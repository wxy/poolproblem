import Testing
import Foundation
@testable import DiskReservoirCore

@Test func snapshotStoreAppendsAndPrunes() throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("pp-store-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let paths = StoragePaths(baseURL: dir)
    let store = SnapshotStore(paths: paths)
    let now = Date()
    let old = Snapshot(
        volume: VolumeInfo(totalBytes: 100, availableBytes: 90, timestamp: now.addingTimeInterval(-100 * 86_400)),
        items: []
    )
    let fresh = Snapshot(
        volume: VolumeInfo(totalBytes: 100, availableBytes: 95, timestamp: now),
        items: []
    )
    try store.append(old)
    try store.append(fresh)
    #expect(try store.snapshots().count == 2)
    try store.prune(retainingDays: 30)
    #expect(try store.snapshots().count == 1)
    #expect(try store.snapshots().first?.volume.availableBytes == 95)
}
