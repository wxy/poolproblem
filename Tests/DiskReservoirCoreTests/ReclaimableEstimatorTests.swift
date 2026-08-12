import Testing
import Foundation
@testable import DiskReservoirCore

@Test func sharedInodeCountsOnce() {
    let shared = FileRecord(
        itemID: "a", url: URL(fileURLWithPath: "/tmp/a"), allocatedBytes: 1000,
        deviceID: 1, inode: 42, lastModified: .distantPast
    )
    let clone = FileRecord(
        itemID: "b", url: URL(fileURLWithPath: "/tmp/b"), allocatedBytes: 1000,
        deviceID: 1, inode: 42, lastModified: .distantPast
    )
    let uniqueB = FileRecord(
        itemID: "b", url: URL(fileURLWithPath: "/tmp/c"), allocatedBytes: 500,
        deviceID: 1, inode: 43, lastModified: .distantPast
    )
    let result = ReclaimableEstimator().estimate(records: [shared, clone, uniqueB])
    #expect(result["a"] == 0)
    #expect(result["b"] == 500)
}

@Test func applyUpdatesReclaimableBytes() {
    let item = ScanItem(
        id: "x", recipeID: "r", name: "N", path: "/tmp/x",
        category: .common, safety: .safeWhileRunning, disposition: .deletePermanently,
        sizeBytes: 1000, allocatedBytes: 1000, reclaimableBytes: 1000,
        fileCount: 1, lastModified: nil
    )
    let record = FileRecord(
        itemID: "x", url: URL(fileURLWithPath: "/tmp/x"), allocatedBytes: 1000,
        deviceID: 1, inode: 7, lastModified: .distantPast
    )
    let updated = ReclaimableEstimator().apply(to: [item], records: [record])
    #expect(updated.first?.reclaimableBytes == 1000)
}

@Test func applyKeepsReclaimableWhenNoRecords() {
    // 轻量测量的目录（如废纸篓）没有逐文件记录，可回收量应保留扫描值而不是归零
    let item = ScanItem(
        id: "trash", recipeID: "trash", name: "废纸篓", path: "/tmp/trash",
        category: .common, safety: .userConfirm, disposition: .none,
        sizeBytes: 5_000, allocatedBytes: 5_000, reclaimableBytes: 5_000,
        fileCount: 100, lastModified: nil
    )
    let updated = ReclaimableEstimator().apply(to: [item], records: [])
    #expect(updated.first?.reclaimableBytes == 5_000)
}

@Test func hardLinksShareInodeAndDedup() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("pp-clone-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let src = root.appendingPathComponent("src.bin")
    try Data(repeating: 1, count: 1_000_000).write(to: src)
    let dst = root.appendingPathComponent("link.bin")
    try FileManager.default.linkItem(at: src, to: dst)

    let srcStat = statFile(src)
    let dstStat = statFile(dst)
    #expect(srcStat.st_ino == dstStat.st_ino)
    let records = [
        FileRecord(itemID: "a", url: src, allocatedBytes: 1_000_000, deviceID: srcStat.st_dev, inode: srcStat.st_ino, lastModified: .distantPast),
        FileRecord(itemID: "b", url: dst, allocatedBytes: 1_000_000, deviceID: dstStat.st_dev, inode: dstStat.st_ino, lastModified: .distantPast),
    ]
    let result = ReclaimableEstimator().estimate(records: records)
    #expect(result["a"] == 0)
    #expect(result["b"] == 0)
}

private func statFile(_ url: URL) -> stat {
    url.withUnsafeFileSystemRepresentation { ptr -> stat in
        var st = stat()
        if let ptr { stat(ptr, &st) }
        return st
    }
}
