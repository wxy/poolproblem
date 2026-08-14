import Foundation
import DiskReservoirCore

@MainActor
final class AppService {
    private let state: AppState
    private let paths: StoragePaths
    private let snapshotStore: SnapshotStore
    private let logStore: CleanLogStore
    private let automationEnabled: Bool
    private var timer: Timer?
    private var lowSpaceNotified = false
    private var trashAccumulationNotified = false
    private let proactiveCleanTriggerBytes: Int64 = 5 * 1_000_000_000
    private let earlyProactiveTriggerBytes: Int64 = 8 * 1_000_000_000
    private let proactiveCleanBatchBytes: Int64 = 3 * 1_000_000_000
    private let fastGrowthTriggerBytesPerDay: Double = 500_000_000

    init(state: AppState, paths: StoragePaths = StoragePaths(), automationEnabled: Bool = true) {
        self.state = state
        self.paths = paths
        self.snapshotStore = SnapshotStore(paths: paths)
        self.logStore = CleanLogStore(paths: paths)
        self.automationEnabled = automationEnabled
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

    func scanNow(autoClean: Bool = true) async {
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
        state.autoCleanPlan = upcomingAutoCleanPlan(result: result)
        if !state.isCleaning {
            state.cleanedItemIDs = []
        }
        if automationEnabled, autoClean {
            await maybeAutoClean(result: result)
            checkTrashAccumulation()
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
        let home = NSHomeDirectory()
        let trash = home + "/.Trash"
        let containers = home + "/Library/Containers"
        let tcc = home + "/Library/Application Support/com.apple.TCC/TCC.db"
        let safari = home + "/Library/Safari"
        let trashReadable = fm.isReadableFile(atPath: trash)
        // 只做轻量探测（避免全量遍历几十万文件的废纸篓拖慢扫描）
        var contentsCount = -1
        if let list = try? fm.contentsOfDirectory(atPath: trash) { contentsCount = list.count }
        let containersOK = (try? fm.contentsOfDirectory(atPath: containers)) != nil
        let posixCount = POSIXDirectoryWalker.firstLevelCount(path: trash)
        var safariCount = -1
        if let en = fm.enumerator(atPath: safari) { safariCount = en.allObjects.count }
        DebugLog.write(
            "perm: home=\(home) tccReadable=\(fm.contents(atPath: tcc) != nil) "
            + "containersOK=\(containersOK) trashReadable=\(trashReadable) "
            + "trashContents=\(contentsCount) posixCount=\(posixCount.map(String.init) ?? "nil") "
            + "safariEnum=\(safariCount)"
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
            .prefix(2)
            .map { (name(for: $0.key), Int64($0.value * 7)) }
        if inflows.count < 2 {
            let chosen = Set(recipeRates.keys)
            let fill = state.items
                .filter { $0.recipeID != "trash" && !chosen.contains($0.recipeID) }
                .sorted { $0.reclaimableBytes > $1.reclaimableBytes }
                .prefix(2 - inflows.count)
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
            let entryNames = entry.itemNames.isEmpty
                ? entry.itemIDs.map(itemName(for:))
                : entry.itemNames
            for name in entryNames {
                names.append(name)
            }
            ourBytes += entry.freedBytes
        }
        state.ourTrashNames = Array(names.prefix(20))
        state.ourTrashBytes = ourBytes
        // 废纸篓可能同时包含本机 ~/.Trash 与 iCloud Drive 废纸篓，合并计算
        let totalTrashBytes = state.items
            .filter { $0.recipeID == "trash" }
            .reduce(Int64(0)) { $0 + $1.reclaimableBytes }
        state.trashOthersBytes = max(0, totalTrashBytes - ourBytes)
        state.keptItemIDs = loadConfig().keptItemIDs
        let sorted = snapshots.sorted { $0.volume.timestamp < $1.volume.timestamp }
        state.availableHistory = sorted.map { $0.volume.availableBytes }
        state.historyTimestamps = sorted.map { $0.volume.timestamp }
        if let first = sorted.first, let last = sorted.last {
            state.weeklyNetChangeBytes = last.volume.availableBytes - first.volume.availableBytes
        }
        refreshCleanLogEntries(entries: entries)
    }

    private func refreshCleanLogEntries(entries: [CleanLogEntry]? = nil) {
        let entries = entries ?? ((try? logStore.entries()) ?? [])
        let sortedEntries = entries.sorted { $0.timestamp < $1.timestamp }
        state.cleanLogEntries = Array(sortedEntries.suffix(100).reversed())
        state.cleaningEvents = sortedEntries
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
            // 全量扫描期间没有逐项回调，先闪动预计第一个处理的小项，避免毫无反馈
            state.deletingItemID = firstPlannedItem()?.id
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
                            itemNames: [entry.0.name],
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
                onItemCleaned: { itemID, disposition in
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
                            if disposition == .trash {
                                self.growTrashItem(by: item.reclaimableBytes)
                            }
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

    func undoCleanup(_ entry: CleanLogEntry) async -> Bool {
        guard entry.disposition == .trash else { return false }
        let originalPaths = entry.originalPaths.isEmpty
            ? entry.itemIDs.map { Self.originalPath(fromItemID: $0) }
            : entry.originalPaths
        let trashPaths = entry.trashPaths
        let logStore = self.logStore

        let work = Task.detached(priority: .userInitiated) { () -> Bool in
            var restored = false
            for (index, originalPath) in originalPaths.enumerated() {
                let originalURL = URL(fileURLWithPath: originalPath)
                let source: URL?
                if index < trashPaths.count, !trashPaths[index].isEmpty {
                    source = URL(fileURLWithPath: trashPaths[index])
                } else {
                    source = Self.findTrashURL(for: originalURL)
                }
                guard let source, FileManager.default.fileExists(atPath: source.path) else {
                    continue
                }
                do {
                    try FileManager.default.moveItem(
                        at: source,
                        to: Self.availableDestination(for: originalURL)
                    )
                    restored = true
                } catch {
                    continue
                }
            }
            if restored {
                try? logStore.remove(id: entry.id)
            }
            return restored
        }

        let restored = await work.value
        if restored {
            await scanNow(autoClean: false)
        } else {
            state.lastCleanSummary = Localized.string("history.undo_failed")
        }
        return restored
    }

    func canUndo(_ entry: CleanLogEntry) -> Bool {
        guard entry.disposition == .trash else { return false }
        if entry.trashPaths.contains(where: { !$0.isEmpty && FileManager.default.fileExists(atPath: $0) }) {
            return true
        }
        let originalPaths = entry.originalPaths.isEmpty
            ? entry.itemIDs.map { Self.originalPath(fromItemID: $0) }
            : entry.originalPaths
        return originalPaths.contains { originalPath in
            Self.findTrashURL(for: URL(fileURLWithPath: originalPath)) != nil
        }
    }

    nonisolated private static func originalPath(fromItemID itemID: String) -> String {
        itemID.split(separator: ":", maxSplits: 1).last.map(String.init) ?? itemID
    }

    nonisolated private static func findTrashURL(for originalURL: URL) -> URL? {
        let trashRoot = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".Trash", isDirectory: true)
        let name = originalURL.lastPathComponent
        let direct = trashRoot.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: direct.path) {
            return direct
        }
        guard let children = try? FileManager.default.contentsOfDirectory(
            at: trashRoot,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return nil }
        for child in children where child.lastPathComponent.hasPrefix("PoolProblem Cleanup") {
            let candidate = child.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }

    nonisolated private static func availableDestination(for originalURL: URL) -> URL {
        guard FileManager.default.fileExists(atPath: originalURL.path) else {
            return originalURL
        }
        let parent = originalURL.deletingLastPathComponent()
        let name = originalURL.lastPathComponent
        var candidate = parent.appendingPathComponent("\(name) (Recovered)")
        var index = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = parent.appendingPathComponent("\(name) (Recovered \(index))")
            index += 1
        }
        return candidate
    }

    // MARK: - Proactive auto-clean

    private func upcomingAutoCleanPlan(result: ScanResult) -> String {
        let waterline = waterlineBytes()
        if result.volume.availableBytes < waterline {
            return Localized.string("countdown.plan_below")
        }

        let safeItems = result.items.filter {
            $0.recipeID != "trash"
                && $0.safety == .safeWhileRunning
                && $0.reclaimableBytes > 0
        }
        let safeReclaimableBytes = safeItems.reduce(Int64(0)) { $0 + $1.reclaimableBytes }

        if result.volume.availableBytes < waterline + proactiveCleanTriggerBytes {
            return Localized.string(
                "countdown.plan_near",
                Format.bytes(proactiveCleanBatchBytes)
            )
        }

        let recipe = RecipeRegistry.builtIn().first { $0.id == "xctestdevices" }
        let prefix = "xctestdevices:"
        let recipeGrowthRate = state.growthRates
            .filter { $0.key.hasPrefix(prefix) }
            .values
            .max() ?? 0
        if recipeGrowthRate >= fastGrowthTriggerBytesPerDay {
            return Localized.string("countdown.plan_fast_growth", name(for: "xctestdevices"))
        }

        if let recipe, let path = recipe.resolvePaths(paths).first {
            let childCount = POSIXDirectoryWalker.firstLevelCount(path: path) ?? 0
            if childCount > 10 {
                return Localized.string("countdown.plan_many_children", name(for: "xctestdevices"), childCount)
            }
        }

        if safeReclaimableBytes >= earlyProactiveTriggerBytes {
            return Localized.string("countdown.plan_large_reclaimable", Format.bytes(safeReclaimableBytes))
        }

        return Localized.string("countdown.plan_idle", Format.bytes(earlyProactiveTriggerBytes))
    }

    private func maybeAutoClean(result: ScanResult) async {
        guard !state.isCleaning else { return }
        let config = loadConfig()
        var totalCount = 0
        var totalFreed: Int64 = 0
        let waterline = waterlineBytes()
        let safeItems = result.items.filter {
            $0.recipeID != "trash"
                && $0.safety == .safeWhileRunning
                && $0.reclaimableBytes > 0
        }
        let safeReclaimableBytes = safeItems.reduce(Int64(0)) { $0 + $1.reclaimableBytes }
        let earlyTrigger = safeReclaimableBytes >= earlyProactiveTriggerBytes

        let target: Int64?
        if result.volume.availableBytes < waterline {
            target = waterline
        } else if result.volume.availableBytes < waterline + proactiveCleanTriggerBytes {
            target = min(
                result.volume.availableBytes + proactiveCleanBatchBytes,
                waterline + proactiveCleanTriggerBytes
            )
        } else if earlyTrigger {
            target = result.volume.availableBytes + proactiveCleanBatchBytes
        } else {
            target = nil
        }

        if let target {
            if let outcome = await runAutoWaterlineClean(
                scan: result,
                config: config,
                waterlineBytes: target
            ) {
                totalCount += outcome.entries.count
                totalFreed += outcome.freedBytes
                if !outcome.calibrationUpdates.isEmpty {
                    var updated = config
                    for (recipeID, ratio) in outcome.calibrationUpdates {
                        updated.cloneRatios[recipeID] = ratio
                    }
                    writeConfig(updated)
                }
            }
        }

        let progressive = await runProgressiveCleanup(config: config)
        totalCount += progressive.entries.count
        totalFreed += progressive.freedBytes

        if totalCount > 0 {
            state.lastCleanSummary = Localized.string(
                "clean.auto_summary",
                totalCount,
                Format.bytes(totalFreed)
            )
            state.autoCleanPlan = Localized.string(
                "countdown.plan_cleaned",
                totalCount,
                Format.bytes(totalFreed)
            )
            refreshCleanLogEntries()
        }
    }

    private func runAutoWaterlineClean(
        scan: ScanResult,
        config: Config,
        waterlineBytes: Int64
    ) async -> CleanOutcome? {
        state.isCleaning = true
        state.cleanedItemIDs = []
        state.deletingItemID = firstAutoPlannedItem(scan: scan, config: config)?.id
        let logStore = self.logStore
        let state = self.state
        let work = Task.detached(priority: .utility) { () -> CleanOutcome? in
            let cleaner = Cleaner(
                evaluator: RuleEvaluator(config: config),
                deleter: FileManagerFileDeleter(),
                inspector: PGrepProcessInspector(),
                logStore: logStore
            )
            return try? cleaner.run(
                scan: scan,
                config: config,
                waterlineBytes: waterlineBytes,
                forceClean: false,
                source: .auto,
                onItemWillDelete: { itemID in
                    Task { @MainActor in
                        state.deletingItemID = itemID
                    }
                },
                onItemCleaned: { itemID, disposition in
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
                            if disposition == .trash {
                                self.growTrashItem(by: item.reclaimableBytes)
                            }
                        }
                    }
                }
            )
        }
        guard let outcome = await work.value else {
            state.isCleaning = false
            return nil
        }
        state.isCleaning = false
        return outcome
    }

    private func runProgressiveCleanup(config: Config) async -> ProgressiveCleanupOutcome {
        let policies = progressivePolicies(config: config)
        guard !policies.isEmpty else { return .empty }
        state.isCleaning = true
        let logStore = self.logStore
        let work = Task.detached(priority: .utility) { () -> ProgressiveCleanupOutcome in
            var entries: [CleanLogEntry] = []
            var freedBytes: Int64 = 0
            var trimmedCount = 0
            var remainingCount = 0
            for policy in policies {
                let deleter: FileDeleting = policy.disposition == .trash
                    ? TrashBatchDeleter()
                    : FileManagerFileDeleter()
                let cleaner = ProgressiveCleaner(
                    deleter: deleter,
                    logStore: logStore
                )
                guard let outcome = try? cleaner.run(policy: policy) else { continue }
                entries.append(contentsOf: outcome.entries)
                freedBytes += outcome.freedBytes
                trimmedCount += outcome.trimmedCount
                remainingCount += outcome.remainingCount
            }
            return ProgressiveCleanupOutcome(
                entries: entries,
                freedBytes: freedBytes,
                trimmedCount: trimmedCount,
                remainingCount: remainingCount
            )
        }
        let outcome = await work.value
        state.isCleaning = false
        if outcome.freedBytes > 0 {
            let trashFreed = outcome.entries
                .filter { $0.disposition == .trash }
                .reduce(Int64(0)) { $0 + $1.freedBytes }
            let permanentFreed = outcome.entries
                .filter { $0.disposition == .deletePermanently }
                .reduce(Int64(0)) { $0 + $1.freedBytes }
            if trashFreed > 0 {
                growTrashItem(by: trashFreed)
            }
            if permanentFreed > 0 {
                state.availableBytes = min(
                    state.totalBytes,
                    state.availableBytes + permanentFreed
                )
            }
            updateParentItemAfterProgressiveCleanup(
                policies: policies,
                freedBytes: outcome.freedBytes,
                trimmedCount: outcome.trimmedCount
            )
        }
        return outcome
    }

    private func progressivePolicies(config: Config) -> [ProgressiveCleanupPolicy] {
        guard let recipe = RecipeRegistry.builtIn().first(where: { $0.id == "xctestdevices" }) else {
            return []
        }
        if let rule = config.rules.first(where: { $0.recipeID == recipe.id }), !rule.enabled {
            return []
        }
        let prefix = "\(recipe.id):"
        let recipeGrowthRate = state.growthRates
            .filter { $0.key.hasPrefix(prefix) }
            .values
            .max() ?? 0
        let fastGrowing = recipeGrowthRate >= fastGrowthTriggerBytesPerDay
        return recipe.resolvePaths(paths).compactMap { path in
            let parentID = "\(recipe.id):\(path)"
            guard !config.keptItemIDs.contains(parentID),
                  !config.whitelistPaths.contains(path) else {
                return nil
            }
            return ProgressiveCleanupPolicy(
                recipeID: recipe.id,
                parentPath: path,
                maxChildren: fastGrowing ? 0 : 10,
                maxItemsPerRun: 3,
                minimumAgeSeconds: 86_400,
                disposition: .trash,
                source: .auto,
                reclaimableRatio: config.cloneRatios[recipe.id] ?? 0.2
            )
        }
    }

    private func firstAutoPlannedItem(scan: ScanResult, config: Config) -> ScanItem? {
        scan.items
            .filter {
                $0.reclaimableBytes > 0
                    && $0.recipeID != "trash"
                    && $0.safety == .safeWhileRunning
                    && !config.whitelistPaths.contains($0.path)
                    && !config.keptItemIDs.contains($0.id)
            }
            .sorted { $0.reclaimableBytes < $1.reclaimableBytes }
            .first
    }

    private func updateParentItemAfterProgressiveCleanup(
        policies: [ProgressiveCleanupPolicy],
        freedBytes: Int64,
        trimmedCount: Int
    ) {
        for policy in policies {
            let parentID = "\(policy.recipeID):\(policy.parentPath)"
            guard let index = state.items.firstIndex(where: { $0.id == parentID }) else { continue }
            let item = state.items[index]
            let updated = ScanItem(
                id: item.id,
                recipeID: item.recipeID,
                name: item.name,
                path: item.path,
                category: item.category,
                safety: item.safety,
                disposition: item.disposition,
                sizeBytes: max(0, item.sizeBytes - freedBytes),
                allocatedBytes: max(0, item.allocatedBytes - freedBytes),
                reclaimableBytes: max(0, item.reclaimableBytes - freedBytes),
                fileCount: max(0, item.fileCount - trimmedCount),
                lastModified: item.lastModified
            )
            state.items[index] = updated
        }
    }

    /// 预计手动清理第一个处理的项目：按可清理量从小到大，
    /// 与 Cleaner 的新顺序一致（排除废纸篓、保留项、白名单及"需退出/需确认"项）
    private func firstPlannedItem() -> ScanItem? {
        let config = loadConfig()
        return state.items
            .filter {
                $0.reclaimableBytes > 0
                    && $0.recipeID != "trash"
                    && $0.safety == .safeWhileRunning
                    && !config.whitelistPaths.contains($0.path)
                    && !config.keptItemIDs.contains($0.id)
            }
            .sorted { $0.reclaimableBytes < $1.reclaimableBytes }
            .first
    }

    /// 删除移入回收站时，实时增长垃圾箱图层
    private func growTrashItem(by bytes: Int64) {
        // 应用清理只会进入本机 ~/.Trash，优先增长本地废纸篓条目
        let localTrash = NSHomeDirectory() + "/.Trash"
        guard let index = state.items.firstIndex(where: { $0.recipeID == "trash" && $0.path == localTrash })
            ?? state.items.firstIndex(where: { $0.recipeID == "trash" })
        else { return }
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

    private func checkTrashAccumulation() {
        let notifyThreshold: Int64 = 5 * 1_000_000_000
        let clearThreshold: Int64 = 3 * 1_000_000_000
        let totalTrashBytes = state.items
            .filter { $0.recipeID == "trash" }
            .reduce(Int64(0)) { $0 + max(0, $1.reclaimableBytes) }

        if !trashAccumulationNotified, totalTrashBytes >= notifyThreshold {
            trashAccumulationNotified = true
            NotificationCenterService.shared.post(
                .trash,
                title: Localized.string("notify.trash_title"),
                body: Localized.string("notify.trash_body", Format.bytes(totalTrashBytes))
            )
        } else if trashAccumulationNotified, totalTrashBytes <= clearThreshold {
            trashAccumulationNotified = false
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
