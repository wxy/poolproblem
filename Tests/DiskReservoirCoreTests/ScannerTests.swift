import Testing
import Foundation
@testable import DiskReservoirCore

@Test func scannerReportsSizeAndFileCount() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("pp-scan-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try Fixtures.makeTree(root: root, files: [("a.bin", 4096), ("sub/b.bin", 8192)])

    let recipe = Fixtures.recipe(id: "fixture", path: root.path)
    let result = try Scanner().scan(recipes: [recipe], homeDirectory: root.path)
    let item = result.items.first { $0.recipeID == "fixture" }!
    #expect(item.fileCount == 2)
    #expect(item.sizeBytes > 0)
    #expect(item.allocatedBytes > 0)
    #expect(item.reclaimableBytes == item.allocatedBytes)
    #expect(result.records.count == 2)
}

@Test func scannerSkipsMissingPaths() throws {
    let missing = FileManager.default.temporaryDirectory
        .appendingPathComponent("pp-missing-\(UUID().uuidString)", isDirectory: true)
    let recipe = Fixtures.recipe(id: "ghost", path: missing.path)
    let result = try Scanner().scan(recipes: [recipe], homeDirectory: FileManager.default.temporaryDirectory.path)
    #expect(result.items.isEmpty)
}

@Test func posixWalkerMatchesFileManager() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("pp-posix-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try Fixtures.makeTree(root: root, files: [("a.bin", 4096), ("sub/b.bin", 8192), ("sub/deep/c.bin", 2048)])

    let walk = POSIXDirectoryWalker.walk(url: root, itemID: "t")
    #expect(walk != nil)
    #expect(walk?.fileCount == 3)
    #expect(walk?.sizeBytes == Int64(4096 + 8192 + 2048))
    #expect(walk?.allocatedBytes ?? 0 > 0)
    #expect(walk?.files.count == 3)
}

@Test func posixWalkerFirstLevelCount() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("pp-posix1-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try Fixtures.makeTree(root: root, files: [("x.bin", 1024), ("y.bin", 2048), ("sub/z.bin", 1024)])

    #expect(POSIXDirectoryWalker.firstLevelCount(path: root.path) == 3)
    #expect(POSIXDirectoryWalker.firstLevelCount(path: root.path + "/does-not-exist") == nil)
}

