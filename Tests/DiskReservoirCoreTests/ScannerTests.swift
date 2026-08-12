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
        safety: .userConfirm, disposition: .none,
        defaultAgeDays: 30, minimumSizeMB: 0, processName: nil,
        resolvePaths: { _ in [root.path] }
    )
    let result = try Scanner().scan(recipes: [recipe], homeDirectory: root.path)
    let item = result.items.first { $0.recipeID == "trash" }!
    #expect(item.fileCount == 2)
    #expect(result.records.isEmpty)
    #expect(item.reclaimableBytes == item.allocatedBytes)
}

@Test func volumeReaderReturnsAvailableCapacity() {
    let info = VolumeReader.read(fileURL: URL(fileURLWithPath: "/"))
    #expect(info.totalBytes > 0)
    #expect(info.availableBytes > 0)
}
