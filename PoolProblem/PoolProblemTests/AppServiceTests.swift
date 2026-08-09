import Testing
import Foundation
@testable import PoolProblem
import DiskReservoirCore

@MainActor
@Test func appServiceScanWritesSnapshot() async throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("pp-app-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let paths = StoragePaths(baseURL: dir)
    let state = AppState()
    let service = AppService(state: state, paths: paths)
    await service.scanNow()
    let snapshots = try SnapshotStore(paths: paths).snapshots()
    #expect(!snapshots.isEmpty)
    #expect(state.availableBytes > 0)
}

@MainActor
@Test func appServiceConfigRoundTrip() throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("pp-app-config-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let paths = StoragePaths(baseURL: dir)
    let service = AppService(state: AppState(), paths: paths)
    var config = Config.default
    config.waterlineGB = 42
    service.saveConfig(config)
    let loaded = service.loadConfig()
    #expect(loaded.waterlineGB == 42)
}
