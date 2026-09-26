import Testing
import Foundation
@testable import DiskReservoirCore

/// 可记录调用次数的 owner 命令假执行器。
private final class RecordingOwnerRunner: OwnerCommandRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var commands: [OwnerCommand] = []
    private let result: Bool

    init(result: Bool) { self.result = result }

    func run(_ command: OwnerCommand) -> Bool {
        lock.lock()
        commands.append(command)
        lock.unlock()
        return result
    }

    var runCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return commands.count
    }
}

private final class RecordingDeleter: FileDeleting, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var urls: [URL] = []
    let freed: Int64

    init(freed: Int64 = 512) { self.freed = freed }

    func delete(url: URL, disposition: CleanDisposition) throws -> Int64 {
        try FileManager.default.removeItem(at: url)
        lock.lock()
        urls.append(url)
        lock.unlock()
        return freed
    }
}

/// 构造一个可触达清理决策的扫描结果（低于水线、条目足够老）。
private func ownerScan(items: [ScanItem], now: Date) -> ScanResult {
    ScanResult(
        volume: VolumeInfo(totalBytes: 100_000, availableBytes: 100, timestamp: now),
        items: items,
        records: [],
        volumeURL: URL(fileURLWithPath: "/")
    )
}

private func ownerItem(id: String, recipeID: String = "test-owner") -> ScanItem {
    ScanItem(
        id: id, recipeID: recipeID, name: "Owner Cache", path: "/tmp/pp-owner-\(id)",
        category: .common, safety: .safeWhileRunning, disposition: .deletePermanently,
        sizeBytes: 1_000, allocatedBytes: 1_000, reclaimableBytes: 1_000,
        fileCount: 1, lastModified: Date(timeIntervalSince1970: 1_000_000).addingTimeInterval(-60 * 86_400)
    )
}

@Test func ownerCommandSuccessSkipsPathDeletion() throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("pp-owner-ok-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let logStore = CleanLogStore(paths: StoragePaths(baseURL: dir))
    let now = Date(timeIntervalSince1970: 1_000_000)
    let runner = RecordingOwnerRunner(result: true)
    let deleter = RecordingDeleter()

    let cleaner = Cleaner(
        evaluator: RuleEvaluator(config: .default, now: { now }),
        deleter: deleter,
        inspector: AlwaysFalseProcessInspector(),
        logStore: logStore,
        ownerCommandRunner: runner,
        ownerCommandByRecipeID: ["test-owner": OwnerCommand(executable: "fake-tool", arguments: ["--prune"])],
        now: { now }
    )
    let outcome = try cleaner.run(
        scan: ownerScan(items: [ownerItem(id: "a")], now: now),
        config: .default,
        waterlineBytes: 150
    )

    // 命令成功：路径删除不发生，释放量记为条目估算值。
    #expect(runner.runCount == 1)
    #expect(deleter.urls.isEmpty)
    #expect(outcome.freedBytes == 1_000)
    #expect(try logStore.entries().count == 1)
    #expect(try logStore.entries().first?.disposition == .deletePermanently)
}

@Test func ownerCommandFailureFallsBackToPathDeletion() throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("pp-owner-fail-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let logStore = CleanLogStore(paths: StoragePaths(baseURL: dir))
    let now = Date(timeIntervalSince1970: 1_000_000)
    let runner = RecordingOwnerRunner(result: false)
    let deleter = RecordingDeleter()
    let item = ownerItem(id: "a")
    let itemFile = dir.appendingPathComponent("payload.bin")
    try Data(repeating: 0x41, count: 16).write(to: itemFile)
    var fallbackItem = item
    fallbackItem = ScanItem(
        id: item.id, recipeID: item.recipeID, name: item.name, path: itemFile.path,
        category: item.category, safety: item.safety, disposition: item.disposition,
        sizeBytes: item.sizeBytes, allocatedBytes: item.allocatedBytes,
        reclaimableBytes: item.reclaimableBytes, fileCount: item.fileCount,
        lastModified: item.lastModified
    )

    let cleaner = Cleaner(
        evaluator: RuleEvaluator(config: .default, now: { now }),
        deleter: deleter,
        inspector: AlwaysFalseProcessInspector(),
        logStore: logStore,
        ownerCommandRunner: runner,
        ownerCommandByRecipeID: ["test-owner": OwnerCommand(executable: "missing-tool", arguments: [])],
        now: { now }
    )
    let outcome = try cleaner.run(
        scan: ownerScan(items: [fallbackItem], now: now),
        config: .default,
        waterlineBytes: 150
    )

    // 命令失败：降级为逐路径删除，删除确实发生。
    #expect(runner.runCount == 1)
    #expect(deleter.urls == [itemFile])
    #expect(outcome.freedBytes == 512)
}

