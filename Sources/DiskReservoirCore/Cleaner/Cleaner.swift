import Foundation

public struct CleanOutcome: Equatable, Sendable {
    public let entries: [CleanLogEntry]
    public let freedBytes: Int64
    public let actualFreedBytes: Int64
    public let stillBelowWaterline: Bool
    public let calibrationUpdates: [String: Double]

    public init(
        entries: [CleanLogEntry],
        freedBytes: Int64,
        actualFreedBytes: Int64,
        stillBelowWaterline: Bool,
        calibrationUpdates: [String: Double] = [:]
    ) {
        self.entries = entries
        self.freedBytes = freedBytes
        self.actualFreedBytes = actualFreedBytes
        self.stillBelowWaterline = stillBelowWaterline
        self.calibrationUpdates = calibrationUpdates
    }
}

public struct Cleaner: Sendable {
    private let evaluator: RuleEvaluator
    private let deleter: FileDeleting
    private let inspector: ProcessInspecting
    private let logStore: CleanLogStore
    private let availableBytesReader: @Sendable (URL) -> Int64
    private let now: @Sendable () -> Date

    public init(
        evaluator: RuleEvaluator,
        deleter: FileDeleting,
        inspector: ProcessInspecting,
        logStore: CleanLogStore,
        availableBytesReader: @escaping @Sendable (URL) -> Int64 = {
            VolumeReader.read(fileURL: $0).availableBytes
        },
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.evaluator = evaluator
        self.deleter = deleter
        self.inspector = inspector
        self.logStore = logStore
        self.availableBytesReader = availableBytesReader
        self.now = now
    }

    /// 清理底线兜底：任何删除决定都必须经过可清理性校验。
    /// `displayOnly` 永不删除；`trashOnly` 强制降级为回收站；`regenerable` 保持原决定。
    public static func guardedDisposition(
        for disposition: CleanDisposition,
        cleanability: Cleanability
    ) -> CleanDisposition? {
        switch cleanability {
        case .displayOnly:
            return nil
        case .trashOnly:
            return .trash
        case .regenerable:
            return disposition
        }
    }

    public func run(
        scan: ScanResult,
        config: Config,
        waterlineBytes: Int64,
        forceClean: Bool = false,
        ignoreAge: Bool = false,
        source: CleanSource = .manual,
        minimumItemBytes: Int64? = nil,
        itemGrowthRates: [String: Double] = [:],
        onItemWillDelete: (@Sendable (String) -> Void)? = nil,
        onItemCleaned: (@Sendable (String, CleanDisposition) -> Void)? = nil
    ) throws -> CleanOutcome {
        var deficit = waterlineBytes - scan.volume.availableBytes
        guard deficit > 0 else {
            return CleanOutcome(entries: [], freedBytes: 0, actualFreedBytes: 0, stillBelowWaterline: false)
        }
        let availableBefore = availableBytesReader(scan.volumeURL)
        let candidates = scan.items
            .filter { !config.whitelistPaths.contains($0.path) }
            // 应用无法删除的手动项（Xcode/Finder）不进入自动/强制清理候选
            .filter { !CleanupRationale.make(for: $0).isManual }
            .filter { item in
                minimumItemBytes.map { item.reclaimableBytes >= $0 } ?? true
            }
            // 第一性原理：水线目标是“现在释放空间”。
            // 永久删除立即可释放，移入废纸篓不改变可用空间（待用户清空），
            // 因此优先清理永久删除类；同类内优先大项、再按增速。
            .sorted { left, right in
                let leftReal = left.disposition == .deletePermanently
                let rightReal = right.disposition == .deletePermanently
                if leftReal != rightReal {
                    return leftReal
                }
                if left.reclaimableBytes != right.reclaimableBytes {
                    return left.reclaimableBytes > right.reclaimableBytes
                }
                return (itemGrowthRates[left.id] ?? 0) > (itemGrowthRates[right.id] ?? 0)
            }
        var entries: [CleanLogEntry] = []
        var freedTotal: Int64 = 0
        var below = true
        let batchID = UUID()
        for item in candidates {
            guard item.reclaimableBytes > 0 else { continue }
            guard deficit > 0 else { below = false; break }
            let decision = evaluator.evaluate(
                item: item,
                isProcessRunning: { name in
                    name.map { inspector.isRunning($0) } ?? false
                },
                force: forceClean,
                ignoreAge: ignoreAge
            )
            let rawDisposition: CleanDisposition?
            switch decision.action {
            case .delete:
                rawDisposition = .deletePermanently
            case .trash:
                rawDisposition = .trash
            default:
                rawDisposition = nil
            }
            guard let rawDisposition,
                  let disposition = Cleaner.guardedDisposition(
                      for: rawDisposition,
                      cleanability: item.cleanability
                  ) else { continue }
            onItemWillDelete?(item.id)
            let targetPaths = item.paths.isEmpty ? [item.path] : item.paths
            var itemFreed: Int64 = 0
            var trashPaths: [String] = []
            var failed = false
            for target in targetPaths {
                // 单项失败（如 TCC 权限）不影响后续项：尽力而为，继续清理其他目标
                guard let deletion = try? deleter.deleteReturningResult(
                    url: URL(fileURLWithPath: target),
                    disposition: disposition
                ) else {
                    failed = true
                    break
                }
                itemFreed += deletion.freedBytes
                if let trash = deletion.resultingURL?.path {
                    trashPaths.append(trash)
                }
            }
            guard !failed else { continue }
            onItemCleaned?(item.id, disposition)
            freedTotal += itemFreed
            deficit -= itemFreed
            entries.append(CleanLogEntry(
                id: UUID(),
                timestamp: now(),
                itemIDs: [item.id],
                itemNames: [item.name],
                originalPaths: targetPaths,
                trashPaths: disposition == .trash ? trashPaths : [],
                batchID: batchID,
                freedBytes: itemFreed,
                disposition: disposition,
                source: source
            ))
        }
        if entries.isEmpty {
            below = scan.volume.availableBytes < waterlineBytes
        } else if deficit > 0 {
            below = true
        }
        for entry in entries {
            try logStore.append(entry)
        }
        let availableAfter = availableBytesReader(scan.volumeURL)
        let actualFreed = max(0, availableAfter - availableBefore)
        var calibrationUpdates: [String: Double] = [:]
        if freedTotal > 0, actualFreed > 0 {
            let runRatio = min(1, max(0, Double(actualFreed) / Double(freedTotal)))
            let cleanedRecipeIDs = Set(
                entries
                    .flatMap { $0.itemIDs }
                    .compactMap { id in scan.items.first { $0.id == id }?.recipeID }
            )
            for recipeID in cleanedRecipeIDs {
                calibrationUpdates[recipeID] = runRatio
            }
        }
        return CleanOutcome(
            entries: entries,
            freedBytes: freedTotal,
            actualFreedBytes: actualFreed,
            stillBelowWaterline: below,
            calibrationUpdates: calibrationUpdates
        )
    }
}
