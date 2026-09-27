import Foundation
import Testing
@testable import DiskReservoirCore

@Test func childDirectoryFlowKeepsOnlySignificantCurrentDirectoriesAndHonestGrowth() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("pp-child-flow-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let parent = root.appendingPathComponent("Caches", isDirectory: true)
    try Fixtures.makeTree(root: parent, files: [
        ("large/data.bin", 11_000_000),
        ("small/data.bin", 1_000_000),
    ])
    let outside = root.appendingPathComponent("outside", isDirectory: true)
    try Fixtures.makeTree(root: outside, files: [("data.bin", 11_000_000)])
    try FileManager.default.createSymbolicLink(
        at: parent.appendingPathComponent("linked"),
        withDestinationURL: outside
    )

    let now = Date(timeIntervalSince1970: 2_000_000_000)
    let large = parent.appendingPathComponent("large").path
    func growth(delta: Int64, observedAt: Date, elapsedDays: Double) -> GrowthEntry {
        GrowthEntry(
            observedAt: observedAt,
            elapsedDays: elapsedDays,
            name: "large", path: large, pattern: "~/Caches/large", kind: .surface,
            deltaBytes: delta, rateBytesPerDay: Double(delta) / elapsedDays
        )
    }
    let olderPeak = growth(delta: 9_000_000, observedAt: now.addingTimeInterval(-86_400), elapsedDays: 0.01)
    let latest = growth(delta: 3_000_000, observedAt: now.addingTimeInterval(-3_600), elapsedDays: 0.125)
    let listed = ChildDirectoryExplorer().list(
        parentPath: parent.path,
        growthEntries: [olderPeak, latest],
        protectedChildNames: [],
        minimumBytes: 10_000_000,
        now: now
    )
    #expect(listed.map(\.name) == ["large"])
    #expect(listed.first.map { URL(fileURLWithPath: $0.path).resolvingSymlinksInPath().path }
        == URL(fileURLWithPath: large).resolvingSymlinksInPath().path)
    #expect(listed.first?.bytes ?? 0 >= 10_000_000)
    #expect(listed.first?.identity == ChildDirectoryAccess.identity(path: large))
    #expect(listed.first?.growth?.deltaBytes == 3_000_000)
    #expect(listed.first?.growth?.elapsedDays == 0.125)

    let impossible = ChildDirectoryExplorer().list(
        parentPath: parent.path,
        growthEntries: [latest, growth(delta: 800_000_000, observedAt: now, elapsedDays: 0.001)],
        protectedChildNames: [], minimumBytes: 10_000_000, now: now
    )
    #expect(impossible.first?.growth == nil)
}

@Test func childCleanupValidationRequiresExactAuthorizedIdleUnprotectedDirectory() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("pp-child-guard-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let parent = root.appendingPathComponent("DerivedData", isDirectory: true)
    let project = parent.appendingPathComponent("OldProject", isDirectory: true)
    let shared = parent.appendingPathComponent("ModuleCache.noindex", isDirectory: true)
    let nested = project.appendingPathComponent("Build", isDirectory: true)
    let outside = root.appendingPathComponent("other", isDirectory: true)
    for url in [nested, shared, outside] {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
    let linked = parent.appendingPathComponent("linked")
    try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: outside)
    let now = Date()
    let old = now.addingTimeInterval(-2 * 86_400)
    for url in [project, nested] {
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: url.path)
    }
    let originalIdentity = try #require(ChildDirectoryAccess.identity(path: project.path))
    func allowed(_ path: String, parents: Set<String> = []) -> Bool {
        ChildDirectoryAccess.canClean(
            childPath: path,
            parentPath: parent.path,
            authorizedParents: parents.isEmpty ? [parent.path] : parents,
            protectedNames: ["ModuleCache.noindex"],
            expectedIdentity: originalIdentity,
            minimumIdleSeconds: 86_400,
            now: now
        )
    }
    #expect(allowed(project.path))
    #expect(!allowed(parent.path))
    #expect(!allowed(nested.path))
    #expect(!allowed(shared.path))
    #expect(!allowed(linked.path))
    #expect(!allowed(outside.path))
    #expect(!allowed(project.path, parents: [outside.path]))
    try FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: nested.path)
    #expect(!allowed(project.path))
    try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: nested.path)
    let trashRoot = root.appendingPathComponent("test-trash", isDirectory: true)
    let moved = try TrashBatchDeleter(trashRoot: trashRoot, batchName: "Selected directory")
        .deleteReturningResult(url: project, disposition: .trash)
    #expect(!FileManager.default.fileExists(atPath: project.path))
    #expect(FileManager.default.fileExists(atPath: parent.path))
    #expect(FileManager.default.fileExists(atPath: shared.path))
    #expect(moved.resultingURL.map { FileManager.default.fileExists(atPath: $0.path) } == true)
    #expect(!allowed(project.path))
    try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: project.path)
    #expect(!allowed(project.path)) // A replacement at the same path is a different target.
}

