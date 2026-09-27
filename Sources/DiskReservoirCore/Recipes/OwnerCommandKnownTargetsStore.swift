import Foundation

/// Durable safety history for owner-managed store paths. Snapshot retention
/// must not erase a previously observed target while its files still exist.
public struct OwnerCommandKnownTargetsStore: Sendable {
    public struct State: Codable, Sendable {
        public var paths: [String]
        /// Once capacity was exceeded, deleted history is unknown. Callers
        /// must fail closed for broad raw-path cleanup.
        public var overflowed: Bool

        public init(paths: [String] = [], overflowed: Bool = false) {
            self.paths = paths
            self.overflowed = overflowed
        }
    }

    public static let maximumPaths = 1_024
    private static let lock = NSLock()
    private let pathsConfig: StoragePaths
    private let store: JSONStoring

    public init(paths: StoragePaths, store: JSONStoring = JSONStore()) {
        self.pathsConfig = paths
        self.store = store
    }

    public func state() throws -> State {
        Self.lock.lock(); defer { Self.lock.unlock() }
        return try read()
    }

    public func paths() throws -> [String] { try state().paths }

    @discardableResult
    public func record(_ newPaths: [String]) throws -> State {
        Self.lock.lock(); defer { Self.lock.unlock() }
        var history = try read()
        for raw in newPaths {
            guard let canonical = canonicalStorePath(raw) else { continue }
            history.paths.removeAll { $0 == canonical }
            history.paths.append(canonical)
        }
        if history.paths.count > Self.maximumPaths {
            history.overflowed = true
            history.paths = Array(history.paths.suffix(Self.maximumPaths))
        }
        try store.save(history, to: fileURL)
        return history
    }

    /// One-time or repeatable migration from the retained snapshots. `record`
    /// de-duplicates, so replaying startup history cannot grow the file.
    @discardableResult
    public func migrate(snapshots: [Snapshot]) throws -> State {
        try record(snapshots.flatMap { snapshot in
            snapshot.items.filter {
                $0.recipeID == OwnerCommandRecipe.pnpmStorePrune.id
            }.map(\.path)
        })
    }

    private var fileURL: URL {
        pathsConfig.baseURL.appendingPathComponent("pnpm-known-store-paths.json")
    }

    private func read() throws -> State {
        try store.load(State.self, from: fileURL) ?? State()
    }

    private func canonicalStorePath(_ raw: String) -> String? {
        guard raw.hasPrefix("/"), !raw.contains("\0"), !raw.contains("\r"),
              !raw.contains("\n"), raw.utf8.count <= 4_096 else { return nil }
        let canonical = URL(fileURLWithPath: raw)
            .resolvingSymlinksInPath().standardizedFileURL.path
        let home = URL(fileURLWithPath: pathsConfig.homeDirectory)
            .resolvingSymlinksInPath().standardizedFileURL.path
        guard canonical != "/", canonical != home,
              URL(fileURLWithPath: canonical).pathComponents.count > 2 else { return nil }
        return canonical
    }
}
