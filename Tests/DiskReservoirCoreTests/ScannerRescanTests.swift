import Testing
import Foundation
@testable import DiskReservoirCore

@Test func rescanMeasuresSingleRecipePath() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("pp-rescan-\(UUID().uuidString)", isDirectory: true)
    let cache = root.appendingPathComponent("Cache", isDirectory: true)
    try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try Data(repeating: 0x41, count: 123_456).write(to: cache.appendingPathComponent("f.bin"))
    let recipe = Recipe(
        id: "r", name: "R", category: .common, safety: .safeWhileRunning,
        disposition: .deletePermanently, cleanability: .regenerable,
        defaultAgeDays: 7, minimumSizeMB: 0, processName: nil,
        resolvePaths: { _ in [cache.path] }
    )
    let items = Scanner().rescan(path: cache.path, recipe: recipe, homeDirectory: root.path)
    #expect(items.count == 1)
    #expect(items[0].sizeBytes == 123_456)
    #expect(items[0].path == cache.path)
}

@Test func rescanReturnsEmptyForMissingPath() {
    let recipe = Recipe(
        id: "r", name: "R", category: .common, safety: .safeWhileRunning,
        disposition: .deletePermanently, cleanability: .regenerable,
        defaultAgeDays: 7, minimumSizeMB: 0, processName: nil,
        resolvePaths: { _ in ["/tmp/nope"] }
    )
    let items = Scanner().rescan(
        path: "/tmp/definitely-missing-\(UUID().uuidString)",
        recipe: recipe,
        homeDirectory: NSHomeDirectory()
    )
    #expect(items.isEmpty)
}
