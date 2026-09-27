import Foundation
import Testing
@testable import DiskReservoirCore

private struct PnpmFixture {
    let root: URL
    let home: URL
    let store: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("pp-pnpm-e2e-\(UUID())")
        home = root.appendingPathComponent("home")
        store = root.appendingPathComponent("store")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: store, withIntermediateDirectories: true)
    }

    func executable(at relativePath: String, body: String) throws -> String {
        let url = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try ("#!/bin/sh\n" + body + "\n").write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url.path
    }

    func close() { try? FileManager.default.removeItem(at: root) }
}

private final class PnpmDeletionRecorder: FileDeleting, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []
    var paths: [String] { lock.lock(); defer { lock.unlock() }; return recorded }
    func delete(url: URL, disposition: CleanDisposition) throws -> Int64 {
        lock.lock(); recorded.append(url.path); lock.unlock()
        return 1
    }
}

@Test func customAndOldSnapshotRootsCannotDeleteDynamicPnpmStore() throws {
    let f = try PnpmFixture(); defer { f.close() }
    let parent = f.root.appendingPathComponent("parent")
    let store = parent.appendingPathComponent("unexpected-store")
    let safe = f.root.appendingPathComponent("safe")
    let alias = f.root.appendingPathComponent("parent-alias")
    try FileManager.default.createDirectory(at: store, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: safe, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: parent)
    try Data("keep".utf8).write(to: store.appendingPathComponent("sentinel"))
    _ = try f.executable(at: "home/.nvm/versions/node/v1/bin/pnpm", body: "echo '\(store.path)'")
    let old = Date(timeIntervalSince1970: 1_000_000)
    func item(_ path: String, id: String) -> ScanItem {
        ScanItem(
            id: id, recipeID: "package-manager-custom", name: "old custom cache",
            path: path, category: .packageManager, safety: .safeWhileRunning,
            disposition: .deletePermanently, sizeBytes: 1000, allocatedBytes: 1000,
            reclaimableBytes: 1000, fileCount: 1, lastModified: old
        )
    }
    let scan = ScanResult(
        volume: VolumeInfo(totalBytes: 100_000, availableBytes: 0, timestamp: old),
        items: [item(parent.path, id: "parent"), item(alias.path, id: "alias"), item(safe.path, id: "safe")],
        records: [], volumeURL: f.root
    )
    let recorder = PnpmDeletionRecorder()
    let homePath = f.home.path
    _ = try Cleaner(
        evaluator: RuleEvaluator(config: .default, now: { old }),
        deleter: recorder, inspector: AlwaysFalseProcessInspector(),
        logStore: CleanLogStore(paths: StoragePaths(baseURL: f.root.appendingPathComponent("logs"), homeDirectory: f.home.path)),
        homeDirectory: homePath, availableBytesReader: { _ in 0 }, now: { old },
        ownerStoreProbe: {
            OwnerCommandRunner(
                recipe: .pnpmStorePrune,
                environment: ["PATH": homePath + "/missing-bin"], home: homePath
            ).probe()
        }
    ).run(scan: scan, config: .default, waterlineBytes: 10_000, forceClean: true, ignoreAge: true)
    #expect(!recorder.paths.contains(parent.path))
    #expect(!recorder.paths.contains(alias.path))
    #expect(recorder.paths.contains(safe.path))
    #expect(FileManager.default.fileExists(atPath: store.appendingPathComponent("sentinel").path))
}

@Test func aggregateScanExcludesNestedPnpmStoreWithoutHidingSiblingCache() throws {
    let f = try PnpmFixture(); defer { f.close() }
    let cache = f.home.appendingPathComponent(".npm")
    let store = cache.appendingPathComponent("custom-pnpm-store")
    try FileManager.default.createDirectory(at: store, withIntermediateDirectories: true)
    try Data(repeating: 1, count: 11_000_000).write(to: store.appendingPathComponent("package"))
    try Data(repeating: 2, count: 2_000_000).write(to: cache.appendingPathComponent("npm-cache"))
    let target = OwnerCommandTarget(executable: "/fixture/pnpm", path: store.path)
    let recipes = [
        PackageManagerRecipes.make(extraRoots: [], homeDirectory: f.home.path),
        OwnerCommandRecipe.pnpmStorePrune.scanRecipe(target: target),
    ]
    let scan = try Scanner(now: { Date().addingTimeInterval(100 * 86_400) })
        .scan(recipes: recipes, homeDirectory: f.home.path)
    let pnpm = try #require(scan.items.first { $0.recipeID == OwnerCommandRecipe.pnpmStorePrune.id })
    let npm = try #require(scan.items.first { $0.recipeID == PackageManagerRecipes.familyID })
    #expect(pnpm.allocatedBytes >= 10_000_000)
    #expect(npm.allocatedBytes >= 2_000_000)
    #expect(npm.allocatedBytes < pnpm.allocatedBytes)
    #expect(npm.reclaimableBytes == 0)
}