@Test func scannerMeasuresDispositionNoneWithoutRecords() throws {
    // 废纸篓这类不可清理目录走轻量 POSIX 统计：不产生文件记录，
    // 且可回收量应保留物理占用值而不是被估算器归零
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("pp-trash-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try Fixtures.makeTree(root: root, files: [("a.bin", 4096), ("sub/b.bin", 8192)])
    let recipe = Recipe(
        id: "trash", name: "Trash", category: .common,
        safety: .userConfirm, disposition: .none, cleanability: .displayOnly,
        defaultAgeDays: 30, minimumSizeMB: 0, processName: nil,
        resolvePaths: { _ in [root.path] }
    )
    let result = try Scanner().scan(recipes: [recipe], homeDirectory: root.path)
    let item = result.items.first { $0.recipeID == "trash" }!
    #expect(item.fileCount == 2)
    #expect(result.records.isEmpty)
    #expect(item.reclaimableBytes == item.allocatedBytes)
}

@Test func runtimeRecipeUsesLastBootedDateAsLastModified() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("pp-runtime-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let home = root.appendingPathComponent("Home", isDirectory: true)
    let volumes = root.appendingPathComponent("Volumes", isDirectory: true)
    let runtime = volumes.appendingPathComponent("iOS_23F77", isDirectory: true)
    let runtimesBundle = runtime
        .appendingPathComponent("Library/Developer/CoreSimulator/Profiles/Runtimes/iOS 26.5.simruntime/Contents", isDirectory: true)
    try FileManager.default.createDirectory(at: runtimesBundle, withIntermediateDirectories: true)
    let info = runtimesBundle.appendingPathComponent("Info.plist")
    let infoData = try PropertyListSerialization.data(
        fromPropertyList: ["CFBundleIdentifier": "com.apple.CoreSimulator.SimRuntime.iOS-26-5"],
        format: .xml,
        options: 0
    )
    try infoData.write(to: info)

    let bootDate = Date(timeIntervalSince1970: 1_720_000_000)
    let deviceDir = home
        .appendingPathComponent("Library/Developer/CoreSimulator/Devices/65380F54-FAED-4D99-B055-F2BA0E015C9E", isDirectory: true)
    try FileManager.default.createDirectory(at: deviceDir, withIntermediateDirectories: true)
    let deviceData = try PropertyListSerialization.data(
        fromPropertyList: [
            "runtime": "com.apple.CoreSimulator.SimRuntime.iOS-26-5",
            "lastBootedAt": bootDate,
        ],
        format: .xml,
        options: 0
    )
    try deviceData.write(to: deviceDir.appendingPathComponent("device.plist"))

    let recipe = Recipe(
        id: "simulator-runtimes", name: "Runtime", category: .simulator,
        safety: .userConfirm, disposition: .trash, cleanability: .regenerable,
        defaultAgeDays: 30, minimumSizeMB: 100, processName: nil,
        usageProbe: .simulatorRuntimeLastBooted,
        resolvePaths: { _ in [volumes.path] }
    )
    let result = try Scanner().scan(recipes: [recipe], homeDirectory: home.path)
    guard let item = result.items.first else {
        Issue.record("expected a runtime item")
        return
    }
    #expect(
        URL(fileURLWithPath: item.path).resolvingSymlinksInPath().path
            == runtime.resolvingSymlinksInPath().path
    )
    #expect(item.lastModified.map { abs($0.timeIntervalSince(bootDate)) < 1 } == true)
}

@Test func neverBootedRuntimeHasNilLastModified() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("pp-runtime-unused-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let home = root.appendingPathComponent("Home", isDirectory: true)
    let volumes = root.appendingPathComponent("Volumes", isDirectory: true)
    let runtime = volumes.appendingPathComponent("watchOS_23T570", isDirectory: true)
    let runtimesBundle = runtime
        .appendingPathComponent("Library/Developer/CoreSimulator/Profiles/Runtimes/watchOS 26.5.simruntime/Contents", isDirectory: true)
    try FileManager.default.createDirectory(at: runtimesBundle, withIntermediateDirectories: true)
    let info = runtimesBundle.appendingPathComponent("Info.plist")
    let infoData = try PropertyListSerialization.data(
        fromPropertyList: ["CFBundleIdentifier": "com.apple.CoreSimulator.SimRuntime.watchOS-26-5"],
        format: .xml,
        options: 0
    )
    try infoData.write(to: info)

    let recipe = Recipe(
        id: "simulator-runtimes", name: "Runtime", category: .simulator,
        safety: .userConfirm, disposition: .trash, cleanability: .regenerable,
        defaultAgeDays: 30, minimumSizeMB: 100, processName: nil,
        usageProbe: .simulatorRuntimeLastBooted,
        resolvePaths: { _ in [volumes.path] }
    )
    let result = try Scanner().scan(recipes: [recipe], homeDirectory: home.path)
    guard let item = result.items.first else {
        Issue.record("expected a runtime item")
        return
    }
    #expect(
        URL(fileURLWithPath: item.path).resolvingSymlinksInPath().path
            == runtime.resolvingSymlinksInPath().path
    )
    #expect(item.lastModified == nil)
}

