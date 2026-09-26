import Testing
import Foundation
@testable import DiskReservoirCore

@Test func attributionMatchesSuffixUnderAnyHome() {
    let entry = AttributionCatalog.attribution(
        forPath: "/Users/alice/Library/Application Support/com.tencent.xinWeChat"
    )
    #expect(entry?.name == "微信数据")
    #expect(entry?.layer == .info)
}

@Test func attributionMatchesPathComponentForGroupContainers() {
    let entry = AttributionCatalog.attribution(
        forPath: "/Users/alice/Library/Group Containers/group.A1B2.dev.orbstack/data"
    )
    #expect(entry?.name == "OrbStack 数据")
    #expect(entry?.layer == .asset)
}

@Test func attributionPrefersDeeperPattern() {
    // 更深的模式优先：Slack 缓存子目录命中缓存条目，而不是外层 Slack 数据条目。
    let cache = AttributionCatalog.attribution(
        forPath: "/Users/alice/Library/Application Support/Slack/Cache"
    )
    #expect(cache?.name == "Slack 缓存")

    let container = AttributionCatalog.attribution(
        forPath: "/Users/alice/Library/Application Support/Slack"
    )
    #expect(container?.name == "Slack 数据")
    #expect(container?.cacheSubdirectory == "Cache")
}

@Test func attributionIsNilForUnknownPaths() {
    #expect(AttributionCatalog.attribution(forPath: "/Users/alice/RandomProject") == nil)
    #expect(AttributionCatalog.displayName(forPath: "/Users/alice/RandomProject") == nil)
}

@Test func cleanCandidateLayerCoversGoAndGradleCaches() {
    let go = AttributionCatalog.attribution(forPath: "/Users/alice/.cache/go-build")
    #expect(go?.layer == .cleanCandidate)
    let gradle = AttributionCatalog.attribution(forPath: "/Users/alice/.gradle/caches")
    #expect(gradle?.layer == .cleanCandidate)
    // non-target：Cargo 的 registry/src 是混合态，绝不识别为清理候选。
    let cargoSource = AttributionCatalog.attribution(forPath: "/Users/alice/.cargo/registry/src")
    #expect(cargoSource?.layer != .cleanCandidate)
}

@Test func surfaceEntriesUseCatalogNames() throws {
    let wechat = "/Users/alice/Library/Application Support/com.tencent.xinWeChat"
    let builder = GrowthLedgerBuilder()
    let previous = [SurfaceDirectory(path: wechat, sizeBytes: 5_000_000_000, fileCount: 100, lastModified: nil)]
    let latest = [SurfaceDirectory(path: wechat, sizeBytes: 5_400_000_000, fileCount: 110, lastModified: nil)]
    let entries = builder.surfaceEntries(previous: previous, latest: latest)
    #expect(entries.count == 1)
    #expect(entries.first?.name == "微信数据")
}

@Test func unknownSurfaceEntriesFallBackToLastPathComponent() throws {
    let path = "/Users/alice/Library/Caches/SomethingUnknown"
    let builder = GrowthLedgerBuilder()
    let previous = [SurfaceDirectory(path: path, sizeBytes: 1_000_000_000, fileCount: 10, lastModified: nil)]
    let latest = [SurfaceDirectory(path: path, sizeBytes: 1_500_000_000, fileCount: 12, lastModified: nil)]
    let entries = builder.surfaceEntries(previous: previous, latest: latest)
    #expect(entries.first?.name == "SomethingUnknown")
}

@Test func drillDownExpandsOnlyMatchedEntriesWithCacheHint() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("pp-attrib-drill-\(UUID().uuidString)", isDirectory: true)
    let slack = root.appendingPathComponent("Library/Application Support/Slack", isDirectory: true)
    try FileManager.default.createDirectory(at: slack.appendingPathComponent("Cache"), withIntermediateDirectories: true)
    try Data(repeating: 0x41, count: 60_000_000).write(to: slack.appendingPathComponent("Cache/f.bin"))
    let plain = root.appendingPathComponent("Library/Application Support/PlainApp", isDirectory: true)
    try FileManager.default.createDirectory(at: plain, withIntermediateDirectories: true)
    try Data(repeating: 0x41, count: 60_000_000).write(to: plain.appendingPathComponent("f.bin"))
    defer { try? FileManager.default.removeItem(at: root) }

    let surface = [
        SurfaceDirectory(path: slack.path, sizeBytes: 60_000_000, fileCount: 1, lastModified: nil),
        SurfaceDirectory(path: plain.path, sizeBytes: 60_000_000, fileCount: 1, lastModified: nil),
    ]
    let drilled = AttributionCatalog.drillDown(directories: surface, minimumSizeBytes: 50_000_000)
    // 只展开命中识别表且声明 cacheSubdirectory 的条目（Slack），PlainApp 不动。
    #expect(drilled.count == 1)
    #expect(drilled.first?.path == slack.appendingPathComponent("Cache").path)
    #expect((drilled.first?.sizeBytes ?? 0) >= 60_000_000)
}