@Test func approvedDefaultCacheFailsClosedWhenPnpmProbeFails() throws {
    let f = try PnpmFixture(); defer { f.close() }
    let npm = f.home.appendingPathComponent(".npm")
    let store = npm.appendingPathComponent("unexpected-store")
    try FileManager.default.createDirectory(at: store, withIntermediateDirectories: true)
    try Data("keep".utf8).write(to: store.appendingPathComponent("package"))
    let old = Date(timeIntervalSince1970: 1_000_000)
    let item = ScanItem(
        id: "old-family", recipeID: PackageManagerRecipes.familyID, name: "package cache",
        path: npm.path, category: .packageManager, safety: .safeWhileRunning,
        disposition: .deletePermanently, sizeBytes: 1000, allocatedBytes: 1000,
        reclaimableBytes: 1000, fileCount: 1, lastModified: old,
        allowsAutomaticPermanentDeletion: true
    )
    let scan = ScanResult(
        volume: VolumeInfo(totalBytes: 100_000, availableBytes: 0, timestamp: old),
        items: [item], records: [], volumeURL: f.root
    )
    let recorder = PnpmDeletionRecorder()
    _ = try Cleaner(
        evaluator: RuleEvaluator(config: .default, now: { old }),
        deleter: recorder, inspector: AlwaysFalseProcessInspector(),
        logStore: CleanLogStore(paths: StoragePaths(baseURL: f.root.appendingPathComponent("logs"), homeDirectory: f.home.path)),
        homeDirectory: f.home.path, availableBytesReader: { _ in 0 }, now: { old },
        ownerStoreProbe: { .failure(.probeFailed(11)) }
    ).run(scan: scan, config: .default, waterlineBytes: 10_000,
          ignoreAge: true, source: .auto)
    #expect(recorder.paths.isEmpty)
    #expect(FileManager.default.fileExists(atPath: store.appendingPathComponent("package").path))
    let separateStore = f.root.appendingPathComponent("separate-pnpm-store")
    try FileManager.default.createDirectory(at: separateStore, withIntermediateDirectories: true)
    let safeRecorder = PnpmDeletionRecorder()
    _ = try Cleaner(
        evaluator: RuleEvaluator(config: .default, now: { old }),
        deleter: safeRecorder, inspector: AlwaysFalseProcessInspector(),
        logStore: CleanLogStore(paths: StoragePaths(baseURL: f.root.appendingPathComponent("safe-logs"), homeDirectory: f.home.path)),
        homeDirectory: f.home.path, availableBytesReader: { _ in 0 }, now: { old },
        ownerStoreProbe: {
            .success(OwnerCommandTarget(executable: "/fixture/pnpm", path: separateStore.path))
        }
    ).run(scan: scan, config: .default, waterlineBytes: 10_000,
          ignoreAge: true, source: .auto)
    #expect(safeRecorder.paths == [npm.path])
}

@Test func unavailablePnpmKeepsOtherCachesUsableAndProtectsKnownLocations() throws {
    let f = try PnpmFixture(); defer { f.close() }
    let npm = f.home.appendingPathComponent(".npm")
    let recognizable = f.home.appendingPathComponent("Library/Caches/pnpm")
    try FileManager.default.createDirectory(at: npm, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: recognizable, withIntermediateDirectories: true)
    let unavailable: Result<OwnerCommandTarget, OwnerCommandFailure> = .failure(.unavailable)
    #expect(OwnerManagedPathGuard.mayDelete(
        path: npm.path, recipeID: PackageManagerRecipes.familyID,
        probe: unavailable, homeDirectory: f.home.path
    ))
    #expect(!OwnerManagedPathGuard.mayDelete(
        path: recognizable.path, recipeID: "library-caches",
        probe: unavailable, homeDirectory: f.home.path
    ))
    #expect(!OwnerManagedPathGuard.mayDelete(
        path: npm.path, recipeID: PackageManagerRecipes.familyID,
        probe: unavailable, homeDirectory: f.home.path,
        knownStorePaths: [npm.appendingPathComponent("past-store").path]
    ))
}

