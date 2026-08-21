import Foundation
import DiskReservoirCore

@MainActor
final class AppService {
    private let state: AppState
    private let paths: StoragePaths
    private let snapshotStore: SnapshotStore
    private let logStore: CleanLogStore
    private let growthLedgerStore: GrowthLedgerStore
    private let recipeSuggestionStore: RecipeSuggestionStore
    private let fseventMonitor = FSEventMonitor()
    private let activityMonitor = FSEventMonitor(latency: 5.0)
    private let devActivityTracker = DevActivityTracker()
    private var dirtyTracker = DirtyTracker(trackedPaths: [])
    private var incrementalTimer: Timer?
    private var lastIncrementalAt = Date.distantPast
    private var lastDevDiscoveryAt = Date.distantPast
    private let automationEnabled: Bool
    private var timer: Timer?
    private var lowSpaceNotified = false
    private var trashAccumulationNotified = false
    private let proactiveCleanTriggerBytes: Int64 = 5 * 1_000_000_000
    private let earlyProactiveTriggerBytes: Int64 = 8 * 1_000_000_000
    private let proactiveCleanBatchBytes: Int64 = 3 * 1_000_000_000
    private let fastGrowthTriggerBytesPerDay: Double = 500_000_000
    private let autoMinimumCleanItemBytes: Int64 = 500_000_000
    private let emergencyProgressiveMinimumAgeSeconds: TimeInterval = 2 * 3600