@Test func recipeMinimumIsPresentationOnlyAndTrashRemainsVisible() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("pp-display-min-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try Fixtures.makeTree(root: root, files: [("small/data.bin", 1024), ("trash/data.bin", 1024)])
    let smallPath = root.appendingPathComponent("small").path
    let trashPath = root.appendingPathComponent("trash").path
    let small = Recipe(
        id: "small", name: "Small", category: .common,
        safety: .userConfirm, disposition: .trash, cleanability: .regenerable,
        defaultAgeDays: 1, minimumSizeMB: 100, processName: nil,
        resolvePaths: { _ in [smallPath] }
    )
    let trash = Recipe(
        id: "trash", name: "Trash", category: .common,
        safety: .userConfirm, disposition: .none, cleanability: .displayOnly,
        defaultAgeDays: 1, minimumSizeMB: 100, processName: nil,
        resolvePaths: { _ in [trashPath] }
    )
    let scan = try Scanner().scan(recipes: [small, trash], homeDirectory: root.path)
    #expect(scan.items.count == 2)
    let visible = ScanDisplayPolicy.visibleItems(scan.items, recipes: [small, trash])
    #expect(visible.map(\.recipeID) == ["trash"])
}

@Test func broadDeveloperRootsDoNotExposeWholeDirectoryDeletion() throws {
    let recipes = Dictionary(uniqueKeysWithValues: RecipeRegistry.builtIn().map { ($0.id, $0) })
    let derived = try #require(recipes["deriveddata"])
    #expect(derived.cleanByChildOnly)
    #expect(derived.disposition == .trash)
    #expect(derived.protectedChildren.contains("ModuleCache.noindex"))

    let simulatorDevices = try #require(recipes["core-simulator-devices"])
    #expect(simulatorDevices.cleanability == .displayOnly)
    #expect(simulatorDevices.disposition == .none)
}

@Test func shortRealScanIntervalDoesNotBecomeAWeeklyGrowthClaim() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("pp-short-growth-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try Fixtures.makeTree(root: root, files: [("cache/first.bin", 1_000_000)])
    let recipe = Fixtures.recipe(id: "cache", path: root.appendingPathComponent("cache").path)
    let first = try Scanner().scan(recipes: [recipe], homeDirectory: root.path)
    try Fixtures.makeTree(root: root, files: [("cache/second.bin", 1_000_000)])
    let second = try Scanner().scan(recipes: [recipe], homeDirectory: root.path)
    let now = Date()
    func snapshot(_ scan: ScanResult, at date: Date) -> Snapshot {
        Snapshot(
            volume: VolumeInfo(
                totalBytes: scan.volume.totalBytes,
                availableBytes: scan.volume.availableBytes,
                timestamp: date
            ),
            items: scan.items
        )
    }
    let short = [snapshot(first, at: now.addingTimeInterval(-3_600)), snapshot(second, at: now)]
    #expect(FlowAnalyzer().growthRates(snapshots: short).isEmpty)
    let long = [snapshot(first, at: now.addingTimeInterval(-2 * 86_400)), snapshot(second, at: now)]
    #expect((FlowAnalyzer().growthRates(snapshots: long).values.first ?? 0) > 0)
}
