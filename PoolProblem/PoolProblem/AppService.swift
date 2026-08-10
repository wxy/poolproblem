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
        Task { await loadLatestState() }
        Task { await scanNow() }
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1800, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in await self?.scanNow() }
        }
    }

    func loadLatestState() async {
        let paths = self.paths
        let work = Task.detached(priority: .userInitiated) { () -> (VolumeInfo, [ScanItem], [Snapshot])? in
            let volume = VolumeReader.read(fileURL: URL(fileURLWithPath: NSHomeDirectory()))
            let store = SnapshotStore(paths: paths)
            let snapshots = (try? store.snapshots()) ?? []
            let items = snapshots.last?.items ?? []
            return (volume, items, snapshots)
        }
        guard let (volume, items, snapshots) = await work.value else { return }
        state.availableBytes = volume.availableBytes
        state.totalBytes = volume.totalBytes
        state.items = items
        state.lastScanAt = snapshots.last?.volume.timestamp
        state.predictionDays = FullPrediction().daysUntilFull(
            snapshots: snapshots,
            waterlineBytes: waterlineBytes()
        )
        await updateFlowMetrics(snapshots: snapshots)
    }

    func scanNow() async {
        guard !state.isScanning else { return }
        state.isScanning = true
        defer { state.isScanning = false }
        let paths = self.paths
        let work = Task.detached(priority: .userInitiated) { () -> (ScanResult, Snapshot?, [Snapshot])? in
            guard let result = try? Scanner().scan(
                recipes: RecipeRegistry.builtIn(),
                homeDirectory: NSHomeDirectory()
            ) else { return nil }
            let snapshot = Snapshot(volume: result.volume, items: result.items)
            let store = SnapshotStore(paths: paths)
            let previous = try? store.snapshots().last
            try? store.append(snapshot)
            let all = (try? store.snapshots()) ?? []
            return (result, previous, all)
        }
        guard let (result, previous, all) = await work.value else { return }
        state.availableBytes = result.volume.availableBytes
        state.totalBytes = result.volume.totalBytes
        state.items = result.items
        state.lastScanAt = Date()
        state.predictionDays = FullPrediction().daysUntilFull(
            snapshots: all,
            waterlineBytes: waterlineBytes()
        )
        await updateFlowMetrics(snapshots: all)
        let snapshot = Snapshot(volume: result.volume, items: result.items)
        checkGrowth(previous: previous, latest: snapshot)
        checkLowSpace(available: result.volume.availableBytes)
    }

    private func updateFlowMetrics(snapshots: [Snapshot]) async {
        state.waterlineBytes = waterlineBytes()
        guard let last = snapshots.last else { return }
        let attribution = FlowAnalyzer().attribution(snapshots: snapshots, windowDays: 7)
        state.topInflows = attribution.recipeDeltas
            .sorted { $0.value > $1.value }
            .prefix(2)
            .map { (name(for: $0.key), $0.value) }
        let cutoff = Date().addingTimeInterval(-7 * 86_400)
        let entries = (try? logStore.entries()) ?? []
        state.weeklyCleanedBytes = entries
            .filter { $0.timestamp >= cutoff }
            .reduce(0) { $0 + $1.freedBytes }
    }

    private func name(for recipeID: String) -> String {
        RecipeRegistry.builtIn().first { $0.id == recipeID }?.name ?? recipeID
    }

    func smartClean(dryRun: Bool) async -> CleanOutcome? {
        let config = loadConfig()
        let logStore = self.logStore
        let work = Task.detached(priority: .userInitiated) { () -> (ScanResult, CleanOutcome?)? in
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
                let outcome = CleanOutcome(
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
                    stillBelowWaterline: result.volume.availableBytes < Int64(config.waterlineGB * 1_000_000_000)
                )
                return (result, outcome)
            }
            let outcome = try? Cleaner(
                evaluator: RuleEvaluator(config: config),
                deleter: FileManagerFileDeleter(),
                inspector: PGrepProcessInspector(),
                logStore: logStore
            ).run(scan: result, config: config, waterlineBytes: Int64(config.waterlineGB * 1_000_000_000))
            return (result, outcome)
        }
        guard let (_, outcome) = await work.value, let outcome else { return nil }
        await scanNow()
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
