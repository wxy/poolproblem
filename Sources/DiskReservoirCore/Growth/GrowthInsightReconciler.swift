import Darwin
import Foundation

/// A cheap current existence check. It does not measure current disk use.
public enum GrowthPathStatus: Equatable, Sendable {
    case present
    case missing
    case unavailable

    public static func probe(_ path: String) -> Self {
        guard !path.isEmpty else { return .unavailable }
        let result = path.withCString { Darwin.access($0, F_OK) }
        if result == 0 { return .present }
        switch errno {
        case ENOENT, ENOTDIR: return .missing
        default: return .unavailable
        }
    }
}

public struct GrowthInsightVisibleEntry: Identifiable, Sendable {
    public let entry: GrowthEntry
    public let pathStatus: GrowthPathStatus

    public var id: UUID { entry.id }
}

public struct GrowthInsightReport: Sendable {
    public let visibleEntries: [GrowthInsightVisibleEntry]
    public let removedCount: Int
    public let checkedAt: Date
}

/// Reconciles a historical growth log with cheap live path facts. Historical
/// records remain in the ledger even when their paths no longer exist.
public struct GrowthInsightReconciler: Sendable {
    public init() {}

    public func reconcile(
        entries: [GrowthEntry],
        checkedAt: Date = Date(),
        limit: Int = 30
    ) -> GrowthInsightReport {
        let latest = GrowthInsightMerger.merge(entries)
        var visible: [GrowthInsightVisibleEntry] = []
        var removedCount = 0
        for entry in latest {
            let status = GrowthPathStatus.probe(entry.path)
            if status == .missing {
                removedCount += 1
            } else if visible.count < limit {
                visible.append(GrowthInsightVisibleEntry(entry: entry, pathStatus: status))
            }
        }
        return GrowthInsightReport(
            visibleEntries: visible,
            removedCount: removedCount,
            checkedAt: checkedAt
        )
    }
}
