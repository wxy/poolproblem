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

@Test func volumeReaderReturnsAvailableCapacity() {
    let info = VolumeReader.read(fileURL: URL(fileURLWithPath: "/"))
    #expect(info.totalBytes > 0)
    #expect(info.availableBytes > 0)
}
