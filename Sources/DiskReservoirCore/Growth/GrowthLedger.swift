import Foundation

/// 从相邻快照（以及相邻表面快照）对比出增长条目。
public struct GrowthLedgerBuilder: Sendable {
    public let minimumDeltaBytes: Int64
    public let surfaceMinimumDeltaBytes: Int64

    public init(
        minimumDeltaBytes: Int64 = 100 << 20,
        surfaceMinimumDeltaBytes: Int64 = 200 << 20
    ) {
        self.minimumDeltaBytes = minimumDeltaBytes
        self.surfaceMinimumDeltaBytes = surfaceMinimumDeltaBytes
    }

    /// 相邻快照 diff：已知项增长、新出现项。
    /// 注：残差（未覆盖空间）不再生成条目——它无法归因到目录，
    /// 目录级归因由表面扫描/FSEvents/主动发现承担。
    public func entries(
        previous: Snapshot?,
        latest: Snapshot,
        homeDirectory: String = NSHomeDirectory()
    ) -> [GrowthEntry] {
        guard let previous else { return [] }
        let interval = latest.volume.timestamp.timeIntervalSince(previous.volume.timestamp)
        let elapsed = max(interval / 86_400, 1.0 / 86_400)
        var result: [GrowthEntry] = []
        let prevByID = Dictionary(uniqueKeysWithValues: previous.items.map { ($0.id, $0) })
        for item in latest.items {
            let delta = item.sizeBytes - (prevByID[item.id]?.sizeBytes ?? 0)
            guard delta >= minimumDeltaBytes else { continue }
            let kind: GrowthKind = prevByID[item.id] == nil ? .new : .known
            result.append(GrowthEntry(
                observedAt: latest.volume.timestamp,
                elapsedDays: elapsed,
                itemID: item.id,
                recipeID: item.recipeID,
                name: item.name,
                path: item.path,
                pattern: PathPatternizer.patternize(item.path, homeDirectory: homeDirectory),
                kind: kind,
                deltaBytes: delta,
                rateBytesPerDay: Double(delta) / elapsed
            ))
        }
        return result
    }

    /// 表面快照 diff：仅产出超过阈值的目录增量，按真实观测间隔计算速率。
    public func surfaceEntries(
        previous: [SurfaceDirectory],
        latest: [SurfaceDirectory],
        previousScannedAt: Date,
        observedAt: Date,
        homeDirectory: String = NSHomeDirectory()
    ) -> [GrowthEntry] {
        let elapsedDays = observedAt.timeIntervalSince(previousScannedAt) / 86_400
        guard elapsedDays > 0 else { return [] }
        let prevByPath = Dictionary(uniqueKeysWithValues: previous.map { ($0.path, $0.sizeBytes) })
        var result: [GrowthEntry] = []
        for dir in latest {
            // A directory that appeared after the baseline grew from zero.
            // The baseline itself is handled by SurfaceGrowthDiscovery and
            // never emitted as an all-new growth report.
            let old = prevByPath[dir.path] ?? 0
            let delta = dir.sizeBytes - old
            guard delta >= surfaceMinimumDeltaBytes else { continue }
            result.append(GrowthEntry(
                observedAt: observedAt,
                elapsedDays: elapsedDays,
                name: URL(fileURLWithPath: dir.path).lastPathComponent,
                path: dir.path,
                pattern: PathPatternizer.patternize(dir.path, homeDirectory: homeDirectory),
                kind: .surface,
                deltaBytes: delta,
                rateBytesPerDay: Double(delta) / elapsedDays
            ))
        }
        return result.sorted { $0.deltaBytes > $1.deltaBytes }
    }
}
