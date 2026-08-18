import Foundation

/// 表面扫描快照（最近一次）。
public struct SurfaceSnapshot: Codable, Sendable {
    public let scannedAt: Date
    public let directories: [SurfaceDirectory]

    public init(scannedAt: Date, directories: [SurfaceDirectory]) {
        self.scannedAt = scannedAt
        self.directories = directories
    }
}

/// 增长台账持久化：条目按时间排序，滚动保留最近 N 天；表面快照单独保存。
public struct GrowthLedgerStore: Sendable {
    private let paths: StoragePaths
    private let store: JSONStoring

    public init(paths: StoragePaths, store: JSONStoring = JSONStore()) {
        self.paths = paths
        self.store = store
    }

    public func entries() throws -> [GrowthEntry] {
        try store.load([GrowthEntry].self, from: paths.growthLedgerURL) ?? []
    }

    public func append(_ entries: [GrowthEntry]) throws {
        var all = try self.entries()
        all.append(contentsOf: entries)
        all.sort { $0.observedAt < $1.observedAt }
        try store.save(all, to: paths.growthLedgerURL)
    }

    public func prune(retainingDays: Int = 30) throws {
        let cutoff = Date().addingTimeInterval(-Double(retainingDays) * 86_400)
        let kept = try entries().filter { $0.observedAt >= cutoff }
        try store.save(kept, to: paths.growthLedgerURL)
    }

    public func saveSurface(_ dirs: [SurfaceDirectory], scannedAt: Date) throws {
        try store.save(SurfaceSnapshot(scannedAt: scannedAt, directories: dirs), to: paths.surfaceSnapshotURL)
    }

    public func surfaceDirectories() throws -> [SurfaceDirectory] {
        try store.load(SurfaceSnapshot.self, from: paths.surfaceSnapshotURL)?.directories ?? []
    }

    public func lastSurfaceScanAt() -> Date? {
        (try? store.load(SurfaceSnapshot.self, from: paths.surfaceSnapshotURL))?.scannedAt
    }
}
