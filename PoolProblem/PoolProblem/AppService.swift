import Foundation
import DiskReservoirCore

@MainActor
final class AppService {
    private let state: AppState
    private let paths: StoragePaths
    private let snapshotStore: SnapshotStore
    private let logStore: CleanLogStore
    private var timer: Timer?
    private var lowSpaceNotified = false

    init(state: AppState, paths: StoragePaths = StoragePaths()) {
        self.state = state
        self.paths = paths
        self.snapshotStore = SnapshotStore(paths: paths)
        self.logStore = CleanLogStore(paths: paths)
    }

    func start() {
        Task { _ = await NotificationCenterService.shared.requestAuthorization() }
        Task { await scanNow() }
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1800, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in await self?.scanNow() }
        }
    }

    func scanNow() async {
        guard !state.isScanning else { return }
        state.isScanning = true
        defer { state.isScanning = false }
        guard let result = try? Scanner().scan(
            recipes: RecipeRegistry.builtIn(),
            homeDirectory: NSHomeDirectory()
        ) else { return }
        let snapshot = Snapshot(volume: result.volume, items: result.items)
        let previous = try? snapshotStore.snapshots().last
        try? snapshotStore.append(snapshot)
        state.availableBytes = result.volume.availableBytes
        state.totalBytes = result.volume.totalBytes
        state.items = result.items
        state.lastScanAt = Date()
        let all = (try? snapshotStore.snapshots()) ?? []
        state.predictionDays = FullPrediction().daysUntilFull(
            snapshots: all,
            waterlineBytes: waterlineBytes()
        )
        checkGrowth(previous: previous, latest: snapshot)
        checkLowSpace(available: result.volume.availableBytes)
    }

    func smartClean(dryRun: Bool) async -> CleanOutcome? {
        let config = loadConfig()
        guard let result = try? Scanner().scan(
            recipes: RecipeRegistry.builtIn(),
            homeDirectory: NSHomeDirectory()
        ) else { return nil }
        if dryRun {
            let evaluator = RuleEvaluator(config: config)
            let suggestions = result.items.compactMap { item -> (ScanItem, EvaluatedAction)? in
                let action = evaluator.evaluate(item: item) { name in
                    name.map { PGrepProcessInspector().isRunning($0) } ?? false
                }
                switch action.action {
                case .skip: return nil
                default: return (item, action)
                }
            }
            return CleanOutcome(
                entries: suggestions.map { entry in
                    CleanLogEntry(
                        id: UUID(),
                        timestamp: Date(),
                        itemIDs: [entry.0.id],
                        freedBytes: entry.0.reclaimableBytes,
                        disposition: entry.1.action == .trash ? .trash : .deletePermanently
                    )
                },
                freedBytes: suggestions.reduce(0) { $0 + $1.0.reclaimableBytes },
                actualFreedBytes: 0,
                stillBelowWaterline: result.volume.availableBytes < waterlineBytes()
            )
        }
        let outcome = try? Cleaner(
            evaluator: RuleEvaluator(config: config),
            deleter: FileManagerFileDeleter(),
            inspector: PGrepProcessInspector(),
            logStore: logStore
        ).run(scan: result, config: config, waterlineBytes: waterlineBytes())
        if outcome != nil {
            await scanNow()
        }
        return outcome
    }

    func loadConfig() -> Config {
        (try? JSONStore().load(Config.self, from: paths.configURL)) ?? .default
    }

    func saveConfig(_ config: Config) {
        try? JSONStore().save(config, to: paths.configURL)
    }

    private func waterlineBytes() -> Int64 {
        Int64(loadConfig().waterlineGB * 1_000_000_000)
    }

    private func checkGrowth(previous: Snapshot?, latest: Snapshot) {
        guard let previous else { return }
        if let alert = FlowAnalyzer().growthAlert(snapshots: [previous, latest]) {
            NotificationCenterService.shared.post(
                .growth,
                title: "磁盘空间异常增长",
                body: "\(alert.name) 近期增长 \(Format.bytes(alert.deltaBytes))"
            )
        }
    }

    private func checkLowSpace(available: Int64) {
        let threshold = Int64(20 * 1_000_000_000)
        if available < threshold, !lowSpaceNotified {
            lowSpaceNotified = true
            NotificationCenterService.shared.post(
                .lowSpace,
                title: "可用空间不足",
                body: "剩余 \(Format.bytes(available))，建议尽快清理"
            )
        } else if available >= threshold {
            lowSpaceNotified = false
        }
    }
}
