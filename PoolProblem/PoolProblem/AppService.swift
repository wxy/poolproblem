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
        Task {
            _ = await NotificationCenterService.shared.requestAuthorization()
            if !(await PermissionService.hasFullDiskAccess()) {
                NotificationCenterService.shared.post(
                    .permission,
                    title: Localized.string("notify.permission_title"),
                    body: Localized.string("notify.permission_body")
                )
            }
        }
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
        refreshGaugeImage()
    }

    func scanNow() async {
        guard !state.isScanning else { return }
        state.isScanning = true
        state.isCleaning = false
        state.lastCleanSummary = nil
        defer { state.isScanning = false }
        let paths = self.paths
        let cloneRatios = loadConfig().cloneRatios
        let work = Task.detached(priority: .userInitiated) { () -> (ScanResult, Snapshot?, [Snapshot])? in
            guard let result = try? DiskReservoirCore.Scanner(cloneRatios: cloneRatios).scan(
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
        if !state.isCleaning {
            state.cleanedItemIDs = []
        }
        refreshGaugeImage()
        #if DEBUG
        debugLogPermission()
        #endif
    }

    #if DEBUG
    /// 诊断：记录受保护目录的可读性，定位废纸篓检测为 0 的问题
    private func debugLogPermission() {
        let fm = FileManager.default
        let trash = NSHomeDirectory() + "/.Trash"
        let containers = NSHomeDirectory() + "/Library/Containers"
        let trashReadable = fm.isReadableFile(atPath: trash)
        var enumeratorCount = -1
        if let en = fm.enumerator(atPath: trash) {
            enumeratorCount = en.allObjects.count
        }
        let containersOK = (try? fm.contentsOfDirectory(atPath: containers)) != nil
        DebugLog.write(
            "perm: containersOK=\(containersOK) trashReadable=\(trashReadable) trashEnumCount=\(enumeratorCount)"
        )
    }
    #endif

    /// 数据变化后预生成 E 字型标尺位图（避免弹窗打开时执行重活）
    private func refreshGaugeImage() {
        state.poolGaugeImage = GaugeImageRenderer.render(
            totalBytes: state.totalBytes,
            waterlineBytes: state.waterlineBytes,
            availableBytes: state.availableBytes,
            cleanableItems: state.items
        )
    }

    private func updateFlowMetrics(snapshots: [Snapshot]) async {
        state.waterlineBytes = waterlineBytes()
        guard !snapshots.isEmpty else { return }
        state.growthRates = FlowAnalyzer().growthRates(snapshots: snapshots)
        // 进水管：按配方聚合"增速"（排除废纸篓），显示每周增长
        let itemRecipe = Dictionary(uniqueKeysWithValues: state.items.map { ($0.id, $0.recipeID) })
        var recipeRates: [String: Double] = [:]
        for (itemID, rate) in state.growthRates {
            guard let recipeID = itemRecipe[itemID], recipeID != "trash" else { continue }
            recipeRates[recipeID, default: 0] += rate
        }
        // 进水管：优先取增速前 2；不足 2 个时用当前可清理量最大的项补齐（都排除废纸篓）
        var inflows: [(String, Int64)] = recipeRates
            .sorted { $0.value > $1.value }
            .prefix(3)
            .map { (name(for: $0.key), Int64($0.value * 7)) }
        if inflows.count < 3 {
            let chosen = Set(recipeRates.keys)
            let fill = state.items
                .filter { $0.recipeID != "trash" && !chosen.contains($0.recipeID) }
                .sorted { $0.reclaimableBytes > $1.reclaimableBytes }
                .prefix(3 - inflows.count)
            for item in fill {
                inflows.append((name(for: item.recipeID), 0))
            }
        }
        state.topInflows = inflows
        let cutoff = Date().addingTimeInterval(-7 * 86_400)
        let entries = (try? logStore.entries()) ?? []
        state.weeklyCleanedBytes = entries
            .filter { $0.timestamp >= cutoff }
            .reduce(0) { $0 + $1.freedBytes }
        // 废纸篓详情：本应用清理的项 vs 其他（手动放入）
        var names: [String] = []
        var ourBytes: Int64 = 0
        for entry in entries {
            for itemID in entry.itemIDs {
                names.append(itemName(for: itemID))
            }
            ourBytes += entry.freedBytes
        }
        state.ourTrashNames = Array(names.prefix(20))
        state.ourTrashBytes = ourBytes
        let trashItem = state.items.first { $0.recipeID == "trash" }
        state.trashOthersBytes = max(0, (trashItem?.reclaimableBytes ?? 0) - ourBytes)
        state.keptItemIDs = loadConfig().keptItemIDs
        let sorted = snapshots.sorted { $0.volume.timestamp < $1.volume.timestamp }
        state.availableHistory = sorted.map { $0.volume.availableBytes }
        state.historyTimestamps = sorted.map { $0.volume.timestamp }
        if let first = sorted.first, let last = sorted.last {
            state.weeklyNetChangeBytes = last.volume.availableBytes - first.volume.availableBytes
        }
        state.cleaningEvents = entries
            .suffix(20)
            .map {
                (
                    timestamp: $0.timestamp,
                    freedBytes: $0.freedBytes,
                    isManual: $0.source == .manual
                )
            }
    }

    private func name(for recipeID: String) -> String {
        let full = RecipeRegistry.builtIn().first { $0.id == recipeID }?.name ?? recipeID
        let trimmed = full.components(separatedBy: " (").first ?? full
        return Localized.recipeName(recipeID, fallback: String(trimmed.prefix(16)))
    }

    private func itemName(for itemID: String) -> String {
        let recipeID = itemID.split(separator: ":").first.map(String.init) ?? itemID
        return name(for: recipeID)
    }

    /// 保留某一项（不再清理，但仍计入进水管）
    func keepItem(_ item: ScanItem) {
        var config = loadConfig()
        config.keptItemIDs.insert(item.id)
        writeConfig(config)
        state.keptItemIDs = config.keptItemIDs
    }

    func unkeepItem(_ id: String) {
        var config = loadConfig()
        config.keptItemIDs.remove(id)
        writeConfig(config)
        state.keptItemIDs = config.keptItemIDs
    }

    func keptItemNames() -> [(id: String, name: String)] {
        state.keptItemIDs
            .map { ($0, itemName(for: $0)) }
            .sorted { $0.name < $1.name }
    }

    func smartClean(dryRun: Bool) async -> CleanOutcome? {
        let config = loadConfig()
        let logStore = self.logStore
        let cloneRatios = config.cloneRatios
        let state = self.state
        if !dryRun {
            state.isCleaning = true
            state.cleanedItemIDs = []
        }
        let work = Task.detached(priority: .userInitiated) { () -> (ScanResult, CleanOutcome?)? in
            guard let result = try? DiskReservoirCore.Scanner(cloneRatios: cloneRatios).scan(
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
            ).run(
                scan: result,
                config: config,
                waterlineBytes: Int64.max,   // 手动清理不受水线限制
                forceClean: true,            // 手动清理：忽略年龄/最近修改，一律进回收站
                onItemWillDelete: { itemID in
                    Task { @MainActor in
                        state.deletingItemID = itemID
                    }
                },
                onItemCleaned: { itemID in
                    Task { @MainActor in
                        var cleaned = state.cleanedItemIDs
                        cleaned.insert(itemID)
                        state.cleanedItemIDs = cleaned
                        state.deletingItemID = nil
                        if let item = state.items.first(where: { $0.id == itemID }) {
                            state.availableBytes = min(
                                state.totalBytes,
                                state.availableBytes + item.reclaimableBytes
                            )
                            self.growTrashItem(by: item.reclaimableBytes)
                        }
                    }
                }
            )
            return (result, outcome)
        }
        guard let (_, outcome) = await work.value, let outcome else {
            state.isCleaning = false
            return nil
        }
        state.isCleaning = false
        if !outcome.calibrationUpdates.isEmpty {
            var updated = config
            for (recipeID, ratio) in outcome.calibrationUpdates {
                updated.cloneRatios[recipeID] = ratio
            }
            writeConfig(updated)
        }
        await scanNow()
        state.lastCleanSummary = Localized.string("clean.summary", outcome.entries.count, Format.bytes(outcome.freedBytes))
        state.cleanCelebrationID += 1
        return outcome
    }

    /// 删除移入回收站时，实时增长垃圾箱图层
    private func growTrashItem(by bytes: Int64) {
        guard let index = state.items.firstIndex(where: { $0.recipeID == "trash" }) else { return }
        let item = state.items[index]
        let updated = ScanItem(
            id: item.id,
            recipeID: item.recipeID,
            name: item.name,
            path: item.path,
            category: item.category,
            safety: item.safety,
            disposition: item.disposition,
            sizeBytes: item.sizeBytes + bytes,
            allocatedBytes: item.allocatedBytes + bytes,
            reclaimableBytes: item.reclaimableBytes + bytes,
            fileCount: item.fileCount + 1,
            lastModified: item.lastModified
        )
        var items = state.items
        items[index] = updated
        state.items = items
    }

    func loadConfig() -> Config {
        (try? JSONStore().load(Config.self, from: paths.configURL)) ?? .default
    }

    func saveConfig(_ config: Config) {
        // 设置页整体保存时只更新它管理的字段，避免覆盖 keptItemIDs/cloneRatios（由其它入口维护）
        var existing = loadConfig()
        existing.waterlineGB = config.waterlineGB
        existing.rules = config.rules
        existing.whitelistPaths = config.whitelistPaths
        existing.enabledRecipes = config.enabledRecipes
        writeConfig(existing)
    }

    private func writeConfig(_ config: Config) {
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
                title: Localized.string("notify.growth_title"),
                body: Localized.string("notify.growth_body", alert.name, Format.bytes(alert.deltaBytes))
            )
        }
    }

    private func checkLowSpace(available: Int64) {
        let threshold = Int64(20 * 1_000_000_000)
        if available < threshold, !lowSpaceNotified {
            lowSpaceNotified = true
            NotificationCenterService.shared.post(
                .lowSpace,
                title: Localized.string("notify.low_space_title"),
                body: Localized.string("notify.low_space_body", Format.bytes(available))
            )
        } else if available >= threshold {
            lowSpaceNotified = false
        }
    }
}

#if DEBUG
/// 诊断日志（仅 Debug 构建）：写入 /tmp/poolproblem-perm.log
enum DebugLog {
    static func write(_ text: String) {
        let line = "[\(Date())] \(text)\n"
        guard let data = line.data(using: .utf8) else { return }
        let url = URL(fileURLWithPath: "/tmp/poolproblem-perm.log")
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: url)
        }
    }
}
#endif