@Test func historicalStoreAStillProtectsScanAndAutoCleanAfterPnpmMovesToB() throws {
    let f = try PnpmFixture(); defer { f.close() }
    let a = f.home.appendingPathComponent(".npm/pnpm-store")
    let b = f.home.appendingPathComponent("Library/pnpm")
    let uv = f.home.appendingPathComponent(".cache/uv")
    for directory in [a, b, uv] {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    try Data(repeating: 1, count: 11_000_000).write(to: a.appendingPathComponent("old-package"))
    try Data(repeating: 2, count: 11_000_000).write(to: b.appendingPathComponent("current-package"))
    try Data(repeating: 3, count: 2_000_000).write(to: uv.appendingPathComponent("uv-cache"))
    let paths = StoragePaths(baseURL: f.root.appendingPathComponent("data"), homeDirectory: f.home.path)
    let legacyItem = ScanItem(
        id: "pnpm-store-prune:\(a.path)", recipeID: OwnerCommandRecipe.pnpmStorePrune.id,
        name: "pnpm store", path: a.path, category: .packageManager,
        safety: .userConfirm, disposition: .none, sizeBytes: 11_000_000,
        allocatedBytes: 11_000_000, reclaimableBytes: 0, fileCount: 1,
        lastModified: nil, cleanability: .watchOnly
    )
    let volume = VolumeInfo(totalBytes: 100_000_000, availableBytes: 0, timestamp: Date())
    try SnapshotStore(paths: paths).append(Snapshot(volume: volume, items: [legacyItem]))
    let knownStore = OwnerCommandKnownTargetsStore(paths: paths)
    _ = try knownStore.migrate(snapshots: SnapshotStore(paths: paths).snapshots())
    _ = try knownStore.record([b.path])
    try SnapshotStore(paths: paths).prune(retainingDays: 0)
    #expect(try SnapshotStore(paths: paths).snapshots().isEmpty)
    let observed = try OwnerCommandKnownTargetsStore(paths: paths).paths()
    #expect(Set(observed) == Set([a.path, b.path]))

    let current = OwnerCommandTarget(executable: "/fixture/pnpm", path: b.path)
    let recipes = [
        PackageManagerRecipes.make(extraRoots: [], homeDirectory: f.home.path),
        OwnerCommandRecipe.pnpmStorePrune.scanRecipe(target: current),
    ]
    let future = Date().addingTimeInterval(100 * 86_400)
    let scan = try Scanner(now: { future }, protectedOwnerPaths: observed)
        .scan(recipes: recipes, homeDirectory: f.home.path)
    let owner = try #require(scan.items.first { $0.recipeID == currentRecipeID })
    let package = try #require(scan.items.first { $0.recipeID == PackageManagerRecipes.familyID })
    #expect(owner.path == b.path)
    #expect(owner.allocatedBytes >= 10_000_000)
    #expect(package.allocatedBytes >= 2_000_000)
    #expect(package.allocatedBytes < 10_000_000)
    #expect(package.reclaimableBytes >= 2_000_000)
    #expect(package.reclaimableBytes < 10_000_000)

    let recorder = PnpmDeletionRecorder()
    _ = try Cleaner(
        evaluator: RuleEvaluator(config: .default, now: { future }),
        deleter: recorder, inspector: AlwaysFalseProcessInspector(),
        logStore: CleanLogStore(paths: paths), homeDirectory: f.home.path,
        availableBytesReader: { _ in 0 }, now: { future },
        ownerStoreProbe: { .success(current) }, knownOwnerStorePaths: observed
    ).run(scan: scan, config: .default, waterlineBytes: 90_000_000,
          ignoreAge: true, source: .auto)
    #expect(recorder.paths == [uv.path])
    #expect(FileManager.default.fileExists(atPath: a.appendingPathComponent("old-package").path))
    #expect(FileManager.default.fileExists(atPath: b.appendingPathComponent("current-package").path))
}

@Test func knownStoreHistoryOverflowFailsClosedForEveryRawDeletion() throws {
    let f = try PnpmFixture(); defer { f.close() }
    let paths = StoragePaths(baseURL: f.root.appendingPathComponent("data"), homeDirectory: f.home.path)
    let knownStore = OwnerCommandKnownTargetsStore(paths: paths)
    let candidates = (0...OwnerCommandKnownTargetsStore.maximumPaths).map {
        f.home.appendingPathComponent("stores/store-\($0)").path
    }
    let state = try knownStore.record(candidates)
    #expect(state.overflowed)
    #expect(state.paths.count == OwnerCommandKnownTargetsStore.maximumPaths)
    let reloaded = try OwnerCommandKnownTargetsStore(paths: paths).state()
    #expect(reloaded.overflowed)
    let unavailable: Result<OwnerCommandTarget, OwnerCommandFailure> = .failure(.unavailable)
    #expect(!OwnerManagedPathGuard.mayDelete(
        path: f.home.appendingPathComponent(".npm").path,
        recipeID: PackageManagerRecipes.familyID,
        probe: unavailable, homeDirectory: f.home.path,
        knownStorePaths: reloaded.paths, historyOverflowed: reloaded.overflowed
    ))
    #expect(!OwnerManagedPathGuard.mayDelete(
        path: f.home.appendingPathComponent("unrelated-build-cache").path,
        recipeID: "unrelated-recipe",
        probe: unavailable, homeDirectory: f.home.path,
        knownStorePaths: reloaded.paths, historyOverflowed: reloaded.overflowed
    ))
}

