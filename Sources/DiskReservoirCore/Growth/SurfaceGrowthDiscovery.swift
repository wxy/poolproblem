import Foundation

public enum SurfaceGrowthDiscoveryError: Error, Equatable, Sendable {
    case unavailableRoots
    case invalidObservationTime
}

public struct SurfaceGrowthDiscoveryResult: Sendable {
    public let entries: [GrowthEntry]
    public let establishedBaseline: Bool
}

/// User-triggered comparison of the existing surface-scan roots. This never
/// participates in automatic cleanup or adds new deletion candidates.
public struct SurfaceGrowthDiscovery: Sendable {
    private let store: GrowthLedgerStore
    private let roots: [String]
    private let homeDirectory: String
    private let minimumDeltaBytes: Int64

    public init(
        store: GrowthLedgerStore,
        roots: [String],
        homeDirectory: String,
        minimumDeltaBytes: Int64 = 200 << 20
    ) {
        self.store = store
        self.roots = roots
        self.homeDirectory = homeDirectory
        self.minimumDeltaBytes = minimumDeltaBytes
    }

    public func run(at observedAt: Date = Date()) throws -> SurfaceGrowthDiscoveryResult {
        let previous = try store.surfaceSnapshot()
        if let previous, observedAt <= previous.scannedAt {
            throw SurfaceGrowthDiscoveryError.invalidObservationTime
        }

        // An unreadable existing root must not replace a good baseline with a
        // partial snapshot. Missing optional roots are simply not scanned.
        let presentRoots = roots.filter { POSIXDirectoryWalker.itemExists(path: $0) }
        guard !presentRoots.isEmpty,
              presentRoots.allSatisfy({ POSIXDirectoryWalker.firstLevelCount(path: $0) != nil })
        else { throw SurfaceGrowthDiscoveryError.unavailableRoots }

        // Keep even small directories in the baseline. Filtering by current
        // size would later misreport their entire size as new growth.
        let latest = SurfaceScanner().scan(roots: presentRoots, minimumSizeBytes: 0)
        let entries = previous.map {
            GrowthLedgerBuilder(surfaceMinimumDeltaBytes: minimumDeltaBytes).surfaceEntries(
                previous: $0.directories,
                latest: latest,
                previousScannedAt: $0.scannedAt,
                observedAt: observedAt,
                homeDirectory: homeDirectory
            )
        } ?? []
        try store.saveSurface(latest, scannedAt: observedAt, latestEntries: entries)
        return SurfaceGrowthDiscoveryResult(
            entries: entries,
            establishedBaseline: previous == nil
        )
    }
}
