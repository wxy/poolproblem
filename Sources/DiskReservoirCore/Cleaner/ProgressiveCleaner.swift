import Foundation

public struct ProgressiveCleanupPolicy: Equatable, Sendable {
    public let recipeID: String
    public let parentPath: String
    public let maxChildren: Int
    public let maxItemsPerRun: Int
    public let minimumAgeSeconds: TimeInterval
    public let disposition: CleanDisposition
    public let source: CleanSource
    public let reclaimableRatio: Double
    public let minimumCleanBytes: Int64

    public init(
        recipeID: String,
        parentPath: String,
        maxChildren: Int,
        maxItemsPerRun: Int,
        minimumAgeSeconds: TimeInterval,
        disposition: CleanDisposition,
        source: CleanSource = .auto,
        reclaimableRatio: Double = 1,
        minimumCleanBytes: Int64 = 0
    ) {
        self.recipeID = recipeID
        self.parentPath = parentPath
        self.maxChildren = maxChildren
        self.maxItemsPerRun = maxItemsPerRun
        self.minimumAgeSeconds = minimumAgeSeconds
        self.disposition = disposition
        self.source = source
        self.reclaimableRatio = reclaimableRatio
        self.minimumCleanBytes = minimumCleanBytes
    }
}

public struct ProgressiveCleanupOutcome: Equatable, Sendable {
    public let entries: [CleanLogEntry]
    public let freedBytes: Int64
    public let trimmedCount: Int
    public let remainingCount: Int

    public init(
        entries: [CleanLogEntry],
        freedBytes: Int64,
        trimmedCount: Int,
        remainingCount: Int
    ) {
        self.entries = entries
        self.freedBytes = freedBytes
        self.trimmedCount = trimmedCount
        self.remainingCount = remainingCount
    }

    public static let empty = ProgressiveCleanupOutcome(
        entries: [],
        freedBytes: 0,
        trimmedCount: 0,
        remainingCount: 0
    )
}

public struct ProgressiveCleanupCandidate: Equatable, Sendable {
    public let path: String
    public let name: String
    public let itemID: String
    public let estimatedBytes: Int64

    public init(path: String, name: String, itemID: String, estimatedBytes: Int64) {
        self.path = path
        self.name = name
        self.itemID = itemID
        self.estimatedBytes = estimatedBytes
    }
}

/// 对“会持续产生大量子项目”的目录做渐进式清理。
///
/// 与水线清理不同，这个清理器不依赖磁盘可用空间，而是在某个目录的一级子项
/// 超过阈值时，只删除其中最老的少量子项。这样每次任务都很轻，用户也不会等到
/// 目录爆炸时才被一次性清空。
public struct ProgressiveCleaner: Sendable {
    private let deleter: FileDeleting
    private let logStore: CleanLogStore
    private let now: @Sendable () -> Date

    public init(
        deleter: FileDeleting,
        logStore: CleanLogStore,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.deleter = deleter
        self.logStore = logStore
        self.now = now
    }

    public func run(policy: ProgressiveCleanupPolicy) throws -> ProgressiveCleanupOutcome {
        let plan = try self.plan(policy: policy)
        guard !plan.candidates.isEmpty else { return .empty }
        let estimatedTotal = plan.candidates.reduce(Int64(0)) { $0 + $1.estimatedBytes }
        guard estimatedTotal >= policy.minimumCleanBytes else { return .empty }

        var entries: [CleanLogEntry] = []
        var freedBytes: Int64 = 0
        var trimmedCount = 0
        let batchID = UUID()
        for candidate in plan.candidates {
            do {
                let deletion = try deleter.deleteReturningResult(
                    url: URL(fileURLWithPath: candidate.path),
                    disposition: policy.disposition
                )
                let reportedFreed = Int64(Double(deletion.freedBytes) * policy.reclaimableRatio)
                let entry = CleanLogEntry(
                    id: UUID(),
                    timestamp: now(),
                    itemIDs: [candidate.itemID],
                    itemNames: [candidate.name],
                    originalPaths: [candidate.path],
                    trashPaths: policy.disposition == .trash
                        ? [deletion.resultingURL?.path ?? ""]
                        : [],
                    batchID: batchID,
                    freedBytes: reportedFreed,
                    disposition: policy.disposition,
                    source: policy.source
                )
                entries.append(entry)
                freedBytes += reportedFreed
                trimmedCount += 1
            } catch {
                // 自动渐进清理应当尽力而为：单个子项失败不影响后面的子项。
                continue
            }
        }

        for entry in entries {
            try logStore.append(entry)
        }

        guard !entries.isEmpty else { return .empty }
        return ProgressiveCleanupOutcome(
            entries: entries,
            freedBytes: freedBytes,
            trimmedCount: trimmedCount,
            remainingCount: max(0, plan.count - trimmedCount)
        )
    }

