import Testing
import Foundation
@testable import PoolProblem
import DiskReservoirCore

@MainActor
@Test func pnpmStoreCacheChildIsNeitherListedForCleaningNorMoved() async throws {
    let fixture = FileManager.default.temporaryDirectory
        .appendingPathComponent("pp-pnpm-child-e2e-\(UUID())", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: fixture) }
    let home = fixture.appendingPathComponent("home")
    let caches = home.appendingPathComponent("Library/Caches")
    let store = caches.appendingPathComponent("pnpm")
    let data = fixture.appendingPathComponent("data")
    try FileManager.default.createDirectory(at: store, withIntermediateDirectories: true)
    try Data(repeating: 1, count: 11_000_000).write(to: store.appendingPathComponent("package"))
    let fakePnpm = fixture.appendingPathComponent("bin/pnpm")
    try FileManager.default.createDirectory(at: fakePnpm.deletingLastPathComponent(), withIntermediateDirectories: true)
    try ("#!/bin/sh\necho '\(store.path)'\n").write(to: fakePnpm, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakePnpm.path)
    let paths = StoragePaths(baseURL: data, homeDirectory: home.path)
    let state = AppState()
    let service = AppService(
        state: state, paths: paths, automationEnabled: false,
        pnpmRunner: OwnerCommandRunner(
            recipe: .pnpmStorePrune, executable: fakePnpm.path,
            environment: ["PATH": fakePnpm.deletingLastPathComponent().path], home: home.path
        )
    )
    await service.scanNow()
    let cacheItem = try #require(state.items.first { $0.recipeID == "library-caches" })
    let rawChild = try #require(ChildDirectoryExplorer().list(
        parentPath: caches.path, growthEntries: [], protectedChildNames: []
    ).first { $0.path == store.path })
    #expect(!(await service.cacheChildren(for: cacheItem)).contains { $0.path == store.path })
    #expect(!(await service.cleanCacheChild(rawChild, in: cacheItem)))
    #expect(FileManager.default.fileExists(atPath: store.appendingPathComponent("package").path))
}

@MainActor
@Test func appServiceScanWritesSnapshot() async throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("pp-app-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let paths = StoragePaths(baseURL: dir)
    let state = AppState()
    let service = AppService(state: state, paths: paths, automationEnabled: false)
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
    let service = AppService(state: AppState(), paths: paths, automationEnabled: false)
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
    let service = AppService(state: AppState(), paths: paths, automationEnabled: false)
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
    let service = AppService(state: AppState(), paths: paths, automationEnabled: false)
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
