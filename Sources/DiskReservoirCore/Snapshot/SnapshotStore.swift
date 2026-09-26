import Foundation

public struct SnapshotStore: Sendable {
    private let paths: StoragePaths
    private let store: JSONStoring

    public init(paths: StoragePaths, store: JSONStoring = JSONStore()) {
        self.paths = paths
        self.store = store
    }

    public func append(
        _ snapshot: Snapshot,
        maximumCount: Int = 1_000,
        minimumIncrementalInterval: TimeInterval = 15 * 60
    ) throws {
        var all = try snapshots()
        if snapshot.source == .incremental,
           let last = all.last,
           last.source == .incremental,
           snapshot.volume.timestamp.timeIntervalSince(last.volume.timestamp) < minimumIncrementalInterval {
            all[all.count - 1] = snapshot
        } else {
            all.append(snapshot)
        }
        all.sort { $0.volume.timestamp < $1.volume.timestamp }
        if maximumCount > 0, all.count > maximumCount {
            all = Array(all.suffix(maximumCount))
        }
        try store.save(all, to: paths.snapshotsURL)
    }

    public func snapshots() throws -> [Snapshot] {
        try store.load([Snapshot].self, from: paths.snapshotsURL) ?? []
    }

    public func prune(retainingDays: Int = 90) throws {
        let cutoff = Date().addingTimeInterval(-Double(retainingDays) * 86_400)
        let kept = try snapshots().filter { $0.volume.timestamp >= cutoff }
        try store.save(kept, to: paths.snapshotsURL)
    }
}
