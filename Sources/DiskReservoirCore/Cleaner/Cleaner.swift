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

    public func run(
        scan: ScanResult,
        config: Config,
        waterlineBytes: Int64,
        forceClean: Bool = false,
        source: CleanSource = .manual,
        onItemWillDelete: (@Sendable (String) -> Void)? = nil,
        onItemCleaned: (@Sendable (String) -> Void)? = nil
    ) throws -> CleanOutcome {
        var deficit = waterlineBytes - scan.volume.availableBytes
        guard deficit > 0 else {
            return CleanOutcome(entries: [], freedBytes: 0, actualFreedBytes: 0, stillBelowWaterline: false)
        }
        let availableBefore = availableBytesReader(scan.volumeURL)
        let candidates = scan.items
            .filter { !config.whitelistPaths.contains($0.path) }
            // 小项目优先：浅目录处理快，能尽早看到清理进度；
            // 大而深的目录（如 XCTestDevices 快照）排到后面
            .sorted { $0.reclaimableBytes < $1.reclaimableBytes }
        var entries: [CleanLogEntry] = []
        var freedTotal: Int64 = 0
        var below = true
        for item in candidates {
            guard item.reclaimableBytes > 0 else { continue }
            guard deficit > 0 else { below = false; break }
            let decision = evaluator.evaluate(
                item: item,
                isProcessRunning: { name in
                    name.map { inspector.isRunning($0) } ?? false
                },
                force: forceClean
            )
            let disposition: CleanDisposition?
            switch decision.action {
            case .delete:
                disposition = .deletePermanently
            case .trash:
                disposition = .trash
            default:
                disposition = nil
            }
            guard let disposition else { continue }
            onItemWillDelete?(item.id)
            let freed = try deleter.delete(url: URL(fileURLWithPath: item.path), disposition: disposition)
            onItemCleaned?(item.id)
            freedTotal += freed
            deficit -= freed
            entries.append(CleanLogEntry(
                id: UUID(),
                timestamp: now(),
                itemIDs: [item.id],
                freedBytes: freed,
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