    public func preview(policy: ProgressiveCleanupPolicy) throws -> ProgressiveCleanupOutcome {
        let plan = try self.plan(policy: policy)
        let entries = plan.candidates.map { candidate in
            CleanLogEntry(
                id: UUID(),
                timestamp: now(),
                itemIDs: [candidate.itemID],
                itemNames: [candidate.name],
                freedBytes: candidate.estimatedBytes,
                disposition: policy.disposition,
                source: policy.source
            )
        }
        guard !entries.isEmpty else { return .empty }
        return ProgressiveCleanupOutcome(
            entries: entries,
            freedBytes: entries.reduce(Int64(0)) { $0 + $1.freedBytes },
            trimmedCount: entries.count,
            remainingCount: max(0, plan.count - entries.count)
        )
    }

    private func plan(
        policy: ProgressiveCleanupPolicy
    ) throws -> (count: Int, candidates: [ProgressiveCleanupCandidate]) {
        let parent = URL(fileURLWithPath: policy.parentPath, isDirectory: true)
        guard FileManager.default.fileExists(atPath: parent.path) else {
            return (0, [])
        }

        let keys: Set<URLResourceKey> = [
            .isDirectoryKey,
            .isSymbolicLinkKey,
            .contentModificationDateKey,
            .creationDateKey,
            .fileSizeKey,
            .totalFileAllocatedSizeKey,
        ]
        let children = try FileManager.default.contentsOfDirectory(
            at: parent,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        )
        let cutoff = now().addingTimeInterval(-policy.minimumAgeSeconds)
        let datedChildren = children.compactMap { url -> (url: URL, date: Date)? in
            let values = try? url.resourceValues(forKeys: keys)
            guard values?.isSymbolicLink != true else { return nil }
            let date = values?.contentModificationDate
                ?? values?.creationDate
                ?? .distantPast
            guard date < cutoff else { return nil }
            return (url, date)
        }

        let count = children.count
        guard count > policy.maxChildren else {
            return (count, [])
        }
        let measuredCandidates = datedChildren.map { candidate -> ProgressiveCleanupCandidate in
            let itemID = "\(policy.recipeID):\(candidate.url.path)"
            return ProgressiveCleanupCandidate(
                path: candidate.url.path,
                name: candidate.url.lastPathComponent,
                itemID: itemID,
                estimatedBytes: Int64(
                    Double(estimatedBytes(for: candidate.url, keys: keys)) * policy.reclaimableRatio
                )
            )
        }
        let candidates = Array(
            measuredCandidates
                .sorted { $0.estimatedBytes > $1.estimatedBytes }
                .prefix(policy.maxItemsPerRun)
        )
        return (count, candidates)
    }

    private func estimatedBytes(for url: URL, keys: Set<URLResourceKey>) -> Int64 {
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
           isDirectory.boolValue {
            return POSIXDirectoryWalker.walk(
                url: url,
                itemID: "progressive-preview",
                includeRecords: false
            )?.allocatedBytes ?? 0
        }
        let values = try? url.resourceValues(forKeys: keys)
        return Int64(values?.totalFileAllocatedSize ?? values?.fileSize ?? 0)
    }
}
