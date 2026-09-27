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
    /// `displayOnly` / `watchOnly` 永不删除；`trashOnly` 强制降级为回收站。
    public static func guardedDisposition(
        for disposition: CleanDisposition,
        cleanability: Cleanability
    ) -> CleanDisposition? {
        switch cleanability {
        case .displayOnly, .watchOnly:
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
            .filter { !RuleEvaluator.isPathProtected(item: $0, whitelistPaths: config.whitelistPaths) }
            // 应用无法删除的手动项（Xcode/Finder）不进入自动/强制清理候选
            .filter { !CleanupRationale.make(for: $0).isManual }
            // 仅按子目录清理的项（如 ~/Library/Caches）绝不整项删除
            .filter { !$0.cleanByChildOnly }
            .filter { item in
                minimumItemBytes.map { item.reclaimableBytes >= $0 } ?? true
            }
            // Automatic cleanup requires positive recipe authorization. Neither
            // "regenerable" nor the absence of activity is sufficient proof.
            .filter { item in
                source != .auto || (
                    item.allowsAutomaticPermanentDeletion
                        && item.cleanability == .regenerable
                        && item.disposition == .deletePermanently
                )
            }
            // Safety eligibility is established above. Under disk pressure,
            // fast-growing safe caches go first so the cleanup addresses the
            // source that is actively worsening the shortage. Unknown growth
            // remains unknown and sorts behind measured positive growth.
            .sorted { left, right in
                if source == .auto {
                    let leftRate = itemGrowthRates[left.id]
                    let rightRate = itemGrowthRates[right.id]
                    let leftGrowing = (leftRate ?? 0) > 0
                    let rightGrowing = (rightRate ?? 0) > 0
                    if leftGrowing != rightGrowing { return leftGrowing }
                    if let leftRate, let rightRate, leftRate != rightRate {
                        return leftRate > rightRate
                    }
                    if leftRate != nil, rightRate == nil { return true }
                    if leftRate == nil, rightRate != nil { return false }
                }
                let leftReal = left.disposition == .deletePermanently
                let rightReal = right.disposition == .deletePermanently
                if leftReal != rightReal {
                    return leftReal
                }
                if left.reclaimableBytes != right.reclaimableBytes {
                    return left.reclaimableBytes > right.reclaimableBytes
                }
                return left.id < right.id
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
            // Moving data to Trash does not recover disk capacity. Automatic
            // waterline cleanup may only do it when the same run is explicitly
            // configured to empty this app's own batches afterwards.
            if source == .auto,
               disposition == .trash,
               !config.autoEmptyOwnTrashBatches {
                continue
            }
            onItemWillDelete?(item.id)
            let targetPaths = item.paths.isEmpty ? [item.path] : item.paths
            var itemFreed: Int64 = 0
            for target in targetPaths {
                guard !PackageManagerRecipes.isLegacyPnpmPath(target, homeDirectory: scan.volumeURL.path) else {
                    continue
                }
                // 单项失败（如 TCC 权限）不影响后续项：尽力而为，继续清理其他目标
                guard let deletion = try? deleter.deleteReturningResult(
                    url: URL(fileURLWithPath: target),
                    disposition: disposition
                ) else {
                    continue
                }
                let entry = CleanLogEntry(
                    id: UUID(),
                    timestamp: now(),
                    itemIDs: [item.id],
                    itemNames: [item.name],
                    originalPaths: [target],
                    trashPaths: disposition == .trash ? [deletion.resultingURL?.path ?? ""] : [],
                    batchID: batchID,
                    freedBytes: deletion.freedBytes,
                    disposition: disposition,
                    source: source
                )
                do {
                    // Journal each successful path immediately. A later path
                    // failure can no longer erase recovery metadata for work
                    // that has already happened.
                    try logStore.append(entry)
                } catch {
                    if disposition == .trash,
                       let moved = deletion.resultingURL,
                       FileManager.default.fileExists(atPath: moved.path),
                       !FileManager.default.fileExists(atPath: target) {
                        try? FileManager.default.moveItem(at: moved, to: URL(fileURLWithPath: target))
                    }
                    if disposition == .deletePermanently { throw error }
                    continue
                }
                entries.append(entry)
                itemFreed += deletion.freedBytes
            }
            guard itemFreed > 0 else { continue }
            onItemCleaned?(item.id, disposition)
            freedTotal += itemFreed
            if disposition == .deletePermanently || config.autoEmptyOwnTrashBatches {
                deficit -= itemFreed
            }
        }
        if entries.isEmpty {
            below = scan.volume.availableBytes < waterlineBytes
        } else if deficit > 0 {
            below = true
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
