import Testing
import Foundation
@testable import DiskReservoirCore

@Test func permanentDeleteRemovesDirectory() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("pp-del-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try Data(repeating: 7, count: 4096).write(to: root.appendingPathComponent("f.bin"))
    let freed = try FileManagerFileDeleter().delete(url: root, disposition: .deletePermanently)
    #expect(!FileManager.default.fileExists(atPath: root.path))
    #expect(freed > 0)
}

@Test func noneDispositionDoesNothing() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("pp-del2-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let freed = try FileManagerFileDeleter().delete(url: root, disposition: .none)
    #expect(FileManager.default.fileExists(atPath: root.path))
    #expect(freed == 0)
}

@Test func missingPathThrows() {
    let missing = FileManager.default.temporaryDirectory
        .appendingPathComponent("pp-del3-\(UUID().uuidString)", isDirectory: true)
    #expect(throws: (any Error).self) {
        _ = try FileManagerFileDeleter().delete(url: missing, disposition: .deletePermanently)
    }
}

@Test func trashBatchDeleterGroupsItemsInOneFolder() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("pp-batch-\(UUID().uuidString)", isDirectory: true)
    let trash = root.appendingPathComponent(".Trash", isDirectory: true)
    let sourceA = root.appendingPathComponent("source-a", isDirectory: true)
    let sourceB = root.appendingPathComponent("source-b", isDirectory: true)
    try FileManager.default.createDirectory(at: sourceA, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: sourceB, withIntermediateDirectories: true)
    try Data(repeating: 1, count: 128).write(to: sourceA.appendingPathComponent("a.bin"))
    try Data(repeating: 2, count: 128).write(to: sourceB.appendingPathComponent("b.bin"))
    defer { try? FileManager.default.removeItem(at: root) }

    let deleter = TrashBatchDeleter(trashRoot: trash, batchName: "PoolProblem Cleanup test")
    _ = try deleter.delete(url: sourceA, disposition: .trash)
    _ = try deleter.delete(url: sourceB, disposition: .trash)

    let group = trash.appendingPathComponent("PoolProblem Cleanup test", isDirectory: true)
    #expect(FileManager.default.fileExists(atPath: group.path))
    let names = try FileManager.default.contentsOfDirectory(atPath: group.path).sorted()
    #expect(names == ["source-a", "source-b"])
    #expect(!FileManager.default.fileExists(atPath: sourceA.path))
    #expect(!FileManager.default.fileExists(atPath: sourceB.path))
}

@Test func trashBatchDeleterEmptiesOnlyOwnBatches() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("pp-batch-empty-\(UUID().uuidString)", isDirectory: true)
    let trash = root.appendingPathComponent(".Trash", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let ownBatch = trash.appendingPathComponent("PoolProblem Cleanup 2026-08-14 18.36.12", isDirectory: true)
    let otherDir = trash.appendingPathComponent("user-manual-file", isDirectory: true)
    try FileManager.default.createDirectory(at: ownBatch, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: otherDir, withIntermediateDirectories: true)
    try Data(repeating: 1, count: 16).write(to: trash.appendingPathComponent("notes.txt"))

    let removed = try TrashBatchDeleter.emptyOwnBatches(trashRoot: trash)
    #expect(removed == 1)
    #expect(!FileManager.default.fileExists(atPath: ownBatch.path))
    #expect(FileManager.default.fileExists(atPath: otherDir.path))
    #expect(FileManager.default.fileExists(atPath: trash.appendingPathComponent("notes.txt").path))
}
