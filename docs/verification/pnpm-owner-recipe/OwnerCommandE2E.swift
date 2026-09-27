import Foundation
import Darwin

@main struct OwnerCommandE2E {
    static func main() throws {
        setbuf(stdout, nil)
        let home = ProcessInfo.processInfo.environment["HOME"]!
        let fixture = ProcessInfo.processInfo.environment["FIXTURE_EXECUTABLE"]!
        let fm = FileManager.default
        let store = home + "/store"
        try fm.createDirectory(atPath: store, withIntermediateDirectories: true)
        try fm.createDirectory(atPath: home + "/other-store", withIntermediateDirectories: true)
        let env = ProcessInfo.processInfo.environment
        func runner(_ mode: String) -> OwnerCommandRunner {
            var e = env; e["FIXTURE_MODE"] = mode
            return OwnerCommandRunner(recipe: .pnpmStorePrune, executable: fixture, environment: e, home: home, timeout: 5)
        }
        func check(_ condition: Bool, _ message: String) { if !condition { fatalError(message) }; print("PASS " + message) }
        // Exercise the real file deleter with a persisted aggregate whose
        // volume URL is the volume root, not the fixture's user home.
        let legacyPnpm = home + "/Library/pnpm"
        let safeCache = home + "/.npm"
        try fm.createDirectory(atPath: legacyPnpm + "/store/v3", withIntermediateDirectories: true)
        try fm.createDirectory(atPath: safeCache, withIntermediateDirectories: true)
        let pnpmSentinel = legacyPnpm + "/store/v3/keep-package"
        try Data("keep".utf8).write(to: URL(fileURLWithPath: pnpmSentinel))
        try Data("clean".utf8).write(to: URL(fileURLWithPath: safeCache + "/cache-entry"))
        let old = Date(timeIntervalSince1970: 1_000_000)
        let persisted = ScanItem(
            id: "legacy-package-cache", recipeID: PackageManagerRecipes.familyID,
            name: "Package cache", path: legacyPnpm, paths: [legacyPnpm, safeCache],
            category: .packageManager, safety: .safeWhileRunning,
            disposition: .deletePermanently, sizeBytes: 8192,
            allocatedBytes: 8192, reclaimableBytes: 8192, fileCount: 2,
            lastModified: old, allowsAutomaticPermanentDeletion: true
        )
        let legacyScan = ScanResult(
            volume: VolumeInfo(totalBytes: 100_000, availableBytes: 10_000, timestamp: old),
            items: [persisted], records: [], volumeURL: URL(fileURLWithPath: "/")
        )
        let legacyLogs = CleanLogStore(paths: StoragePaths(
            baseURL: URL(fileURLWithPath: home + "/legacy-data"), homeDirectory: home
        ))
        let legacyOutcome = try Cleaner(
            evaluator: RuleEvaluator(config: .default, now: { old }),
            deleter: FileManagerFileDeleter(), inspector: AlwaysFalseProcessInspector(),
            logStore: legacyLogs, homeDirectory: home, now: { old }
        ).run(scan: legacyScan, config: .default, waterlineBytes: 99_000,
              ignoreAge: true, source: .auto)
        check(legacyScan.volumeURL.path != home, "legacy scan volume differs from fixture home")
        check(!fm.fileExists(atPath: safeCache), "unrelated aggregate cache actually cleaned")
        check(fm.fileExists(atPath: legacyPnpm) && fm.fileExists(atPath: pnpmSentinel), "legacy pnpm tree survives Cleaner")
        check(legacyOutcome.entries.map(\.originalPaths) == [[safeCache]], "Cleaner records only safe cache deletion")
        check(try legacyLogs.entries().map(\.originalPaths) == [[safeCache]], "durable clean log excludes pnpm")
        // A persisted scan can outlive a configured-home change. Its old
        // aggregate must not gain permission to delete the previous HOME.
        let historicalHome = URL(fileURLWithPath: home).deletingLastPathComponent()
            .appendingPathComponent("historical-home").path
        let historicalPnpm = historicalHome + "/Library/pnpm"
        let freshSafeCache = home + "/.cache/uv"
        try fm.createDirectory(atPath: historicalPnpm + "/store/v3", withIntermediateDirectories: true)
        try fm.createDirectory(atPath: freshSafeCache, withIntermediateDirectories: true)
        let historicalSentinel = historicalPnpm + "/store/v3/keep-package"
        try Data("historical".utf8).write(to: URL(fileURLWithPath: historicalSentinel))
        try Data("clean".utf8).write(to: URL(fileURLWithPath: freshSafeCache + "/cache-entry"))
        let oldHomeAggregate = ScanItem(
            id: "historical-package-cache", recipeID: PackageManagerRecipes.familyID,
            name: "Historical package cache", path: historicalPnpm,
            paths: [historicalPnpm, freshSafeCache], category: .packageManager,
            safety: .safeWhileRunning, disposition: .deletePermanently,
            sizeBytes: 8192, allocatedBytes: 8192, reclaimableBytes: 8192,
            fileCount: 2, lastModified: old, allowsAutomaticPermanentDeletion: true
        )
        let historicalScan = ScanResult(
            volume: VolumeInfo(totalBytes: 100_000, availableBytes: 10_000, timestamp: old),
            items: [oldHomeAggregate], records: [], volumeURL: URL(fileURLWithPath: "/")
        )
        let historicalOutcome = try Cleaner(
            evaluator: RuleEvaluator(config: .default, now: { old }),
            deleter: FileManagerFileDeleter(), inspector: AlwaysFalseProcessInspector(),
            logStore: legacyLogs, homeDirectory: home, now: { old }
        ).run(scan: historicalScan, config: .default, waterlineBytes: 99_000,
              ignoreAge: true, source: .auto)
        check(historicalHome != home, "persisted pnpm tree belongs to a different temporary home")
        check(!fm.fileExists(atPath: freshSafeCache), "safe cache still deleted after home changes")
        check(fm.fileExists(atPath: historicalPnpm) && fm.fileExists(atPath: historicalSentinel), "historical-home pnpm tree survives Cleaner")
        check(historicalOutcome.entries.map(\.originalPaths) == [[freshSafeCache]], "historical aggregate records only safe deletion")
        // An old aggregate can contain a parent of pnpm, which a pnpm-root
        // pattern check alone cannot protect from recursive deletion.
        try fm.createDirectory(atPath: safeCache, withIntermediateDirectories: true)
        try Data("clean again".utf8).write(to: URL(fileURLWithPath: safeCache + "/cache-entry"))
        let cocoaPodsCache = home + "/Library/Caches/CocoaPods"
        let homebrewCache = home + "/Library/Caches/Homebrew"
        for path in [cocoaPodsCache, homebrewCache] {
            try fm.createDirectory(atPath: path, withIntermediateDirectories: true)
            try Data("clean".utf8).write(to: URL(fileURLWithPath: path + "/cache-entry"))
        }
        let historicalLibrary = historicalHome + "/Library"
        let parentAggregate = ScanItem(
            id: "parent-package-cache", recipeID: PackageManagerRecipes.familyID,
            name: "Parent package cache", path: historicalLibrary,
            paths: [historicalLibrary, safeCache, cocoaPodsCache, homebrewCache], category: .packageManager,
            safety: .safeWhileRunning, disposition: .deletePermanently,
            sizeBytes: 16_384, allocatedBytes: 16_384, reclaimableBytes: 16_384,
            fileCount: 4, lastModified: old, allowsAutomaticPermanentDeletion: true
        )
        let parentScan = ScanResult(
            volume: VolumeInfo(totalBytes: 100_000, availableBytes: 10_000, timestamp: old),
            items: [parentAggregate], records: [], volumeURL: URL(fileURLWithPath: "/")
        )
        let parentOutcome = try Cleaner(
            evaluator: RuleEvaluator(config: .default, now: { old }),
            deleter: FileManagerFileDeleter(), inspector: AlwaysFalseProcessInspector(),
            logStore: legacyLogs, homeDirectory: home, now: { old }
        ).run(scan: parentScan, config: .default, waterlineBytes: 99_000,
              ignoreAge: true, source: .auto)
        check([safeCache, cocoaPodsCache, homebrewCache].allSatisfy { !fm.fileExists(atPath: $0) }, "all approved default caches deleted beside stale parent")
        check(fm.fileExists(atPath: historicalLibrary) && fm.fileExists(atPath: historicalSentinel), "historical Library parent and pnpm survive Cleaner")
        check(parentOutcome.entries.map(\.originalPaths) == [[safeCache], [cocoaPodsCache], [homebrewCache]], "parent aggregate records only approved caches")
        check(try Array(legacyLogs.entries().suffix(3)).map(\.originalPaths) == [[safeCache], [cocoaPodsCache], [homebrewCache]], "durable parent aggregate log excludes Library and pnpm")
        try Data("package".utf8).write(to: URL(fileURLWithPath: store + "/unreferenced-package"))
        let target = try runner("success").probe().get()
        check(target.path == store, "probe exact isolated store")
        let outcome = try runner("success").perform(confirmed: target).get()
        check(!fm.fileExists(atPath: store + "/unreferenced-package") && fm.fileExists(atPath: store), "prune retained store root")
        check(outcome.target == target, "outcome exact confirmed target")
        let paths = StoragePaths(baseURL: URL(fileURLWithPath: home + "/data"), homeDirectory: home)
        let records = OwnerCommandRecordStore(paths: paths)
        try records.append(OwnerCommandRecord(recipeID: OwnerCommandRecipe.pnpmStorePrune.id, targetPath: target.path, outcome: "success", capacityDeltaBytes: outcome.capacityDeltaBytes))
        check(try records.entries().last?.targetPath == store, "separate owner command history")
        check(!fm.fileExists(atPath: paths.cleanLogURL.path), "no fabricated clean log")
        try Data("package".utf8).write(to: URL(fileURLWithPath: store + "/unreferenced-package"))
        let before = (try? String(contentsOfFile: home + "/invocations", encoding: .utf8)) ?? ""
        if case .failure(.actionFailed(17)) = runner("failure").perform(confirmed: target) { check(true, "nonzero action status") } else { fatalError("wrong action result") }
        check(fm.fileExists(atPath: store + "/unreferenced-package"), "failed action left package")
        let changedTarget = try runner("changed").probe().get()
        if case .failure(.targetChanged) = runner("changed").perform(confirmed: changedTarget) { check(true, "changed target blocked") } else { fatalError("changed target executed") }
        check(runner("invalid").probe() == .failure(.invalidTarget), "invalid root rejected")
        let after = try String(contentsOfFile: home + "/invocations", encoding: .utf8)
        check(after.split(separator: "\n").count == before.split(separator: "\n").count + 1, "changed and invalid target did not run prune")
        let timeoutFixture = env["TIMEOUT_FIXTURE_EXECUTABLE"]!
        let timeoutRunner = OwnerCommandRunner(recipe: .pnpmStorePrune, executable: timeoutFixture, environment: env, home: home, timeout: 0.5)
        let timeoutTarget = try timeoutRunner.probe().get()
        let victim = store + "/delayed-delete-victim"
        try Data("must survive timeout".utf8).write(to: URL(fileURLWithPath: victim))
        let started = Date()
        let timeoutResult = timeoutRunner.perform(confirmed: timeoutTarget)
        let elapsed = Date().timeIntervalSince(started)
        let heartbeatPath = home + "/child-heartbeat"
        let atReturn = (try? Data(contentsOf: URL(fileURLWithPath: heartbeatPath))) ?? Data()
        Thread.sleep(forTimeInterval: 0.8)
        let afterReturn = (try? Data(contentsOf: URL(fileURLWithPath: heartbeatPath))) ?? Data()
        // Clean up the deliberately orphaned fixture even when the regression fails.
        if let pidText = try? String(contentsOfFile: home + "/child-pid", encoding: .utf8),
           let pid = Int32(pidText.trimmingCharacters(in: .whitespacesAndNewlines)) {
            kill(pid, SIGKILL)
        }
        if case .failure(.timedOut) = timeoutResult { check(true, "wrapper action reports timeout") }
        else { fatalError("wrapper did not time out") }
        check(!atReturn.isEmpty, "child ran after draining 512 KiB of stdout and stderr")
        print("EVIDENCE timeout elapsed=\(elapsed) heartbeatBytesAtReturn=\(atReturn.count) heartbeatBytesAfter800ms=\(afterReturn.count)")
        check(atReturn == afterReturn, "child stopped before timeout was reported")
        check(fm.fileExists(atPath: victim), "child cannot perform delayed deletion after timeout")
        check(elapsed < 3, "timeout completes within bounded interval")
        var outputEnv = env; outputEnv["LIFETIME_MODE"] = "output"
        let outputRunner = OwnerCommandRunner(recipe: .pnpmStorePrune, executable: timeoutFixture, environment: outputEnv, home: home, timeout: 5)
        let noisy = try outputRunner.perform(confirmed: timeoutTarget).get()
        check(noisy.output.utf8.count == 65_536, "512 KiB drained with only 64 KiB retained")
        check(true, "executable observes its own process group before action starts")
        try fm.removeItem(atPath: heartbeatPath)
        var earlyEnv = env; earlyEnv["LIFETIME_MODE"] = "early-exit"
        let earlyRunner = OwnerCommandRunner(recipe: .pnpmStorePrune, executable: timeoutFixture, environment: earlyEnv, home: home, timeout: 5)
        _ = try earlyRunner.perform(confirmed: timeoutTarget).get()
        let earlyAtReturn = try Data(contentsOf: URL(fileURLWithPath: heartbeatPath))
        Thread.sleep(forTimeInterval: 0.8)
        let earlyAfter = try Data(contentsOf: URL(fileURLWithPath: heartbeatPath))
        if let pidText = try? String(contentsOfFile: home + "/child-pid", encoding: .utf8),
           let pid = Int32(pidText.trimmingCharacters(in: .whitespacesAndNewlines)) { kill(pid, SIGKILL) }
        check(!earlyAtReturn.isEmpty && earlyAtReturn == earlyAfter, "early wrapper exit also stops its child")
        check(fm.fileExists(atPath: victim), "early wrapper exit cannot leave delayed deletion running")
        check(PackageManagerRecipes.isLegacyPnpmPath(home + "/Library/pnpm/store/v3", homeDirectory: home), "legacy pnpm subtree guarded")
        check(!PackageManagerRecipes.defaultPaths(homeDirectory: home).contains(home + "/Library/pnpm"), "default automatic recipe excludes pnpm")
    }
}
