import Foundation

public struct SnapshotStore: Sendable {
    private let paths: StoragePaths
    private let store: JSONStoring

    public init(paths: StoragePaths, store: JSONStoring = JSONStore()) {
        self.paths = paths
        self.store = store
    }

    public func append(_ snapshot: Snapshot) throws {
        var all = try snapshots()
        all.append(snapshot)
        all.sort { $0.volume.timestamp < $1.volume.timestamp }
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
