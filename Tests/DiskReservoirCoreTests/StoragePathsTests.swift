import Testing
import Foundation
@testable import DiskReservoirCore

@Test func dataDirRespectsEnvironmentOverride() {
    setenv("POOLPROBLEM_DATA_DIR", "/tmp/pp-test-data", 1)
    defer { unsetenv("POOLPROBLEM_DATA_DIR") }
    let paths = StoragePaths()
    #expect(paths.baseURL.path == "/tmp/pp-test-data")
    #expect(paths.snapshotsURL.lastPathComponent == "snapshots.json")
    #expect(paths.configURL.lastPathComponent == "config.json")
    #expect(paths.cleanLogURL.lastPathComponent == "clean-log.json")
    #expect(paths.growthLedgerURL.lastPathComponent == "growth-ledger.json")
    #expect(paths.surfaceSnapshotURL.lastPathComponent == "surface-snapshot.json")
    #expect(paths.recipeSuggestionsURL.lastPathComponent == "recipe-suggestions.json")
}

@Test func jsonStoreRoundTrip() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("pp-test-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: url) }
    let store = JSONStore()
    try store.save([1, 2, 3], to: url)
    let loaded: [Int]? = try store.load([Int].self, from: url)
    #expect(loaded == [1, 2, 3])
    let missing: [Int]? = try store.load([Int].self, from: url.appendingPathExtension("nope"))
    #expect(missing == nil)
}