private let currentRecipeID = OwnerCommandRecipe.pnpmStorePrune.id

@Test func exactCustomRootDoesNotDoubleCountOwnerStore() throws {
    let f = try PnpmFixture(); defer { f.close() }
    try Data(repeating: 1, count: 11_000_000).write(to: f.store.appendingPathComponent("package"))
    let target = OwnerCommandTarget(executable: "/fixture/pnpm", path: f.store.path)
    let recipes = [
        PackageManagerRecipes.makeCustom(extraRoots: [f.store.path]),
        OwnerCommandRecipe.pnpmStorePrune.scanRecipe(target: target),
    ]
    let scan = try Scanner(now: { Date().addingTimeInterval(100 * 86_400) })
        .scan(recipes: recipes, homeDirectory: f.home.path)
    #expect(scan.items.count == 1)
    #expect(scan.items.first?.recipeID == OwnerCommandRecipe.pnpmStorePrune.id)
}

@Test func pnpmProbeSkipsBrokenShimAndScansExactStoreWithoutDeletion() throws {
    let f = try PnpmFixture(); defer { f.close() }
    _ = try f.executable(at: "first/pnpm", body: "echo broken >&2; exit 1")
    let valid = try f.executable(at: "second/pnpm", body: "echo warning >&2; echo '\(f.store.path)'")
    try Data(repeating: 1, count: 11_000_000).write(to: f.store.appendingPathComponent("asset"))
    let env = ["PATH": f.root.appendingPathComponent("first").path + ":" + f.root.appendingPathComponent("second").path]
    let runner = OwnerCommandRunner(recipe: .pnpmStorePrune, environment: env, home: f.home.path)
    let target = try runner.probe().get()
    #expect(target.executable == valid)
    #expect(target.path == f.store.path)
    let recipe = OwnerCommandRecipe.pnpmStorePrune.scanRecipe(target: target)
    #expect(recipe.cleanability == .watchOnly)
    #expect(recipe.disposition == .none)
    #expect(recipe.minimumSizeMB == 10)
    let result = try Scanner().scan(recipes: [recipe], homeDirectory: f.home.path)
    let item = try #require(result.items.first)
    #expect(item.path == f.store.path)
    #expect(item.allocatedBytes >= 10_000_000)
    #expect(ScanDisplayPolicy.visibleItems(result.items, recipes: [recipe]).count == 1)
    #expect(item.reclaimableBytes == 0)
    #expect(!item.cleanability.allowsManualCleanup)
    #expect(FileManager.default.fileExists(atPath: f.store.appendingPathComponent("asset").path))
}

@Test func pnpmProbeRejectsAmbiguousStoresAndDisablesCorepackNetwork() throws {
    let f = try PnpmFixture(); defer { f.close() }
    let other = f.root.appendingPathComponent("other")
    try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
    _ = try f.executable(at: "first/pnpm", body: "test \"$COREPACK_ENABLE_NETWORK\" = 0 || exit 7; echo '\(f.store.path)'")
    _ = try f.executable(at: "second/pnpm", body: "echo '\(other.path)'")
    let env = ["PATH": f.root.appendingPathComponent("first").path + ":" + f.root.appendingPathComponent("second").path]
    let runner = OwnerCommandRunner(recipe: .pnpmStorePrune, environment: env, home: f.home.path)
    #expect(runner.probe() == .failure(.ambiguousTarget))
}

@Test func pnpmProbeRejectsMalformedPathsAndNeverRunsPrune() throws {
    let f = try PnpmFixture(); defer { f.close() }
    let marker = f.root.appendingPathComponent("pruned")
    let executable = try f.executable(at: "bin/pnpm", body: "if test \"$2\" = prune; then touch '\(marker.path)'; exit 0; fi; echo /; echo '\(f.store.path)'")
    let runner = OwnerCommandRunner(recipe: .pnpmStorePrune, executable: executable, home: f.home.path)
    #expect(runner.probe() == .failure(.invalidTarget))
    #expect(!FileManager.default.fileExists(atPath: marker.path))
}