@Test func ownerCommandRunsOncePerRecipe() throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("pp-owner-dedupe-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let logStore = CleanLogStore(paths: StoragePaths(baseURL: dir))
    let now = Date(timeIntervalSince1970: 1_000_000)
    let runner = RecordingOwnerRunner(result: true)

    let cleaner = Cleaner(
        evaluator: RuleEvaluator(config: .default, now: { now }),
        deleter: RecordingDeleter(),
        inspector: AlwaysFalseProcessInspector(),
        logStore: logStore,
        ownerCommandRunner: runner,
        ownerCommandByRecipeID: ["test-owner": OwnerCommand(executable: "fake-tool", arguments: [])],
        now: { now }
    )
    let outcome = try cleaner.run(
        scan: ownerScan(items: [ownerItem(id: "a"), ownerItem(id: "b")], now: now),
        config: .default,
        waterlineBytes: 150
    )

    // 同配方一次运行只执行一次命令；第二条目由同一命令覆盖，记 0。
    #expect(runner.runCount == 1)
    #expect(outcome.freedBytes == 1_000)
}

@Test func trashDecisionNeverUsesOwnerCommand() throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("pp-owner-trash-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let logStore = CleanLogStore(paths: StoragePaths(baseURL: dir))
    let now = Date(timeIntervalSince1970: 1_000_000)
    let runner = RecordingOwnerRunner(result: true)
    let deleter = RecordingDeleter()
    let itemFile = dir.appendingPathComponent("payload.bin")
    try Data(repeating: 0x41, count: 16).write(to: itemFile)
    let item = ScanItem(
        id: "a", recipeID: "test-owner", name: "Owner Cache", path: itemFile.path,
        category: .common, safety: .safeWhileRunning, disposition: .deletePermanently,
        sizeBytes: 1_000, allocatedBytes: 1_000, reclaimableBytes: 1_000,
        fileCount: 1, lastModified: now.addingTimeInterval(-60 * 86_400)
    )

    let cleaner = Cleaner(
        evaluator: RuleEvaluator(config: .default, now: { now }),
        deleter: deleter,
        inspector: AlwaysFalseProcessInspector(),
        logStore: logStore,
        ownerCommandRunner: runner,
        ownerCommandByRecipeID: ["test-owner": OwnerCommand(executable: "fake-tool", arguments: [])],
        now: { now }
    )
    // 手动 force：决策为回收站 → owner 命令天然是永久语义，绝不使用。
    let outcome = try cleaner.run(
        scan: ownerScan(items: [item], now: now),
        config: .default,
        waterlineBytes: 150,
        forceClean: true
    )

    #expect(runner.runCount == 0)
    #expect(deleter.urls == [itemFile])
    #expect(outcome.freedBytes == 512)
}

@Test func goModuleRecipeDeclaresOwnerCommand() {
    let recipe = RecipeRegistry.builtIn().first { $0.id == PackageManagerRecipes.goModuleCacheID }!
    #expect(recipe.ownerCommand == OwnerCommand(executable: "go", arguments: ["clean", "-modcache"]))
    // owner 命令映射：配方集合 → 字典
    let map = OwnerCommand.mapByRecipeID(RecipeRegistry.builtIn())
    #expect(map[PackageManagerRecipes.goModuleCacheID]?.executable == "go")
    // 其余配方默认没有 owner 命令
    #expect(map[PackageManagerRecipes.familyID] == nil)
}
