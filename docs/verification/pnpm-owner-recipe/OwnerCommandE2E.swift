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
