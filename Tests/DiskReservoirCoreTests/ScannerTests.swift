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
