import Foundation

public struct CleanLogStore: Sendable {
    private let paths: StoragePaths
    private let store: JSONStoring

    public init(paths: StoragePaths, store: JSONStoring = JSONStore()) {
        self.paths = paths
        self.store = store
    }

    public func entries() throws -> [CleanLogEntry] {
        try store.load([CleanLogEntry].self, from: paths.cleanLogURL) ?? []
    }

    public func append(_ entry: CleanLogEntry) throws {
        var all = try entries()
        all.append(entry)
        try store.save(all, to: paths.cleanLogURL)
    }

    public func prune(retainingDays: Int = 90) throws {
        let cutoff = Date().addingTimeInterval(-Double(retainingDays) * 86_400)
        let kept = try entries().filter { $0.timestamp >= cutoff }
        try store.save(kept, to: paths.cleanLogURL)
    }
}