@Test func runtimeRecipeSkipsNonRuntimeChildren() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("pp-runtime-noise-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let home = root.appendingPathComponent("Home", isDirectory: true)
    let volumes = root.appendingPathComponent("Volumes", isDirectory: true)
    let runtime = volumes.appendingPathComponent("iOS_23F77", isDirectory: true)
    let runtimesBundle = runtime
        .appendingPathComponent("Library/Developer/CoreSimulator/Profiles/Runtimes/iOS 26.5.simruntime/Contents", isDirectory: true)
    try FileManager.default.createDirectory(at: runtimesBundle, withIntermediateDirectories: true)
    let info = runtimesBundle.appendingPathComponent("Info.plist")
    let infoData = try PropertyListSerialization.data(
        fromPropertyList: ["CFBundleIdentifier": "com.apple.CoreSimulator.SimRuntime.iOS-26-5"],
        format: .xml,
        options: 0
    )
    try infoData.write(to: info)
    try FileManager.default.createDirectory(
        at: volumes.appendingPathComponent("inc", isDirectory: true),
        withIntermediateDirectories: true
    )

    let recipe = Recipe(
        id: "simulator-dyld-cache", name: "Shared Cache", category: .simulator,
        safety: .userConfirm, disposition: .trash, cleanability: .regenerable,
        defaultAgeDays: 30, minimumSizeMB: 100, processName: nil,
        usageProbe: .simulatorRuntimeLastBooted,
        resolvePaths: { _ in [volumes.path] }
    )
    let result = try Scanner().scan(recipes: [recipe], homeDirectory: home.path)
    #expect(result.items.count == 1)
    #expect(result.items.first?.path.hasSuffix("iOS_23F77") == true)
}

@Test func runtimeDisplayNameReadsSimruntimeBundle() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("pp-runtime-name-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let bundle = root
        .appendingPathComponent("Library/Developer/CoreSimulator/Profiles/Runtimes/iOS 26.5.simruntime", isDirectory: true)
    try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)

    #expect(SimulatorRuntimeUsage.displayName(forPath: root.path) == "iOS 26.5")
}

@Test func runtimeDisplayNameParsesDyldCacheName() {
    let path = "/tmp/dyld/25F80/com.apple.CoreSimulator.SimRuntime.watchOS-26-5.23T570"
    #expect(SimulatorRuntimeUsage.displayName(forPath: path) == "watchOS 26.5")
}

@Test func volumeReaderReturnsAvailableCapacity() {
    let info = VolumeReader.read(fileURL: URL(fileURLWithPath: "/"))
    #expect(info.totalBytes > 0)
    #expect(info.availableBytes > 0)
}

@Test func parentAndSelfProbeUsesParentNewest() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("pp-probe-\(UUID().uuidString)", isDirectory: true)
    let project = root.appendingPathComponent("Proj", isDirectory: true)
    let nm = project.appendingPathComponent("node_modules", isDirectory: true)
    try FileManager.default.createDirectory(at: nm, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try Data().write(to: nm.appendingPathComponent("old.bin"))
    Thread.sleep(forTimeInterval: 1.1)
    // 上级项目根新增文件 → 项目仍活跃，条目 lastModified 应反映上级的新 mtime
    try Data().write(to: project.appendingPathComponent("new.swift"))
    let recipe = Recipe(
        id: "project-node-modules", name: "NM", category: .project, safety: .userConfirm,
        disposition: .trash, cleanability: .regenerable,
        defaultAgeDays: 30, minimumSizeMB: 100, processName: nil,
        usageProbe: .parentAndSelfNewestModified,
        resolvePaths: { _ in [nm.path] }
    )
    let items = Scanner().rescan(path: nm.path, recipe: recipe, homeDirectory: root.path)
    let parentNewest = (try? FileManager.default.attributesOfItem(atPath: project.path)[.modificationDate] as? Date) ?? .distantPast
    let itemNewest = (try? FileManager.default.attributesOfItem(atPath: nm.path)[.modificationDate] as? Date) ?? .distantPast
    #expect((items.first?.lastModified ?? .distantPast) >= max(parentNewest, itemNewest).addingTimeInterval(-2))
}

