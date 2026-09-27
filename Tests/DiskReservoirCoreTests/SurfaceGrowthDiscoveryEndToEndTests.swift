import Foundation
import Testing
@testable import DiskReservoirCore

@Test func surfaceGrowthDiscoveryEndToEnd() throws {
    let fixture = FileManager.default.temporaryDirectory
        .appendingPathComponent("pp-growth-e2e-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: fixture) }
    let root = fixture.appendingPathComponent("home/Library/Caches", isDirectory: true)
    let source = root.appendingPathComponent("Example", isDirectory: true)
    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
    try Data(repeating: 0x41, count: 100).write(to: source.appendingPathComponent("initial.bin"))

    let store = GrowthLedgerStore(paths: StoragePaths(
        baseURL: fixture.appendingPathComponent("data", isDirectory: true),
        homeDirectory: fixture.appendingPathComponent("home").path
    ))
    let discovery = SurfaceGrowthDiscovery(
        store: store,
        roots: [root.path],
        homeDirectory: fixture.appendingPathComponent("home").path,
        minimumDeltaBytes: 50
    )
    let baselineAt = Date(timeIntervalSince1970: 1_700_000_000)
    let baseline = try discovery.run(at: baselineAt)
    #expect(baseline.establishedBaseline)
    #expect(baseline.entries.isEmpty)
    #expect(store.lastSurfaceScanAt() == baselineAt)
    #expect(try store.surfaceSnapshot()?.latestEntries?.isEmpty == true)

    try Data(repeating: 0x42, count: 300).write(to: source.appendingPathComponent("growth.bin"))
    let newSource = root.appendingPathComponent("NewSource", isDirectory: true)
    try FileManager.default.createDirectory(at: newSource, withIntermediateDirectories: true)
    try Data(repeating: 0x43, count: 300).write(to: newSource.appendingPathComponent("new.bin"))
    let observedAt = baselineAt.addingTimeInterval(2 * 86_400)
    let growth = try discovery.run(at: observedAt)
    #expect(!growth.establishedBaseline)
    #expect(growth.entries.count == 2)
    #expect(growth.entries.allSatisfy { $0.deltaBytes == 300 })
    #expect(growth.entries.allSatisfy { $0.elapsedDays == 2 })
    #expect(growth.entries.allSatisfy { $0.rateBytesPerDay == 150 })
    #expect(growth.entries.contains {
        URL(fileURLWithPath: $0.path).lastPathComponent == "NewSource"
    })
    #expect(try store.surfaceSnapshot()?.latestEntries?.count == 2)
    #expect(try store.entries().isEmpty)
    #expect(store.lastSurfaceScanAt() == observedAt)

    let unchanged = try discovery.run(at: observedAt.addingTimeInterval(86_400))
    #expect(unchanged.entries.isEmpty)
    #expect(try store.surfaceSnapshot()?.latestEntries?.isEmpty == true)
    #expect(try store.entries().isEmpty)

    #expect(throws: SurfaceGrowthDiscoveryError.invalidObservationTime) {
        try discovery.run(at: observedAt)
    }
    #expect(store.lastSurfaceScanAt() == observedAt.addingTimeInterval(86_400))

    let missing = SurfaceGrowthDiscovery(
        store: store,
        roots: [fixture.appendingPathComponent("missing").path],
        homeDirectory: fixture.appendingPathComponent("home").path,
        minimumDeltaBytes: 50
    )
    #expect(throws: SurfaceGrowthDiscoveryError.unavailableRoots) {
        try missing.run(at: observedAt.addingTimeInterval(2 * 86_400))
    }
    #expect(store.lastSurfaceScanAt() == observedAt.addingTimeInterval(86_400))
}

@Test func surfaceGrowthDiscoveryKeepsSmallBaselineDirectories() throws {
    let fixture = FileManager.default.temporaryDirectory
        .appendingPathComponent("pp-growth-small-baseline-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: fixture) }
    let root = fixture.appendingPathComponent("home/Library/Caches", isDirectory: true)
    let source = root.appendingPathComponent("SmallAtBaseline", isDirectory: true)
    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
    try Data(repeating: 0x41, count: 30).write(to: source.appendingPathComponent("initial.bin"))

    let home = fixture.appendingPathComponent("home").path
    let store = GrowthLedgerStore(paths: StoragePaths(
        baseURL: fixture.appendingPathComponent("data", isDirectory: true),
        homeDirectory: home
    ))
    let discovery = SurfaceGrowthDiscovery(
        store: store,
        roots: [root.path],
        homeDirectory: home,
        minimumDeltaBytes: 50
    )
    let baselineAt = Date(timeIntervalSince1970: 1_700_000_000)
    _ = try discovery.run(at: baselineAt)
    #expect(try store.surfaceSnapshot()?.directories.first?.sizeBytes == 30)

    try Data(repeating: 0x42, count: 60).write(to: source.appendingPathComponent("growth.bin"))
    let growth = try discovery.run(at: baselineAt.addingTimeInterval(86_400))
    #expect(growth.entries.count == 1)
    #expect(growth.entries.first?.deltaBytes == 60)
    #expect(growth.entries.first?.rateBytesPerDay == 60)
}