    init(state: AppState, paths: StoragePaths = StoragePaths(), automationEnabled: Bool = true) {
        self.state = state
        self.paths = paths
        self.snapshotStore = SnapshotStore(paths: paths)
        self.logStore = CleanLogStore(paths: paths)
        self.growthLedgerStore = GrowthLedgerStore(paths: paths)
        self.recipeSuggestionStore = RecipeSuggestionStore(paths: paths)
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
        Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            await scanNow()
        }
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
        refreshGrowthState()
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
        let ageRules = ageDaysByRecipe()
        let recipes = activeRecipes()
        let work = Task.detached(priority: .utility) { () -> (ScanResult, Snapshot?, [Snapshot])? in
            guard let result = try? DiskReservoirCore.Scanner(
                cloneRatios: cloneRatios,
                ageDaysByRecipe: ageRules
            ).scan(
                recipes: recipes,
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
        await updateGrowthInsights(previous: previous, latest: snapshot)
        checkGrowth(previous: previous, latest: snapshot)
        checkLowSpace(available: result.volume.availableBytes)
        let plans = upcomingAutoCleanPlans(result: result)
        state.autoCleanPlans = plans
        state.autoCleanPlan = plans.first?.title
            ?? Localized.string("countdown.plan_idle", Format.bytes(earlyProactiveTriggerBytes))
        if !state.isCleaning {
            state.cleanedItemIDs = []
        }
        if automationEnabled, autoClean {
            await maybeAutoClean(result: result)
            checkTrashAccumulation()
        }
        refreshGaugeImage()
        startWatching()
        #if DEBUG
        debugLogPermission()
        #endif
    }

    /// 全量扫描成功后启动 FSEvents 监听（幂等：内部先 stop 再 start）。
    private func startWatching() {
        let home = NSHomeDirectory()
        let recipePaths = activeRecipes()
            .flatMap { $0.resolvePaths(StoragePaths(baseURL: nil, homeDirectory: home)) }
        let roots = SurfaceScanner.defaultRoots(homeDirectory: home)
        let paths = Array(Set(recipePaths + roots))
        dirtyTracker = DirtyTracker(trackedPaths: paths)
        fseventMonitor.start(paths: paths) { [weak self] eventPaths in
            Task { @MainActor [weak self] in
                self?.handleEvents(eventPaths)
            }
        }
        // 写活动识别：监听家目录，命中可再生产物名即记录"项目根 + 最近活动"
        activityMonitor.start(paths: [home]) { [devActivityTracker] eventPaths in
            devActivityTracker.record(eventPaths: eventPaths)
        }
        incrementalTimer?.invalidate()
        incrementalTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in await self?.incrementalScanIfDirty() }
        }
    }

    private func handleEvents(_ eventPaths: [String]) {
        dirtyTracker.mark(eventPaths: eventPaths)
    }

    private func incrementalScanIfDirty() async {
        guard !dirtyTracker.dirty.isEmpty else { return }
        guard Date().timeIntervalSince(lastIncrementalAt) >= 30 else { return }
        lastIncrementalAt = Date()
        let dirty = dirtyTracker.dirty
        dirtyTracker.clear()
        await runIncrementalScan(dirty: dirty)
    }

    /// 增量重扫：脏配方路径 + 脏表面目录 → 合成增量快照 → 更新台账与候选配方。
    /// 不触发自动清理、通知与水位预测（由下一次全量扫描接管）。
    private func runIncrementalScan(dirty: Set<String>) async {
        let home = NSHomeDirectory()
        let paths = self.paths
        let recipes = activeRecipes()
        let cloneRatios = loadConfig().cloneRatios
        let ageRules = ageDaysByRecipe()
        let surfaceRoots = SurfaceScanner.defaultRoots(homeDirectory: home)
        let work = Task.detached(priority: .utility) { () -> (Snapshot, [SurfaceDirectory])? in
            let store = SnapshotStore(paths: paths)
            var items = (try? store.snapshots().last?.items) ?? []
            var dirtySurface: [String] = []
            let storagePaths = StoragePaths(baseURL: nil, homeDirectory: home)
            for path in dirty {
                if let recipe = recipes.first(where: {
                    $0.resolvePaths(storagePaths).contains { $0 == path || path.hasPrefix($0 + "/") }
                }) {
                    let fresh = Scanner(
                        cloneRatios: cloneRatios,
                        ageDaysByRecipe: ageRules
                    ).rescan(
                        path: path,
                        recipe: recipe,
                        homeDirectory: home
                    )
                    if recipe.aggregatesPaths {
                        // 聚合配方：脏路径可能只是其中某个项目，旧条目以配方为单位整体替换
                        items.removeAll { $0.recipeID == recipe.id }
                    } else {
                        items.removeAll { $0.path == path || $0.path.hasPrefix(path + "/") }
                    }
                    items.append(contentsOf: fresh)
                } else if surfaceRoots.contains(where: { path.hasPrefix($0 + "/") || $0.hasPrefix(path + "/") }) {
                    dirtySurface.append(path)
                }
            }
            let surface = SurfaceScanner().measure(paths: dirtySurface)
            let volume = VolumeReader.read(fileURL: URL(fileURLWithPath: home))
            return (Snapshot(volume: volume, items: items, source: .incremental), surface)
        }
        guard let (snapshot, surface) = await work.value else { return }
        let store = SnapshotStore(paths: paths)
        let previous = try? store.snapshots().last
        try? store.append(snapshot)
        state.items = snapshot.items
        state.availableBytes = snapshot.volume.availableBytes
        state.totalBytes = snapshot.volume.totalBytes
        await updateIncrementalInsights(previous: previous, latest: snapshot, surface: surface)
    }

    /// 增量更新增长台账与候选配方（不走 24h 表面扫描门控；只更新脏表面目录）。
    private func updateIncrementalInsights(
        previous: Snapshot?,
        latest: Snapshot,
        surface: [SurfaceDirectory]
    ) async {
        let home = NSHomeDirectory()
        let builder = GrowthLedgerBuilder()
        var entries = builder.entries(previous: previous, latest: latest, homeDirectory: home)
        if !surface.isEmpty {
            let oldDirs = (try? growthLedgerStore.surfaceDirectories()) ?? []
            var merged = oldDirs.filter { dir in !surface.contains(where: { $0.path == dir.path }) }
            merged.append(contentsOf: surface)
            entries.append(contentsOf: builder.surfaceEntries(
                previous: oldDirs,
                latest: merged,
                homeDirectory: home
            ))
            try? growthLedgerStore.saveSurface(merged, scannedAt: Date())
        }
        try? growthLedgerStore.append(entries)
        try? growthLedgerStore.prune(retainingDays: 30)
        let allEntries = (try? growthLedgerStore.entries()) ?? []
        let candidates = RecipeSuggester().suggest(
            entries: allEntries,
            existingRecipes: activeRecipes(),
            homeDirectory: home
        )
        try? recipeSuggestionStore.merge(candidates)
        state.growthInsights = growthInsights(from: allEntries)
        state.candidateRecipes = (try? recipeSuggestionStore.load()) ?? []
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
        let made = PoolWindowLayout.make(
            totalBytes: state.totalBytes,
            availableBytes: state.availableBytes,
            waterlineBytes: state.waterlineBytes,
            items: state.items,
            estimatedRecipeIDs: Set(activeRecipes().filter(\.cloneProne).map(\.id)),
            excludedItemIDs: state.cleanedItemIDs
        )
        state.poolGaugeImage = GaugeImageRenderer.render(layout: made.layout)
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
        // 废纸篓详情：只展示当前仍留在回收站里的、本应用清理过的项；
        // 用户清空废纸篓后，这里不再显示历史清理记录。
        var names: [String] = []
        var ourBytes: Int64 = 0
        for entry in entries where entry.disposition == .trash {
            let stillPresent = !entry.trashPaths.isEmpty
                ? entry.trashPaths.allSatisfy { FileManager.default.fileExists(atPath: $0) }
                : false
            guard stillPresent else { continue }
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

        var grouped: [String: (timestamp: Date, freedBytes: Int64, isManual: Bool)] = [:]
        var order: [String] = []
        for entry in sortedEntries {
            let key = entry.batchID.map { "batch-\($0.uuidString)" }
                ?? "legacy-\(entry.source.rawValue)-\(Int(entry.timestamp.timeIntervalSince1970))"
            if grouped[key] == nil {
                order.append(key)
                grouped[key] = (entry.timestamp, 0, entry.source == .manual)
            }
            grouped[key]?.freedBytes += entry.freedBytes
        }

        let historyStart = state.historyTimestamps.first
        let historyEnd = state.historyTimestamps.last
        let groupedEvents = order.compactMap { key -> (Date, Int64, Bool)? in
            guard let event = grouped[key] else { return nil }
            if let historyStart, event.timestamp < historyStart { return nil }
            if let historyEnd, event.timestamp > historyEnd { return nil }
            return event
        }
        let visibleEvents = groupedEvents.isEmpty
            ? order.compactMap { grouped[$0] }
            : groupedEvents
        state.cleaningEvents = visibleEvents
            .suffix(120)
            .map {
                (
                    timestamp: $0.0,
                    freedBytes: $0.1,
                    isManual: $0.2
                )
            }
    }

    private func name(for recipeID: String) -> String {
        let full = activeRecipes().first { $0.id == recipeID }?.name ?? recipeID
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
        let recipes = activeRecipes()
        let activeRootsByRecipe = projectActiveRootsByRecipe(recipes: recipes)
        let idleHours = idleHoursByRecipe(recipes: recipes)
        let ageRules = ageDaysByRecipe()
        let work = Task.detached(priority: .userInitiated) { () -> (ScanResult, CleanOutcome?)? in
            guard let result = try? DiskReservoirCore.Scanner(
                cloneRatios: cloneRatios,
                ageDaysByRecipe: ageRules
            ).scan(
                recipes: recipes,
                homeDirectory: NSHomeDirectory()
            ) else { return nil }
            if dryRun {
                let evaluator = RuleEvaluator(
                    config: config,
                    activeProjectRootsByRecipe: activeRootsByRecipe,
                    idleHoursByRecipe: idleHours
                )
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
                evaluator: RuleEvaluator(
                    config: config,
                    activeProjectRootsByRecipe: activeRootsByRecipe,
                    idleHoursByRecipe: idleHours
                ),
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

    func cleanItem(_ item: ScanItem) async -> CleanOutcome? {
        // 详情页点击“立即清理”即用户确认：
        // safeWhileRunning 与 userConfirm 放行，displayOnly（用户数据）除外；
        // requiresQuit 须先退出相关进程（如 Simulator）才能清理。
        guard item.cleanability != .displayOnly else {
            return nil
        }
        switch item.safety {
        case .safeWhileRunning, .userConfirm:
            break
        case .requiresQuit:
            guard let processName = Self.processName(for: item),
                  !PGrepProcessInspector().isRunning(processName) else {
                return nil
            }
        }
        state.isCleaning = true
        state.cleanedItemIDs = []
        state.deletingItemID = item.id
        let logStore = self.logStore
        let work = Task.detached(priority: .userInitiated) { () -> CleanOutcome? in
            do {
                let targetPaths = item.paths.isEmpty ? [item.path] : item.paths
                var freedBytes: Int64 = 0
                var trashPaths: [String] = []
                for target in targetPaths {
                    let deletion = try FileManagerFileDeleter().deleteReturningResult(
                        url: URL(fileURLWithPath: target),
                        disposition: .trash
                    )
                    freedBytes += deletion.freedBytes
                    if let trash = deletion.resultingURL?.path {
                        trashPaths.append(trash)
                    }
                }
                let entry = CleanLogEntry(
                    id: UUID(),
                    timestamp: Date(),
                    itemIDs: [item.id],
                    itemNames: [item.name],
                    originalPaths: targetPaths,
                    trashPaths: trashPaths,
                    batchID: UUID(),
                    freedBytes: freedBytes,
                    disposition: .trash,
                    source: .manual
                )
                try logStore.append(entry)
                return CleanOutcome(
                    entries: [entry],
                    freedBytes: freedBytes,
                    actualFreedBytes: 0,
                    stillBelowWaterline: false
                )
            } catch {
                return nil
            }
        }
        guard let outcome = await work.value else {
            state.isCleaning = false
            state.deletingItemID = nil
            state.deletingProgress = 1
            return nil
        }
        state.isCleaning = false
        await scanNow(autoClean: false)
        state.lastCleanSummary = Localized.string(
            "clean.summary",
            outcome.entries.count,
            Format.bytes(outcome.freedBytes)
        )
        state.cleanCelebrationID += 1
        return outcome
    }

    private static func processName(for item: ScanItem) -> String? {
        switch item.category {
        case .xcode:
            return "Xcode"
        case .simulator:
            return "Simulator"
        default:
            return nil
        }
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

    nonisolated private static func progressiveBatchName(for policy: ProgressiveCleanupPolicy) -> String {
        let sourceName = URL(fileURLWithPath: policy.parentPath).lastPathComponent
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return "PoolProblem Cleanup \(sourceName) \(formatter.string(from: Date()))"
    }

    // MARK: - Proactive auto-clean

    private func upcomingAutoCleanPlans(result: ScanResult) -> [AutoCleanPlanItem] {
        let now = Date()
        let waterline = waterlineBytes()
        let nextScan = now.addingTimeInterval(30 * 60)
        let oneWeek: Double = 7 * 86_400
        var plans: [AutoCleanPlanItem] = []

        let safeItems = result.items.filter {
            $0.recipeID != "trash"
                && $0.safety == .safeWhileRunning
                && $0.reclaimableBytes > 0
        }
        let safeReclaimableBytes = safeItems.reduce(Int64(0)) { $0 + $1.reclaimableBytes }
        let safeItemIDs = Set(safeItems.map(\.id))
        let safeGrowthRate = state.growthRates
            .filter { safeItemIDs.contains($0.key) && $0.value > 0 }
            .values
            .reduce(0, +)

        // 1. 水线守护 / 接近水线
        if result.volume.availableBytes < waterline {
            plans.append(AutoCleanPlanItem(
                id: UUID(),
                title: Localized.string("countdown.plan_below"),
                estimatedDate: nextScan,
                progress: 1
            ))
        } else if result.volume.availableBytes < waterline + proactiveCleanTriggerBytes {
            let distance = Double(max(0, result.volume.availableBytes - waterline))
            let span = Double(proactiveCleanTriggerBytes)
            let progress = 1 - min(1, distance / span)
            plans.append(AutoCleanPlanItem(
                id: UUID(),
                title: Localized.string("countdown.plan_near", Format.bytes(proactiveCleanBatchBytes)),
                estimatedDate: nextScan,
                progress: progress
            ))
        } else if let days = state.predictionDays, days <= 7 {
            let progress = min(1, max(0.05, 1 - min(1, days / 30)))
            plans.append(AutoCleanPlanItem(
                id: UUID(),
                title: Localized.string("countdown.plan_waterline_prediction"),
                estimatedDate: now.addingTimeInterval(days * 86_400),
                progress: progress
            ))
        }

        // 2. 可清理项库存 / 快速增长 / 子项数量
        let fastGrowingItem = safeItems.max { left, right in
            (state.growthRates[left.id] ?? 0) < (state.growthRates[right.id] ?? 0)
        }
        let fastestGrowthRate = fastGrowingItem.map { state.growthRates[$0.id] ?? 0 } ?? 0
        if fastestGrowthRate >= fastGrowthTriggerBytesPerDay, let fastGrowingItem {
            plans.append(AutoCleanPlanItem(
                id: UUID(),
                title: Localized.string("countdown.plan_fast_growth", name(for: fastGrowingItem.recipeID)),
                estimatedDate: nextScan,
                progress: 1
            ))
        } else if let manyChildrenItem = safeItems.first(where: { item in
            (POSIXDirectoryWalker.firstLevelCount(path: item.path) ?? 0) > 10
        }) {
            let childCount = POSIXDirectoryWalker.firstLevelCount(path: manyChildrenItem.path) ?? 0
                plans.append(AutoCleanPlanItem(
                    id: UUID(),
                    title: Localized.string("countdown.plan_many_children", name(for: manyChildrenItem.recipeID), childCount),
                    estimatedDate: nextScan,
                    progress: min(1, Double(childCount) / 12)
                ))
        }

        if plans.count < 2, safeReclaimableBytes >= earlyProactiveTriggerBytes {
            plans.append(AutoCleanPlanItem(
                id: UUID(),
                title: Localized.string("countdown.plan_large_reclaimable", Format.bytes(safeReclaimableBytes)),
                estimatedDate: nextScan,
                progress: 1
            ))
        }

        if plans.count < 2, safeGrowthRate > 0 {
            let remainingBytes = max(0, earlyProactiveTriggerBytes - safeReclaimableBytes)
            let daysToThreshold = Double(remainingBytes) / safeGrowthRate
            if daysToThreshold <= 7 {
                let estimatedDate = now.addingTimeInterval(daysToThreshold * 86_400)
                plans.append(AutoCleanPlanItem(
                    id: UUID(),
                    title: Localized.string("countdown.plan_inventory_waiting"),
                    estimatedDate: estimatedDate,
                    progress: min(1, Double(safeReclaimableBytes) / Double(earlyProactiveTriggerBytes))
                ))
            }
        }

        // 3. 废纸篓积累：自动清理移入废纸篓的项并不释放空间，提示清空
        let trashBytes = result.items
            .filter { $0.recipeID == "trash" }
            .reduce(Int64(0)) { $0 + max(0, $1.reclaimableBytes) }
        if trashBytes >= 5_000_000_000 {
            plans.append(AutoCleanPlanItem(
                id: UUID(),
                title: Localized.string("countdown.plan_trash", Format.bytes(trashBytes)),
                estimatedDate: nil,
                progress: 1
            ))
        }

        return plans
            .filter { plan in
                guard let estimatedDate = plan.estimatedDate else { return true }
                return estimatedDate.timeIntervalSince(now) <= oneWeek
            }
            .prefix(2)
            .map { $0 }
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

        let emergency = result.volume.availableBytes < waterline + proactiveCleanTriggerBytes
        if let target {
            if let outcome = await runAutoWaterlineClean(
                scan: result,
                config: config,
                waterlineBytes: target,
                forceClean: false,
                // 紧急（低于水位附近）时忽略年龄/最近修改保护，但保留处置方式
                ignoreAge: emergency,
                minimumItemBytes: autoMinimumCleanItemBytes,
                itemGrowthRates: state.growthRates
            ) {
                totalCount += outcome.entries.count
                // 以实测释放为准：移入废纸篓的项实际不释放空间，不虚报
                totalFreed += outcome.actualFreedBytes
                if !outcome.calibrationUpdates.isEmpty {
                    var updated = config
                    for (recipeID, ratio) in outcome.calibrationUpdates {
                        updated.cloneRatios[recipeID] = ratio
                    }
                    writeConfig(updated)
                }
            }
        }

        let progressive = await runProgressiveCleanup(config: config, emergency: emergency)
        totalCount += progressive.entries.count
        totalFreed += progressive.freedBytes

        if totalCount > 0 {
            state.lastCleanSummary = Localized.string(
                "clean.auto_summary",
                totalCount,
                Format.bytes(totalFreed)
            )
            state.autoCleanPlan = ""
            state.autoCleanPlans = []
            refreshCleanLogEntries()
        }
    }

    private func runAutoWaterlineClean(
        scan: ScanResult,
        config: Config,
        waterlineBytes: Int64,
        forceClean: Bool = false,
        ignoreAge: Bool = false,
        minimumItemBytes: Int64? = nil,
        itemGrowthRates: [String: Double] = [:]
    ) async -> CleanOutcome? {
        state.isCleaning = true
        state.cleanedItemIDs = []
        state.deletingItemID = firstAutoPlannedItem(
            scan: scan,
            config: config,
            minimumItemBytes: minimumItemBytes
        )?.id
        let logStore = self.logStore
        let state = self.state
        let recipes = activeRecipes()
        let activeRootsByRecipe = projectActiveRootsByRecipe(recipes: recipes)
        let idleHours = idleHoursByRecipe(recipes: recipes)
        let work = Task.detached(priority: .utility) { () -> CleanOutcome? in
            let cleaner = Cleaner(
                evaluator: RuleEvaluator(
                    config: config,
                    activeProjectRootsByRecipe: activeRootsByRecipe,
                    idleHoursByRecipe: idleHours
                ),
                deleter: FileManagerFileDeleter(),
                inspector: PGrepProcessInspector(),
                logStore: logStore
            )
            return try? cleaner.run(
                scan: scan,
                config: config,
                waterlineBytes: waterlineBytes,
                forceClean: forceClean,
                ignoreAge: ignoreAge,
                source: .auto,
                minimumItemBytes: minimumItemBytes,
                itemGrowthRates: itemGrowthRates,
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
            state.deletingItemID = nil
            return nil
        }
        state.isCleaning = false
        state.deletingItemID = nil
        return outcome
    }

    private func runProgressiveCleanup(
        config: Config,
        emergency: Bool
    ) async -> ProgressiveCleanupOutcome {
        let policies = progressivePolicies(config: config, emergency: emergency)
        guard !policies.isEmpty else { return .empty }
        state.isCleaning = true
        let logStore = self.logStore
        let work = Task.detached(priority: .utility) { () -> ProgressiveCleanupOutcome in
            var entries: [CleanLogEntry] = []
            var freedBytes: Int64 = 0
            var trimmedCount = 0
            var remainingCount = 0
            for policy in policies {
                let batchName = Self.progressiveBatchName(for: policy)
                let deleter: FileDeleting = policy.disposition == .trash
                    ? TrashBatchDeleter(batchName: batchName)
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

    private func progressivePolicies(
        config: Config,
        emergency: Bool
    ) -> [ProgressiveCleanupPolicy] {
        var policies: [ProgressiveCleanupPolicy] = []
        for item in state.items {
            guard item.recipeID != "trash",
                  !item.recipeID.hasPrefix("project-"),
                  item.safety == .safeWhileRunning,
                  item.reclaimableBytes > 0,
                  !config.whitelistPaths.contains(item.path),
                  !config.keptItemIDs.contains(item.id) else {
                continue
            }
            if let rule = config.rules.first(where: { $0.recipeID == item.recipeID }),
               !rule.enabled {
                continue
            }
            guard let recipe = activeRecipes().first(where: { $0.id == item.recipeID }) else {
                continue
            }
            guard let childCount = POSIXDirectoryWalker.firstLevelCount(path: item.path),
                  childCount > 0 else {
                continue
            }
            let ratio = recipe.cloneProne
                ? (config.cloneRatios[item.recipeID] ?? 0.2)
                : 1

            if emergency {
                policies.append(ProgressiveCleanupPolicy(
                    recipeID: item.recipeID,
                    parentPath: item.path,
                    maxChildren: 0,
                    maxItemsPerRun: 3,
                    minimumAgeSeconds: emergencyProgressiveMinimumAgeSeconds,
                    disposition: .trash,
                    source: .auto,
                    reclaimableRatio: ratio,
                    minimumCleanBytes: autoMinimumCleanItemBytes,
                    minimumCandidateBytes: autoMinimumCleanItemBytes,
                    protectedChildNames: ProgressiveCleanupPolicy.mergedProtectedChildNames(
                        recipe: recipe,
                        config: config
                    )
                ))
                continue
            }

            let growthRate = state.growthRates[item.id] ?? 0
            let fastGrowing = growthRate >= fastGrowthTriggerBytesPerDay
            let tooManyChildren = childCount > 10
            guard fastGrowing || tooManyChildren else { continue }
            policies.append(ProgressiveCleanupPolicy(
                recipeID: item.recipeID,
                parentPath: item.path,
                maxChildren: fastGrowing ? 0 : 10,
                maxItemsPerRun: 3,
                minimumAgeSeconds: 86_400,
                disposition: .trash,
                source: .auto,
                reclaimableRatio: ratio,
                minimumCleanBytes: autoMinimumCleanItemBytes,
                minimumCandidateBytes: autoMinimumCleanItemBytes,
                protectedChildNames: ProgressiveCleanupPolicy.mergedProtectedChildNames(
                    recipe: recipe,
                    config: config
                )
            ))
        }
        return policies
    }

    private func firstAutoPlannedItem(
        scan: ScanResult,
        config: Config,
        minimumItemBytes: Int64? = nil
    ) -> ScanItem? {
        scan.items
            .filter { item in
                item.reclaimableBytes > 0
                    && (minimumItemBytes.map { item.reclaimableBytes >= $0 } ?? true)
                    && item.recipeID != "trash"
                    && item.safety == .safeWhileRunning
                    && !config.whitelistPaths.contains(item.path)
                    && !config.keptItemIDs.contains(item.id)
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
                paths: item.paths,
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
            paths: item.paths,
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

    /// 每次扫描后：更新增长台账（含配方外未知空间与表面目录），
    /// 并刷新候选配方建议。
    private func updateGrowthInsights(previous: Snapshot?, latest: Snapshot) async {
        let home = NSHomeDirectory()
        let builder = GrowthLedgerBuilder()
        var entries = builder.entries(previous: previous, latest: latest, homeDirectory: home)
        // 表面扫描兜底：每 6 小时一次（目录级归因的基础；实时由 FSEvents 增量承担）
        let lastScan = growthLedgerStore.lastSurfaceScanAt()
        if lastScan == nil || Date().timeIntervalSince(lastScan!) >= 6 * 3600 {
            let roots = SurfaceScanner.defaultRoots(homeDirectory: home)
            let dirs = await Task.detached(priority: .utility) {
                SurfaceScanner().scan(roots: roots)
            }.value
            let prevDirs = (try? growthLedgerStore.surfaceDirectories()) ?? []
            entries.append(contentsOf: builder.surfaceEntries(
                previous: prevDirs,
                latest: dirs,
                homeDirectory: home
            ))
            try? growthLedgerStore.saveSurface(dirs, scannedAt: Date())
        }
        try? growthLedgerStore.append(entries)
        try? growthLedgerStore.prune(retainingDays: 30)
        let allEntries = (try? growthLedgerStore.entries()) ?? []
        let candidates = RecipeSuggester().suggest(
            entries: allEntries,
            existingRecipes: activeRecipes(),
            homeDirectory: home
        )
        try? recipeSuggestionStore.merge(candidates)
        state.growthInsights = growthInsights(from: allEntries)
        state.candidateRecipes = (try? recipeSuggestionStore.load()) ?? []
        suggestDevRootsFromGrowth(allEntries: allEntries)
    }

    /// 启动时从磁盘恢复增长洞察与候选配方状态。
    private func refreshGrowthState() {
        let allEntries = (try? growthLedgerStore.entries()) ?? []
        state.growthInsights = growthInsights(from: allEntries)
        state.candidateRecipes = (try? recipeSuggestionStore.load()) ?? []
        Task { await maybeDiscoverDevDirectories() }
    }

    /// 主动发现开发目录（无需增长触发）：找出基线之前就已存在、
    /// 含大量可重建内容（node_modules/dist/build）的项目并建议加入监控。
    /// 默认每 1 小时最多执行一次，避免频繁全量测量；force 时立即执行。
    private func maybeDiscoverDevDirectories(force: Bool = false) async {
        let home = NSHomeDirectory()
        guard force || Date().timeIntervalSince(lastDevDiscoveryAt) >= 3600 else { return }
        lastDevDiscoveryAt = Date()
        let known = Set(loadConfig().devRoots + loadConfig().declinedDevRoots)
        let found = await Task.detached(priority: .utility) {
            DevDirectoryDiscovery.discover(homeDirectory: home)
        }.value
        let existing = Set(state.pendingDevRoots.map(\.path))
        var fresh = found
            .filter { !isKnownDevPath($0.path, known: known) && !existing.contains($0.path) }
            .map { DevRootCandidate(path: $0.path, marker: $0.marker, bytes: $0.regenerableBytes, source: .discovery) }
        // FSEvents 写活动：无标记/新项目也能被发现（来源"近期活跃"）
        for activity in devActivityTracker.activeProjects(since: 48 * 3600)
        where !isKnownDevPath(activity.projectRoot, known: known) && !existing.contains(activity.projectRoot)
            && !fresh.contains(where: { $0.path == activity.projectRoot }) {
            fresh.append(DevRootCandidate(
                path: activity.projectRoot,
                marker: activity.artifact,
                bytes: 0,
                source: .activity
            ))
        }
        if !fresh.isEmpty {
            state.pendingDevRoots += Array(groupDevRootCandidates(fresh).prefix(5))
        }
        #if DEBUG
        let line = "[\(Date())] discovery: found=\(found.count) fresh=\(fresh.count) "
            + "known=\(known.count) first=\(found.prefix(3).map(\.path).joined(separator: "|"))\n"
        if let data = line.data(using: .utf8) {
            let url = URL(fileURLWithPath: "/tmp/poolproblem-discovery.log")
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                handle.write(data)
                try? handle.close()
            } else {
                try? data.write(to: url)
            }
        }
        #endif
    }

    /// 供 UI 手动/打开洞察时触发开发目录发现。
    func refreshDevSuggestions(force: Bool = true) async {
        await maybeDiscoverDevDirectories(force: force)
    }

    /// 增长洞察展示过滤：只保留配方未覆盖、可归因到目录的增长。
    /// 残差条目（历史数据中的 unknownSpace）一律剔除——它无法归因，只会制造焦虑。
    private func uncoveredInsights(_ entries: [GrowthEntry]) -> [GrowthEntry] {
        let home = NSHomeDirectory()
        let covered = RecipeCoverage.coveredPatterns(
            recipes: activeRecipes(),
            homeDirectory: home
        )
        let devRoots = loadConfig().devRoots
        return entries.filter { entry in
            if entry.kind == .unknownSpace { return false }
            // 已列入监控的开发目录整棵子树视为已覆盖：其中的项目 node_modules /
            // 构建产物即使已被清理删除（不再出现在配方路径里），其历史增长也不再
            // 显示——否则会看到一条“无法采取进一步动作”的项目增长记录。
            if devRoots.contains(where: { entry.path == $0 || entry.path.hasPrefix($0 + "/") }) {
                return false
            }
            return !RecipeCoverage.isCovered(
                path: entry.path,
                coveredPatterns: covered,
                homeDirectory: home
            )
        }
    }

    /// 当前生效的配方：系统内置 + 用户确认的项目目录配方。
    private func activeRecipes() -> [Recipe] {
        RecipeRegistry.builtIn()
            + ProjectRecipes.make(devRoots: loadConfig().devRoots, homeDirectory: NSHomeDirectory())
    }

    /// 各配方用户配置的年龄阈值（天），未配置的配方回落 recipe.defaultAgeDays。
    private func ageDaysByRecipe() -> [String: Int] {
        var result: [String: Int] = [:]
        for rule in loadConfig().rules {
            if let days = rule.maxAgeDays {
                result[rule.recipeID] = days
            }
        }
        return result
    }

    /// 各项目配方在“各自活跃窗口”内最近有 FSEvents 写活动的项目根：
    /// 构建产物窗口短（6h），node_modules 窗口长（72h），由 recipe.minimumIdleHours 决定。
    private func projectActiveRootsByRecipe(recipes: [Recipe]) -> [String: Set<String>] {
        Dictionary(uniqueKeysWithValues: recipes.compactMap { recipe in
            guard recipe.id.hasPrefix("project-") else { return nil }
            let roots = Set(
                devActivityTracker
                    .activeProjects(since: recipe.minimumIdleHours * 3600)
                    .map(\.projectRoot)
            )
            return (recipe.id, roots)
        })
    }

    /// 各配方最短闲置小时数（mtime 判定），供 RuleEvaluator 使用。
    private func idleHoursByRecipe(recipes: [Recipe]) -> [String: Double] {
        Dictionary(uniqueKeysWithValues: recipes.map { ($0.id, $0.minimumIdleHours) })
    }

    /// 用户确认把某个目录加入开发目录监控。
    func confirmDevRoot(_ path: String) {
        var config = loadConfig()
        guard !config.devRoots.contains(path) else { return }
        config.devRoots.append(path)
        config.declinedDevRoots.removeAll { $0 == path }
        writeConfig(config)
        state.pendingDevRoots.removeAll { $0.path == path || $0.path.hasPrefix(path + "/") }
        // 立即重扫，让项目配方（聚合条目）出现在清理列表中
        Task { await scanNow(autoClean: false) }
    }

    /// 用户忽略该目录：记入忽略列表，避免重复提示。
    func declineDevRoot(_ path: String) {
        var config = loadConfig()
        if !config.declinedDevRoots.contains(path) {
            config.declinedDevRoots.append(path)
        }
        writeConfig(config)
        state.pendingDevRoots.removeAll { $0.path == path }
    }

    /// 从监控中移除用户添加的开发目录。
    func removeDevRoot(_ path: String) {
        var config = loadConfig()
        config.devRoots.removeAll { $0 == path }
        writeConfig(config)
    }

    /// 增长洞察展示：过滤配方覆盖项后，把多条"未覆盖空间"聚合成
    /// 只保留可归因的目录级增长（最新 30 条，新→旧）。
    private func growthInsights(from allEntries: [GrowthEntry]) -> [GrowthEntry] {
        Array(
            GrowthInsightMerger.merge(uncoveredInsights(allEntries))
                .sorted { $0.observedAt > $1.observedAt }
                .prefix(30)
        )
    }

    /// 增长来源的开发目录建议：表面扫描发现的未覆盖增长中，命中项目标记的
    /// 提示用户加入监控（来源"增长"）。已知/忽略/已在建议中的不再重复。
    private func suggestDevRootsFromGrowth(allEntries: [GrowthEntry]) {
        let config = loadConfig()
        let known = Set(config.devRoots + config.declinedDevRoots)
        let existing = Set(state.pendingDevRoots.map(\.path))
        let fresh: [DevRootCandidate] = uncoveredInsights(allEntries).compactMap { entry in
            guard !isKnownDevPath(entry.path, known: known),
                  !existing.contains(entry.path),
                  let kind = DevDirectoryDetector.detect(path: entry.path) else { return nil }
            return DevRootCandidate(path: entry.path, marker: kind.rawValue, bytes: entry.deltaBytes, source: .growth)
        }
        if !fresh.isEmpty {
            state.pendingDevRoots += Array(groupDevRootCandidates(fresh).prefix(3))
        }
    }

    /// 路径是否已被某个已确认/忽略的开发目录覆盖（自身或其子树）。
    private func isKnownDevPath(_ path: String, known: Set<String>) -> Bool {
        known.contains { $0 == path || path.hasPrefix($0 + "/") }
    }

    /// 把建议按父目录归并：同一父目录下有 ≥2 个项目时，只建议监控父目录
    /// （一次确认覆盖全部），散落的项目保持单独建议。
    private func groupDevRootCandidates(_ candidates: [DevRootCandidate]) -> [DevRootCandidate] {
        var byParent: [String: [DevRootCandidate]] = [:]
        for candidate in candidates {
            let parent = URL(fileURLWithPath: candidate.path).deletingLastPathComponent().path
            byParent[parent, default: []].append(candidate)
        }
        var result: [DevRootCandidate] = []
        for (parent, group) in byParent {
            if group.count >= 2 {
                let total = group.reduce(Int64(0)) { $0 + $1.bytes }
                let names = group.compactMap { URL(fileURLWithPath: $0.path).lastPathComponent }
                result.append(DevRootCandidate(
                    path: parent,
                    marker: "group",
                    bytes: total,
                    source: .discovery,
                    childNames: names
                ))
            } else if let single = group.first {
                result.append(single)
            }
        }
        return result.sorted { $0.bytes > $1.bytes }
    }

    func acceptCandidate(id: String) {
        setCandidateStatus(id: id, status: .accepted)
    }

    func dismissCandidate(id: String) {
        setCandidateStatus(id: id, status: .dismissed)
    }

    private func setCandidateStatus(id: String, status: CandidateStatus) {
        try? recipeSuggestionStore.setStatus(id: id, status: status)
        state.candidateRecipes = (try? recipeSuggestionStore.load()) ?? []
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