@Test func scannerAggregatesMultiplePathsIntoOneItem() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("pp-agg-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let projA = root.appendingPathComponent("A/node_modules", isDirectory: true)
    let projB = root.appendingPathComponent("B/node_modules", isDirectory: true)
    try FileManager.default.createDirectory(at: projA, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: projB, withIntermediateDirectories: true)
    try Fixtures.makeTree(root: projA, files: [("pkg.bin", 4096)])
    try Fixtures.makeTree(root: projB, files: [("pkg.bin", 8192)])
    // 两个目录都足够老，才应进入聚合条目
    let oldDate = Date().addingTimeInterval(-100 * 86_400)
    try FileManager.default.setAttributes(
        [.modificationDate: oldDate],
        ofItemAtPath: projA.appendingPathComponent("pkg.bin").path
    )
    try FileManager.default.setAttributes(
        [.modificationDate: oldDate],
        ofItemAtPath: projB.appendingPathComponent("pkg.bin").path
    )

    let recipe = Recipe(
        id: "project-node-modules", name: "Project node_modules", category: .project,
        safety: .userConfirm, disposition: .trash, cleanability: .regenerable,
        defaultAgeDays: 30, minimumSizeMB: 100, processName: nil,
        aggregatesPaths: true,
        resolvePaths: { _ in [projA.path, projB.path] }
    )
    let result = try Scanner().scan(recipes: [recipe], homeDirectory: root.path)
    #expect(result.items.count == 1)
    let item = result.items[0]
    #expect(item.paths == [projA.path, projB.path])
    #expect(item.sizeBytes == Int64(4096 + 8192))
    #expect(item.fileCount == 2)
    #expect(item.safety == .safeWhileRunning)

    // 增量重扫：任一项目路径变脏 → 仍返回唯一聚合条目
    let fresh = Scanner().rescan(path: projB.path, recipe: recipe, homeDirectory: root.path)
    #expect(fresh.count == 1)
    #expect(fresh[0].paths == [projA.path, projB.path])
    #expect(fresh[0].id.hasSuffix(":aggregate"))
}

@Test func scannerAggregatesOnlyOldEnoughPaths() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("pp-agg2-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let oldProj = root.appendingPathComponent("Old/node_modules", isDirectory: true)
    let recentProj = root.appendingPathComponent("Recent/node_modules", isDirectory: true)
    try FileManager.default.createDirectory(at: oldProj, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: recentProj, withIntermediateDirectories: true)
    try Fixtures.makeTree(root: oldProj, files: [("pkg.bin", 4096)])
    try Fixtures.makeTree(root: recentProj, files: [("pkg.bin", 8192)])
    try FileManager.default.setAttributes(
        [.modificationDate: Date().addingTimeInterval(-100 * 86_400)],
        ofItemAtPath: oldProj.appendingPathComponent("pkg.bin").path
    )
    // recentProj 保持"刚刚修改"，不应进入可清理清单

    let recipe = Recipe(
        id: "project-node-modules", name: "node_modules", category: .project,
        safety: .userConfirm, disposition: .trash, cleanability: .regenerable,
        defaultAgeDays: 30, minimumSizeMB: 100, processName: nil,
        aggregatesPaths: true,
        resolvePaths: { _ in [oldProj.path, recentProj.path] }
    )
    let result = try Scanner().scan(recipes: [recipe], homeDirectory: root.path)
    #expect(result.items.count == 1)
    let item = result.items[0]
    #expect(item.paths == [oldProj.path])
    #expect(item.sizeBytes == 4096)
    #expect(item.safety == .safeWhileRunning)
}

@Test func scanItemDecodesLegacySnapshotWithoutPaths() throws {
    // 旧快照 JSON 没有 paths 字段：应回退为 [path]，保证兼容
    let json = """
    {"id":"r:/tmp/x","recipeID":"r","name":"R","path":"/tmp/x",
     "category":"common","safety":"safeWhileRunning","disposition":"trash",
     "sizeBytes":1,"allocatedBytes":1,"reclaimableBytes":1,"fileCount":0,
     "lastModified":null,"cleanability":"regenerable"}
    """
    let item = try JSONDecoder().decode(ScanItem.self, from: Data(json.utf8))
    #expect(item.paths == ["/tmp/x"])
}
