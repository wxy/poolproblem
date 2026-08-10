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

@MainActor
@Test func keepItemPersistsAndUnkeeps() throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("pp-app-keep-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let paths = StoragePaths(baseURL: dir)
    let service = AppService(state: AppState(), paths: paths)
    let item = ScanItem(
        id: "keepme", recipeID: "r", name: "N", path: "/tmp/keepme",
        category: .common, safety: .safeWhileRunning, disposition: .trash,
        sizeBytes: 1, allocatedBytes: 1, reclaimableBytes: 1,
        fileCount: 1, lastModified: nil
    )
    service.keepItem(item)
    var loaded = try JSONStore().load(Config.self, from: paths.configURL)
    #expect(loaded?.keptItemIDs.contains(item.id) == true)
    service.unkeepItem(item.id)
    loaded = try JSONStore().load(Config.self, from: paths.configURL)
    #expect(loaded?.keptItemIDs.contains(item.id) == false)
}

@MainActor
@Test func settingsSavePreservesKeptItemIDs() throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("pp-app-merge-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let paths = StoragePaths(baseURL: dir)
    let service = AppService(state: AppState(), paths: paths)
    service.keepItem(ScanItem(
        id: "keep", recipeID: "r", name: "N", path: "/tmp/keep",
        category: .common, safety: .safeWhileRunning, disposition: .trash,
        sizeBytes: 1, allocatedBytes: 1, reclaimableBytes: 1,
        fileCount: 1, lastModified: nil
    ))
    var config = Config.default
    config.waterlineGB = 42
    service.saveConfig(config)
    let loaded = try JSONStore().load(Config.self, from: paths.configURL)
    #expect(loaded?.waterlineGB == 42)
    #expect(loaded?.keptItemIDs.isEmpty == false)
}
