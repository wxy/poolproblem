import Testing
import Foundation
@testable import DiskReservoirCore

private func item(_ id: String, recipe: String, size: Int64) -> ScanItem {
    ScanItem(
        id: id, recipeID: recipe, name: id, path: "/tmp/\(id)",
        category: .xcode, safety: .safeWhileRunning, disposition: .deletePermanently,
        sizeBytes: size, allocatedBytes: size, reclaimableBytes: size,
        fileCount: 1, lastModified: nil
    )
}

@Test func ledgerTracksKnownGrowth() {
    let now = Date()
    let prev = Snapshot(
        volume: VolumeInfo(totalBytes: 1000, availableBytes: 500, timestamp: now.addingTimeInterval(-86_400)),
        items: [item("x1", recipe: "r", size: 100)]
    )
    let latest = Snapshot(
        volume: VolumeInfo(totalBytes: 1000, availableBytes: 300, timestamp: now),
        items: [item("x1", recipe: "r", size: 400)]
    )
    let entries = GrowthLedgerBuilder(minimumDeltaBytes: 50)
        .entries(previous: prev, latest: latest, homeDirectory: "/tmp")
    #expect(entries.count == 1)
    #expect(entries[0].kind == .known)
    #expect(entries[0].deltaBytes == 300)
    #expect(abs(entries[0].rateBytesPerDay - 300) < 1)
}

@Test func ledgerCapturesNewItems() {
    let now = Date()
    let prev = Snapshot(
        volume: VolumeInfo(totalBytes: 1000, availableBytes: 500, timestamp: now.addingTimeInterval(-86_400)),
        items: []
    )
    let latest = Snapshot(
        volume: VolumeInfo(totalBytes: 1000, availableBytes: 300, timestamp: now),
        items: [item("fresh", recipe: "r", size: 1_000)]
    )
    let entries = GrowthLedgerBuilder(minimumDeltaBytes: 50)
        .entries(previous: prev, latest: latest, homeDirectory: "/tmp")
    #expect(entries.contains { $0.kind == .new && $0.deltaBytes == 1_000 })
}

@Test func ledgerSkipsSmallDeltas() {
    let now = Date()
    let prev = Snapshot(
        volume: VolumeInfo(totalBytes: 1000, availableBytes: 500, timestamp: now.addingTimeInterval(-86_400)),
        items: [item("x1", recipe: "r", size: 100)]
    )
    let latest = Snapshot(
        volume: VolumeInfo(totalBytes: 1000, availableBytes: 490, timestamp: now),
        items: [item("x1", recipe: "r", size: 110)]
    )
    let entries = GrowthLedgerBuilder(minimumDeltaBytes: 1_000)
        .entries(previous: prev, latest: latest, homeDirectory: "/tmp")
    #expect(entries.isEmpty)
}

@Test func ledgerDiffsSurfaceDirectories() {
    let prevDirs = [SurfaceDirectory(path: "/tmp/cache/A", sizeBytes: 100, fileCount: 1, lastModified: nil)]
    let latestDirs = [SurfaceDirectory(path: "/tmp/cache/A", sizeBytes: 500, fileCount: 1, lastModified: nil)]
    let entries = GrowthLedgerBuilder(surfaceMinimumDeltaBytes: 200)
        .surfaceEntries(previous: prevDirs, latest: latestDirs, homeDirectory: "/tmp")
    #expect(entries.count == 1)
    #expect(entries[0].kind == .surface)
    #expect(entries[0].pattern == "~/cache/A")
    #expect(entries[0].deltaBytes == 400)
}

@Test func ledgerStoreAppendsPrunesAndKeepsSurface() throws {
    let base = FileManager.default.temporaryDirectory
        .appendingPathComponent("pp-ledger-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: base) }
    let paths = StoragePaths(baseURL: base)
    let store = GrowthLedgerStore(paths: paths)
    let now = Date()
    let entry = GrowthEntry(
        observedAt: now, elapsedDays: 1, name: "n", path: "/tmp/a",
        pattern: "~/a", kind: .surface, deltaBytes: 100, rateBytesPerDay: 100
    )
    try store.append([entry])
    #expect(try store.entries().count == 1)
    try store.saveSurface(
        [SurfaceDirectory(path: "/tmp/a", sizeBytes: 1, fileCount: 1, lastModified: nil)],
        scannedAt: now
    )
    #expect(try store.surfaceDirectories().count == 1)
    #expect(store.lastSurfaceScanAt().map { abs($0.timeIntervalSince(now)) < 1 } == true)
    let old = GrowthEntry(
        observedAt: now.addingTimeInterval(-60 * 86_400), elapsedDays: 1, name: "old", path: "/tmp/o",
        pattern: "~/o", kind: .surface, deltaBytes: 1, rateBytesPerDay: 1
    )
    try store.append([old])
    try store.prune(retainingDays: 30)
    #expect(try store.entries().count == 1)
    #expect(try store.entries().first?.name == "n")
}
