import AppKit
import Foundation
import DiskReservoirCore

enum ManualCleanFailure: Equatable, Sendable {
    case unavailable
    case processRunning(String)
    case recentlyModified
    case permissionDenied
    case fileInUse
    case fileSystem(String)
}

enum ManualCleanResult: Sendable {
    case cleaned(CleanOutcome)
    case failed(ManualCleanFailure)
}

private struct ManualCleanExecution: Sendable {
    var entries: [CleanLogEntry]
    var firstFailure: ManualCleanFailure?
}

private struct TrashDirectoryFingerprint: Sendable {
    let exists: Bool
    let childCount: Int?
    let modificationDate: Date?
}

private struct DashboardConsistencyReading: Sendable {
    let volume: VolumeInfo
    let trashReplacements: [String: ScanItem]
    let trashFingerprints: [String: TrashDirectoryFingerprint]
    let allTrashPathsReadable: Bool
}

nonisolated private func manualCleanFailure(for error: Error) -> ManualCleanFailure {
    let nsError = error as NSError
    if nsError.domain == NSCocoaErrorDomain {
        switch CocoaError.Code(rawValue: nsError.code) {
        case .fileReadNoPermission, .fileWriteNoPermission:
            return .permissionDenied
        case .fileLocking, .fileWriteVolumeReadOnly:
            return .fileInUse
        default:
            break
        }
    }
    if nsError.domain == NSPOSIXErrorDomain {
        switch POSIXErrorCode(rawValue: Int32(nsError.code)) {
        case .EACCES, .EPERM:
            return .permissionDenied
        case .EBUSY, .ETXTBSY:
            return .fileInUse
        default:
            break
        }
    }
    return .fileSystem(nsError.localizedDescription)
}

@MainActor
final class AppService {
    private let state: AppState
    private let paths: StoragePaths
    private let snapshotStore: SnapshotStore
    private let logStore: CleanLogStore
    private let ownerCommandRecordStore: OwnerCommandRecordStore
    private let knownPnpmTargetsStore: OwnerCommandKnownTargetsStore
    private let pnpmRunner: OwnerCommandRunner
    private(set) var currentPnpmStoreTarget: OwnerCommandTarget?
    private(set) var lastPnpmProbeFailure: OwnerCommandFailure?
    private var knownPnpmStorePaths: [String]
    private var pnpmHistoryOverflowed: Bool
    private let growthLedgerStore: GrowthLedgerStore
    private let recipeSuggestionStore: RecipeSuggestionStore
    private let cleanupCoordinator: CleanupCoordinator
    private var lastDevDiscoveryAt = Date.distantPast
    private let automationEnabled: Bool
    private var timer: Timer?
    private var lowSpaceNotified = false
    private var trashAccumulationNotified = false
    private var interactionResumeTask: Task<Void, Never>?
    private let launchedAt = Date()
    private var lastPressureState: DiskPressureState?
    private var lastAnalysisAt = Date.distantPast
    private var lastAnalyzedAvailableBytes: Int64?
    /// A scan request arriving during another scan must be coalesced, not lost.
    private var pendingScanRequested = false
    private var pendingScanAutoClean = false
    private var pendingScanClearsSummary = false
    /// Incremented after a filesystem mutation so an older in-flight scan
    /// cannot overwrite the optimistic post-cleanup state with stale results.
    private var scanRevision = 0
    private var trashFingerprints: [String: TrashDirectoryFingerprint] = [:]

    /// 最小清理规模（MB → bytes），专家设置，默认 500MB。
    private func minimumCleanItemBytes(_ config: Config) -> Int64 {
        Int64(config.minimumCleanItemMB * 1_000_000)
    }

    init(
        state: AppState, paths: StoragePaths = StoragePaths(),
        automationEnabled: Bool = true, pnpmRunner: OwnerCommandRunner? = nil
    ) {
        self.state = state
        self.paths = paths
        self.snapshotStore = SnapshotStore(paths: paths)
        self.logStore = CleanLogStore(paths: paths)
        self.ownerCommandRecordStore = OwnerCommandRecordStore(paths: paths)
        let knownStore = OwnerCommandKnownTargetsStore(paths: paths)
        self.knownPnpmTargetsStore = knownStore
        let retainedSnapshots: [Snapshot]
        var historyLoadFailed = false
        do { retainedSnapshots = try SnapshotStore(paths: paths).snapshots() }
        catch { retainedSnapshots = []; historyLoadFailed = true }
        let knownState: OwnerCommandKnownTargetsStore.State
        do { knownState = try knownStore.migrate(snapshots: retainedSnapshots) }
        catch {
            let saved = (try? knownStore.state()) ?? .init()
            let migrated = retainedSnapshots.flatMap { snapshot in
                snapshot.items.filter {
                    $0.recipeID == OwnerCommandRecipe.pnpmStorePrune.id
                }.map(\.path)
            }
            knownState = .init(
                paths: Array((saved.paths + migrated).suffix(OwnerCommandKnownTargetsStore.maximumPaths)),
                overflowed: true
            )
        }
        self.knownPnpmStorePaths = knownState.paths
        self.pnpmHistoryOverflowed = knownState.overflowed || historyLoadFailed
        self.pnpmRunner = pnpmRunner ?? OwnerCommandRunner(
            recipe: .pnpmStorePrune, home: paths.homeDirectory
        )
        self.growthLedgerStore = GrowthLedgerStore(paths: paths)
        self.recipeSuggestionStore = RecipeSuggestionStore(paths: paths)
        self.automationEnabled = automationEnabled
        self.cleanupCoordinator = CleanupCoordinator { [weak state] cleaning in
            state?.isCleaning = cleaning
        }
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
        Task {
            await loadLatestState()
            await reconcileDashboardState()
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            await monitorAvailableSpace()
        }
        timer?.invalidate()
        // Capacity probing is cheap; recursive analysis is pressure-triggered.
        timer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in await self?.monitorAvailableSpace() }
        }
    }

    private func monitorAvailableSpace() async {
        let volume = await reconcileDashboardState()

        let policy = DiskPressurePolicy(targetBytes: waterlineBytes())
        let pressure = policy.state(availableBytes: volume.availableBytes)
        let shouldAnalyze = policy.shouldAnalyze(
            state: pressure,
            previousState: lastPressureState,
            now: Date(),
            lastAnalysisAt: lastAnalysisAt,
            availableBytes: volume.availableBytes,
            lastAnalyzedAvailableBytes: lastAnalyzedAvailableBytes
        )
        lastPressureState = pressure
        guard shouldAnalyze else { return }
        lastAnalysisAt = Date()
        lastAnalyzedAvailableBytes = volume.availableBytes

        switch pressure {
        case .healthy:
            return
        case .warning:
            await scanNow(autoClean: false)
        case .critical:
            await scanNow(autoClean: true)
        }
    }

    /// Reconciles the cheap live facts that can change without a Pool Problem
    /// scan: APFS capacity and Trash contents. All visible consumers receive
    /// one frame, so the menu icon, tank, and right panel cannot mix different
    /// generations of these values.
    @discardableResult
    func reconcileDashboardState() async -> VolumeInfo {
        if state.consistencyStatus == .reconciling {
            return VolumeInfo(
                totalBytes: state.totalBytes,
                availableBytes: state.availableBytes,
                timestamp: Date()
            )
        }
        state.consistencyStatus = .reconciling
        let currentItems = state.items
        let lastScanAt = state.lastScanAt
        let previousFingerprints = trashFingerprints
        let homeDirectory = NSHomeDirectory()
        let reading = await Task.detached(priority: .utility) {
            Self.readDashboardConsistency(
                homeDirectory: homeDirectory,
                currentItems: currentItems,
                lastScanAt: lastScanAt,
                previousFingerprints: previousFingerprints
            )
        }.value

        var replacements = reading.trashReplacements
        var items = state.items.map { item -> ScanItem in
            guard item.recipeID == "trash", let replacement = replacements.removeValue(forKey: item.path) else {
                return item
            }
            return replacement
        }
        items.append(contentsOf: replacements.values.sorted { $0.path < $1.path })
        let trashChanged = items != state.items
        if trashChanged {
            // Any recursive scan already in flight predates this external
            // filesystem observation and must not overwrite it.
            scanRevision &+= 1
        }
        state.availableBytes = reading.volume.availableBytes
        state.totalBytes = reading.volume.totalBytes
        state.items = items
        trashFingerprints = reading.trashFingerprints
        state.consistencyStatus = reading.allTrashPathsReadable ? .current : .partial
        refreshGaugeImage()
        return reading.volume
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
        state.lastOwnerCommandRecord = try? ownerCommandRecordStore.entries().last
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

    func scanNow(autoClean: Bool = false, clearCleanSummary: Bool = true) async {
        guard !state.isScanning else {
            pendingScanRequested = true
            pendingScanAutoClean = pendingScanAutoClean || autoClean
            pendingScanClearsSummary = pendingScanClearsSummary || clearCleanSummary
            return
        }
        state.isScanning = true
        if clearCleanSummary {
            state.lastCleanSummary = nil
        }
        let startedAtRevision = scanRevision
        defer {
            state.isScanning = false
            if pendingScanRequested {
                let autoClean = pendingScanAutoClean
                let clearSummary = pendingScanClearsSummary
                pendingScanRequested = false
                pendingScanAutoClean = false
                pendingScanClearsSummary = false
                Task { @MainActor [weak self] in
                    await self?.scanNow(autoClean: autoClean, clearCleanSummary: clearSummary)
                }
            }
        }
        let paths = self.paths
        let cloneRatios = loadConfig().cloneRatios
        let ageRules = ageDaysByRecipe()
        let pnpmRunner = self.pnpmRunner
        let pnpmProbe = await Task.detached(priority: .utility) {
            pnpmRunner.probe()
        }.value
        let pnpmTarget = try? pnpmProbe.get()
        if let pnpmTarget {
            if let history = try? knownPnpmTargetsStore.record([pnpmTarget.path]) {
                knownPnpmStorePaths = history.paths
                // A startup read/migration failure may have lost an older
                // target even if this later write succeeds. Keep the guard
                // closed for this session.
                pnpmHistoryOverflowed = pnpmHistoryOverflowed || history.overflowed
            } else {
                if !knownPnpmStorePaths.contains(pnpmTarget.path) {
                    knownPnpmStorePaths.append(pnpmTarget.path)
                }
                pnpmHistoryOverflowed = true
            }
        }
        let pnpmFailure: OwnerCommandFailure?
        if case .failure(let failure) = pnpmProbe, failure != .unavailable {
            pnpmFailure = failure
        } else {
            pnpmFailure = nil
        }
        let recipes = recipes(pnpmTarget: pnpmTarget)
        let protectedPnpmPaths = knownPnpmStorePaths
        let work = Task.detached(priority: .background) { () -> (ScanResult, Snapshot?, [Snapshot])? in
            guard let result = try? DiskReservoirCore.Scanner(
                cloneRatios: cloneRatios,
                ageDaysByRecipe: ageRules,
                protectedOwnerPaths: protectedPnpmPaths
            ).scan(
                recipes: recipes,
                homeDirectory: paths.homeDirectory
            ) else { return nil }
            let snapshot = Snapshot(volume: result.volume, items: result.items)
            let store = SnapshotStore(paths: paths)
            let previous = try? store.snapshots().last
            try? store.append(snapshot)
            let all = (try? store.snapshots()) ?? []
            return (result, previous, all)
        }
        guard let (result, previous, all) = await work.value else {
            currentPnpmStoreTarget = nil
            lastPnpmProbeFailure = pnpmFailure
            return
        }
        guard startedAtRevision == scanRevision else {
            pendingScanRequested = true
            return
        }
        currentPnpmStoreTarget = pnpmTarget
        lastPnpmProbeFailure = pnpmFailure
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
            ?? Localized.string(
                "countdown.plan_idle",
                Format.bytes(CleanThresholds(
                    waterlineGB: Double(waterlineBytes()) / 1_000_000_000
                ).earlyTriggerBytes)
            )
        if !state.isCleaning {
            state.cleanedItemIDs = []
        }
        // Never delete during the first five minutes after launch. This grace
        // period lets process/activity state settle and keeps startup read-only.
        let automationWarmedUp = Date().timeIntervalSince(launchedAt) >= 5 * 60
        if automationEnabled, autoClean, automationWarmedUp {
            await maybeAutoClean(result: result)
            checkTrashAccumulation()
        }
        refreshGaugeImage()
    }

    /// Give the menu popover a short, deterministic head start over a running
    /// directory walk. The scan pauses cooperatively and resumes without losing
    /// progress after the first frame has settled.
    func prioritizePopoverPresentation() {
        interactionResumeTask?.cancel()
        ScanWorkloadGate.shared.pause()
        interactionResumeTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            ScanWorkloadGate.shared.resume()
            self?.interactionResumeTask = nil
        }
    }

    func endPopoverPresentationPriority() {
        interactionResumeTask?.cancel()
        interactionResumeTask = nil
        ScanWorkloadGate.shared.resume()
    }

    /// 数据变化后预生成 E 字型标尺位图（避免弹窗打开时执行重活）
    private func refreshGaugeImage() {
        let recipes = activeRecipes()
        let made = PoolWindowLayout.make(
            totalBytes: state.totalBytes,
            availableBytes: state.availableBytes,
            waterlineBytes: state.waterlineBytes,
            items: state.items,
            recipes: recipes,
            estimatedRecipeIDs: Set(recipes.filter(\.cloneProne).map(\.id)),
            excludedItemIDs: state.cleanedItemIDs
        )
        state.poolGaugeImage = GaugeImageRenderer.render(layout: made.layout)
    }

    /// Refresh only the volume counters after a filesystem mutation. This is
    /// intentionally separate from recursive analysis so the available-space
    /// label and water level do not wait for a full scan.
    private func refreshVolumeCapacity() async {
        let volume = await Task.detached(priority: .userInitiated) {
            VolumeReader.read(fileURL: URL(fileURLWithPath: NSHomeDirectory()))
        }.value
        state.availableBytes = volume.availableBytes
        state.totalBytes = volume.totalBytes
        refreshGaugeImage()
    }

    private func updateFlowMetrics(snapshots: [Snapshot]) async {
        state.waterlineBytes = waterlineBytes()
        guard !snapshots.isEmpty else { return }
        state.growthRates = FlowAnalyzer().growthRates(snapshots: snapshots)
        // 进水管：按配方聚合"增速"（排除废纸篓），显示每周增长
        let itemRecipe = Dictionary(uniqueKeysWithValues: state.items.map { ($0.id, $0) })
        var recipeRates: [String: Double] = [:]
        for (itemID, rate) in state.growthRates {
            guard let item = itemRecipe[itemID],
                  item.recipeID != "trash",
                  item.cleanability != .watchOnly else { continue }
            recipeRates[item.recipeID, default: 0] += rate
        }
        // 进水管：优先取增速前 2；不足 2 个时用当前可清理量最大的项补齐（都排除废纸篓）
        var inflows: [(String, Int64)] = recipeRates
            .sorted { $0.value > $1.value }
            .prefix(2)
            .map { (name(for: $0.key), Int64($0.value * 7)) }
        if inflows.count < 2 {
            let chosen = Set(recipeRates.keys)
            let fill = state.items
                .filter {
                    $0.recipeID != "trash"
                        && $0.cleanability != .watchOnly
                        && !chosen.contains($0.recipeID)
                }
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
            .filter { $0.timestamp >= cutoff && $0.disposition == .deletePermanently }
            .reduce(0) { $0 + $1.freedBytes }
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
        if dryRun {
            return await smartCleanInternal(dryRun: true)
        }
        // 真正清理走协调器串行执行，避免与自动清理并发
        return await cleanupCoordinator.run { [weak self] in
            await self?.smartCleanInternal(dryRun: false) ?? nil
        }
    }

    /// 每个配方在清理日志中的累计执行次数与清理字节（itemID 形如 "recipeID:path"）。
    func cleanStatsByRecipe() -> [String: (count: Int, bytes: Int64)] {
        let entries = (try? logStore.entries()) ?? []
        var result: [String: (count: Int, bytes: Int64)] = [:]
        for entry in entries {
            var seen = Set<String>()
            for itemID in entry.itemIDs {
                guard let recipeID = itemID.split(separator: ":").first.map(String.init),
                      seen.insert(recipeID).inserted else { continue }
                result[recipeID, default: (count: 0, bytes: 0)].count += 1
                result[recipeID, default: (count: 0, bytes: 0)].bytes += entry.freedBytes
            }
        }
        return result
    }

    private func smartCleanInternal(dryRun: Bool) async -> CleanOutcome? {
        let config = loadConfig()
        let logStore = self.logStore
        let cloneRatios = config.cloneRatios
        let state = self.state
        if !dryRun {
            state.cleanedItemIDs = []
            // 全量扫描期间没有逐项回调，先闪动预计第一个处理的小项，避免毫无反馈
            state.deletingItemID = firstPlannedItem()?.id
        }
        let recipes = activeRecipes()
        let activeRootsByRecipe = projectActiveRootsByRecipe(recipes: recipes)
        let idleHours = idleHoursByRecipe(recipes: recipes)
        let ageRules = ageDaysByRecipe()
        let groupsByRecipe = recipeGroups(recipes)
        let defaultAgesByRecipe = recipeDefaultAges(recipes)
        let homeDirectory = paths.homeDirectory
        let knownPnpmStorePaths = self.knownPnpmStorePaths
        let pnpmHistoryOverflowed = self.pnpmHistoryOverflowed
        let work = Task.detached(priority: .userInitiated) { () -> (ScanResult, CleanOutcome?)? in
            guard let result = try? DiskReservoirCore.Scanner(
                cloneRatios: cloneRatios,
                ageDaysByRecipe: ageRules,
                protectedOwnerPaths: knownPnpmStorePaths
            ).scan(
                recipes: recipes,
                homeDirectory: homeDirectory
            ) else { return nil }
            if dryRun {
                let evaluator = RuleEvaluator(
                    config: config,
                    activeProjectRootsByRecipe: activeRootsByRecipe,
                    idleHoursByRecipe: idleHours,
                    groupByRecipe: groupsByRecipe,
                    defaultAgeByRecipe: defaultAgesByRecipe
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
                    idleHoursByRecipe: idleHours,
                    groupByRecipe: groupsByRecipe,
                    defaultAgeByRecipe: defaultAgesByRecipe
                ),
                deleter: TrashBatchDeleter(batchName: Self.cleanupBatchName()),
                inspector: PGrepProcessInspector(),
                logStore: logStore,
                homeDirectory: homeDirectory,
                knownOwnerStorePaths: knownPnpmStorePaths,
                ownerHistoryOverflowed: pnpmHistoryOverflowed
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
                            if disposition == .trash {
                                self.growTrashItem(by: item.reclaimableBytes)
                            } else {
                                state.availableBytes = min(
                                    state.totalBytes,
                                    state.availableBytes + item.reclaimableBytes
                                )
                            }
                        }
                    }
                }
            )
            return (result, outcome)
        }
        guard let (_, outcome) = await work.value, let outcome else {
            return nil
        }
        if outcome.entries.contains(where: { $0.disposition == .trash }) {
            notifyTrashChanged()
        }
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

    func cleanItem(_ item: ScanItem) async -> ManualCleanResult {
        return await cleanupCoordinator.run { [weak self] in
            await self?.cleanItemSerialized(item) ?? .failed(.unavailable)
        }
    }

    private func cleanItemSerialized(_ item: ScanItem) async -> ManualCleanResult {
        // 详情页点击“立即清理”即用户确认：
        // safeWhileRunning 与 userConfirm 放行，displayOnly（用户数据）除外；
        // requiresQuit 须先退出相关进程（如 Simulator）才能清理。
        guard let currentRecipe = activeRecipes().first(where: { $0.id == item.recipeID }),
              item.recipeID != OwnerCommandRecipe.pnpmStorePrune.id,
              item.cleanability.allowsManualCleanup,
              currentRecipe.cleanability.allowsManualCleanup,
              // 废纸篓是特殊过渡区：只通过废纸篓详情页管理，不走通用清理
              item.recipeID != "own-trash-batches",
              item.recipeID != "trash",
              // 仅按子目录清理的项（如应用缓存）不整项删除
              !item.cleanByChildOnly,
              !currentRecipe.cleanByChildOnly else {
            return .failed(.unavailable)
        }
        let currentPaths = item.paths.isEmpty ? [item.path] : item.paths
        let scanProbe: Result<OwnerCommandTarget, OwnerCommandFailure> = currentPnpmStoreTarget
            .map(Result.success) ?? .failure(lastPnpmProbeFailure ?? .unavailable)
        let knownPaths = knownPnpmStorePaths
        if currentPaths.contains(where: {
            !OwnerManagedPathGuard.mayDelete(
                path: $0, recipeID: item.recipeID, probe: scanProbe,
                homeDirectory: paths.homeDirectory, knownStorePaths: knownPaths,
                historyOverflowed: pnpmHistoryOverflowed
            )
        }) {
            return .failed(.unavailable)
        }
        if item.recipeID == TemporaryBuildArtifacts.recipeID {
            let inspector = PGrepProcessInspector()
            if let running = TemporaryBuildArtifacts.guardProcessNames.first(where: inspector.isRunning) {
                return .failed(.processRunning(running))
            }
        }
        switch item.safety {
        case .safeWhileRunning, .userConfirm:
            break
        case .requiresQuit:
            guard let processName = Self.processName(for: item),
                  !PGrepProcessInspector().isRunning(processName) else {
                return .failed(.processRunning(Self.processName(for: item) ?? item.name))
            }
        }
        state.cleanedItemIDs = []
        state.deletingItemID = item.id
        let logStore = self.logStore
        let scanHome = paths.homeDirectory
        let pnpmRunner = self.pnpmRunner
        let knownStorePaths = knownPnpmStorePaths
        let pnpmHistoryOverflowed = self.pnpmHistoryOverflowed
        let deleter = TrashBatchDeleter(batchName: Self.cleanupBatchName())
        let work = Task.detached(priority: .userInitiated) { () -> ManualCleanExecution in
            let targetPaths = item.paths.isEmpty ? [item.path] : item.paths
            let needsOwnerProbe = item.category == .packageManager || targetPaths.contains { path in
                OwnerManagedPathGuard.isRecognizablePnpmLocation(
                    path, homeDirectory: scanHome
                ) || knownStorePaths.contains {
                    OwnerManagedPathGuard.overlaps(path, storePath: $0)
                }
            }
            let ownerStore: Result<OwnerCommandTarget, OwnerCommandFailure> = needsOwnerProbe
                ? pnpmRunner.probe() : .failure(.unavailable)
            let batchID = UUID()
            var entries: [CleanLogEntry] = []
            var firstFailure: ManualCleanFailure?
            for target in targetPaths {
                guard OwnerManagedPathGuard.mayDelete(
                    path: target, recipeID: item.recipeID, probe: ownerStore,
                    homeDirectory: scanHome, knownStorePaths: knownStorePaths,
                    historyOverflowed: pnpmHistoryOverflowed
                ) else {
                    firstFailure = firstFailure ?? .unavailable
                    continue
                }
                if item.recipeID == PackageManagerRecipes.familyID,
                   !PackageManagerRecipes.isApprovedDefaultCachePath(target, homeDirectory: scanHome) {
                    firstFailure = firstFailure ?? .unavailable
                    continue
                }
                guard !PackageManagerRecipes.isLegacyPnpmPath(target, homeDirectory: scanHome) else {
                    firstFailure = firstFailure ?? .unavailable
                    continue
                }
                if item.recipeID == TemporaryBuildArtifacts.recipeID,
                   !TemporaryBuildArtifacts.isEligibleForCleanup(path: target) {
                    firstFailure = firstFailure ?? .recentlyModified
                    continue
                }
                do {
                    let deletion = try deleter.deleteReturningResult(
                        url: URL(fileURLWithPath: target),
                        disposition: .trash
                    )
                    let entry = CleanLogEntry(
                        id: UUID(),
                        timestamp: Date(),
                        itemIDs: [item.id],
                        itemNames: [item.name],
                        originalPaths: [target],
                        trashPaths: [deletion.resultingURL?.path ?? ""],
                        batchID: batchID,
                        freedBytes: deletion.freedBytes,
                        disposition: .trash,
                        source: .manual
                    )
                    do {
                        try logStore.append(entry)
                        entries.append(entry)
                    } catch {
                        firstFailure = firstFailure ?? manualCleanFailure(for: error)
                        if let moved = deletion.resultingURL,
                           FileManager.default.fileExists(atPath: moved.path),
                           !FileManager.default.fileExists(atPath: target) {
                            try? FileManager.default.moveItem(at: moved, to: URL(fileURLWithPath: target))
                        }
                    }
                } catch {
                    firstFailure = firstFailure ?? manualCleanFailure(for: error)
                }
            }
            return ManualCleanExecution(entries: entries, firstFailure: firstFailure)
        }
        let execution = await work.value
        guard !execution.entries.isEmpty else {
            state.deletingItemID = nil
            state.deletingProgress = 1
            return .failed(execution.firstFailure ?? .unavailable)
        }
        let outcome = CleanOutcome(
            entries: execution.entries,
            freedBytes: execution.entries.reduce(0) { $0 + $1.freedBytes },
            actualFreedBytes: 0,
            stillBelowWaterline: false
        )
        // Moving to Trash does not free blocks on the volume. Update the tank
        // immediately by transferring the layer from its source to Trash, then
        // reconcile with a fresh scan. This keeps the UI responsive and honest.
        scanRevision &+= 1
        var cleaned = state.cleanedItemIDs
        cleaned.insert(item.id)
        state.cleanedItemIDs = cleaned
        growTrashItem(by: outcome.freedBytes)
        state.deletingItemID = nil
        notifyTrashChanged()
        refreshCleanLogEntries()
        state.lastCleanSummary = Localized.string(
            "clean.summary_trash_pending",
            outcome.entries.count,
            Format.bytes(outcome.freedBytes)
        )
        refreshGaugeImage()
        await refreshVolumeCapacity()
        await scanNow(autoClean: false, clearCleanSummary: false)
        state.cleanCelebrationID += 1
        return .cleaned(outcome)
    }

    /// 清空本应用自己创建的回收站批次（只删 PoolProblem Cleanup 目录）。
    func emptyOwnTrashBatches() async {
        await cleanupCoordinator.run { [weak self] in
            await self?.emptyOwnTrashBatchesSerialized()
        }
    }

    private func emptyOwnTrashBatchesSerialized() async {
        _ = try? TrashBatchDeleter.emptyOwnBatches()
        scanRevision &+= 1
        notifyTrashChanged()
        _ = await reconcileDashboardState()
        await scanNow(autoClean: false, clearCleanSummary: false)
    }

    /// 清空单个本应用批次。
    func emptyOwnBatch(named name: String) async {
        await cleanupCoordinator.run { [weak self] in
            await self?.emptyOwnBatchSerialized(named: name)
        }
    }

    private func emptyOwnBatchSerialized(named name: String) async {
        try? TrashBatchDeleter.emptyBatch(named: name)
        scanRevision &+= 1
        notifyTrashChanged()
        _ = await reconcileDashboardState()
        await scanNow(autoClean: false, clearCleanSummary: false)
    }

    /// 恢复单个本应用批次（依据清理记录），返回恢复的条目数。
    @discardableResult
    func restoreOwnBatch(named name: String) async -> Int {
        await cleanupCoordinator.run { [weak self] in
            await self?.restoreOwnBatchSerialized(named: name) ?? 0
        }
    }

    private func restoreOwnBatchSerialized(named name: String) async -> Int {
        let batchPath = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".Trash", isDirectory: true)
            .appendingPathComponent(name, isDirectory: true)
            .path
        let entries = (try? logStore.entries()) ?? []
        var restoredCount = 0
        for entry in entries where entry.disposition == .trash {
            let inBatch = entry.trashPaths.contains { $0.hasPrefix(batchPath) }
            guard inBatch else { continue }
            if await undoCleanup(entry) {
                restoredCount += 1
            }
        }
        return restoredCount
    }

    /// 废纸篓当前一级条目（名称 + 大小），本应用批次优先。
    /// 需要完全磁盘访问才能枚举；无权限时返回空列表。
    func trashEntries() async -> [TrashEntry] {
        let trash = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".Trash", isDirectory: true)
        guard let children = try? FileManager.default.contentsOfDirectory(
            at: trash,
            includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey]
        ) else { return [] }
        let work = Task.detached(priority: .utility) { () -> [TrashEntry] in
            var entries: [TrashEntry] = []
            for child in children {
                let isDir = ((try? child.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory) ?? false
                let bytes: Int64
                if isDir {
                    bytes = POSIXDirectoryWalker.walk(
                        url: child,
                        itemID: "trash-entry",
                        includeRecords: false
                    )?.allocatedBytes ?? 0
                } else {
                    bytes = Int64((try? child.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
                }
                entries.append(TrashEntry(
                    name: child.lastPathComponent,
                    bytes: bytes,
                    isOwnBatch: child.lastPathComponent.hasPrefix(TrashBatchDeleter.batchNamePrefix)
                ))
            }
            return entries.sorted { lhs, rhs in
                if lhs.isOwnBatch != rhs.isOwnBatch { return lhs.isOwnBatch }
                return lhs.bytes > rhs.bytes
            }
        }
        return await work.value
    }

    /// 一级子目录的当前占用与一次实际增长观测；小于 10 MB 的目录不在详情中列出。
    func cacheChildren(for item: ScanItem) async -> [ChildDirectoryInfo] {
        guard let recipe = activeRecipes().first(where: { $0.id == item.recipeID }),
              recipe.cleanByChildOnly,
              recipe.resolvePaths(paths).contains(item.path) else { return [] }
        let protected = ProgressiveCleanupPolicy.mergedProtectedChildNames(
            recipe: recipe, config: loadConfig()
        )
        let growth = (try? growthLedgerStore.entries()) ?? []
        let knownPaths = knownPnpmStorePaths
        let scanProbe: Result<OwnerCommandTarget, OwnerCommandFailure> = currentPnpmStoreTarget
            .map(Result.success) ?? .failure(lastPnpmProbeFailure ?? .unavailable)
        let homeDirectory = paths.homeDirectory
        let children = await Task.detached(priority: .utility) {
            ChildDirectoryExplorer().list(
                parentPath: item.path,
                growthEntries: growth,
                protectedChildNames: protected
            )
        }.value
        return children.filter {
            OwnerManagedPathGuard.mayDelete(
                path: $0.path, recipeID: item.recipeID, probe: scanProbe,
                homeDirectory: homeDirectory, knownStorePaths: knownPaths,
                historyOverflowed: pnpmHistoryOverflowed
            )
        }
    }

    /// 逐子目录清理：执行前用当前配方与文件树重新校验，不信任详情页中的旧路径。
    func cleanCacheChild(_ child: ChildDirectoryInfo, in item: ScanItem) async -> Bool {
        await cleanupCoordinator.run { [weak self] in
            guard let self,
                  let recipe = self.activeRecipes().first(where: { $0.id == item.recipeID }),
                  recipe.cleanByChildOnly,
                  recipe.cleanability.allowsManualCleanup,
                  item.cleanability.allowsManualCleanup else { return false }
            let protected = ProgressiveCleanupPolicy.mergedProtectedChildNames(
                recipe: recipe, config: self.loadConfig()
            )
            guard ChildDirectoryAccess.canClean(
                childPath: child.path,
                parentPath: item.path,
                authorizedParents: Set(recipe.resolvePaths(self.paths)),
                protectedNames: protected,
                expectedIdentity: child.identity,
                minimumIdleSeconds: recipe.id == "deriveddata"
                    ? DerivedDataChildPolicy.minimumIdleSeconds : 0
            ) else { return false }
            let pnpmRunner = self.pnpmRunner
            let ownerStore = await Task.detached(priority: .userInitiated) {
                pnpmRunner.probe()
            }.value
            let knownPaths = self.knownPnpmStorePaths
            guard OwnerManagedPathGuard.mayDelete(
                path: child.path, recipeID: item.recipeID, probe: ownerStore,
                homeDirectory: self.paths.homeDirectory, knownStorePaths: knownPaths,
                historyOverflowed: self.pnpmHistoryOverflowed
            ) else { return false }
            let deleter = TrashBatchDeleter(batchName: Self.cleanupBatchName())
            guard let deletion = try? deleter.deleteReturningResult(
                url: URL(fileURLWithPath: child.path),
                disposition: .trash
            ) else { return false }
            let entry = CleanLogEntry(
                id: UUID(),
                timestamp: Date(),
                itemIDs: ["\(item.recipeID):\(child.path)"],
                itemNames: [child.name],
                originalPaths: [child.path],
                trashPaths: [deletion.resultingURL?.path ?? ""],
                batchID: UUID(),
                freedBytes: deletion.freedBytes,
                disposition: .trash,
                source: .manual
            )
            do {
                try self.logStore.append(entry)
            } catch {
                if let moved = deletion.resultingURL,
                   FileManager.default.fileExists(atPath: moved.path),
                   !FileManager.default.fileExists(atPath: child.path) {
                    try? FileManager.default.moveItem(at: moved, to: URL(fileURLWithPath: child.path))
                }
                return false
            }
            self.notifyTrashChanged()
            await self.scanNow(autoClean: false)
            return true
        }
    }

    /// 恢复仍留在废纸篓里的本应用批次（依据清理记录），返回成功恢复的条数。
    @discardableResult
    func restoreOwnTrashBatches() async -> Int {
        await cleanupCoordinator.run { [weak self] in
            await self?.restoreOwnTrashBatchesSerialized() ?? 0
        }
    }

    private func restoreOwnTrashBatchesSerialized() async -> Int {
        let entries = (try? logStore.entries()) ?? []
        var restoredCount = 0
        for entry in entries where entry.disposition == .trash && !entry.trashPaths.isEmpty {
            let stillPresent = entry.trashPaths.allSatisfy { FileManager.default.fileExists(atPath: $0) }
            guard stillPresent else { continue }
            if await undoCleanup(entry) {
                restoredCount += 1
            }
        }
        return restoredCount
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
            var restoredCount = 0
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
                    restoredCount += 1
                } catch {
                    continue
                }
            }
            if restored, restoredCount == originalPaths.count {
                try? logStore.remove(id: entry.id)
            }
            return restored
        }

        let restored = await work.value
        if restored {
            notifyTrashChanged()
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

    /// 通用清理批次名：智能清理 / 水线自动清理 / 详情页一键清理共用。
    /// 所有“移入废纸篓”都进批次文件夹，才能在废纸篓详情里被识别为本应用批次。
    nonisolated private static func cleanupBatchName() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return "PoolProblem Cleanup \(formatter.string(from: Date()))"
    }

    // MARK: - Proactive auto-clean

    private func upcomingAutoCleanPlans(result: ScanResult) -> [AutoCleanPlanItem] {
        let waterline = waterlineBytes()
        let policy = DiskPressurePolicy(targetBytes: waterline)
        switch policy.state(availableBytes: result.volume.availableBytes) {
        case .healthy:
            return []
        case .warning:
            let span = Double(policy.analysisMarginBytes)
            let distance = Double(max(0, result.volume.availableBytes - waterline))
            return [AutoCleanPlanItem(
                id: UUID(),
                title: Localized.string(
                    "countdown.plan_near",
                    Format.bytes(policy.recoveryMarginBytes)
                ),
                estimatedDate: nil,
                progress: 1 - min(1, distance / span)
            )]
        case .critical:
            return [AutoCleanPlanItem(
                id: UUID(),
                title: Localized.string("countdown.plan_below"),
                estimatedDate: Date(),
                progress: 1
            )]
        }
    }

    private func maybeAutoClean(result: ScanResult) async {
        guard !cleanupCoordinator.isCleaning else { return }
        await cleanupCoordinator.run { [weak self] in
            await self?.performAutoClean(result: result)
        }
    }

    private func performAutoClean(result: ScanResult) async {
        guard let config = loadAutomationConfig() else {
            state.lastCleanSummary = "Automatic cleanup paused: configuration could not be read."
            return
        }
        let target = Int64(config.waterlineGB * 1_000_000_000)
        let pressure = DiskPressurePolicy(targetBytes: target)
        // Warning mode is analysis-only. Unattended deletion exists solely as
        // an emergency response below the configured waterline.
        guard pressure.state(availableBytes: result.volume.availableBytes) == .critical else {
            return
        }
        let minItemBytes = minimumCleanItemBytes(config)
        let outcome = await runAutoWaterlineClean(
            scan: result,
            config: config,
            waterlineBytes: pressure.recoveryTargetBytes,
            forceClean: false,
            // Urgency never overrides age or recent-use protection.
            ignoreAge: false,
            minimumItemBytes: minItemBytes,
            itemGrowthRates: state.growthRates
        )
        let totalCount = outcome?.entries.count ?? 0
        var totalFreed = outcome?.actualFreedBytes ?? 0
        if totalCount > 0 {
            let volume = await Task.detached(priority: .utility) {
                VolumeReader.read(fileURL: URL(fileURLWithPath: NSHomeDirectory()))
            }.value
            state.availableBytes = volume.availableBytes
            state.totalBytes = volume.totalBytes
            totalFreed = max(0, volume.availableBytes - result.volume.availableBytes)
        }

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
        refreshGaugeImage()
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
        let groupsByRecipe = recipeGroups(recipes)
        let defaultAgesByRecipe = recipeDefaultAges(recipes)
        let homeDirectory = paths.homeDirectory
        let knownPnpmStorePaths = self.knownPnpmStorePaths
        let pnpmHistoryOverflowed = self.pnpmHistoryOverflowed
        let work = Task.detached(priority: .utility) { () -> CleanOutcome? in
            let cleaner = Cleaner(
                evaluator: RuleEvaluator(
                    config: config,
                    activeProjectRootsByRecipe: activeRootsByRecipe,
                    idleHoursByRecipe: idleHours,
                    groupByRecipe: groupsByRecipe,
                    defaultAgeByRecipe: defaultAgesByRecipe
                ),
                deleter: TrashBatchDeleter(batchName: Self.cleanupBatchName()),
                inspector: PGrepProcessInspector(),
                logStore: logStore,
                homeDirectory: homeDirectory,
                knownOwnerStorePaths: knownPnpmStorePaths,
                ownerHistoryOverflowed: pnpmHistoryOverflowed
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
                            if disposition == .trash {
                                self.growTrashItem(by: item.reclaimableBytes)
                            } else {
                                state.availableBytes = min(
                                    state.totalBytes,
                                    state.availableBytes + item.reclaimableBytes
                                )
                            }
                        }
                    }
                }
            )
        }
        guard let outcome = await work.value else {
            state.deletingItemID = nil
            return nil
        }
        state.deletingItemID = nil
        return outcome
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
                    && item.allowsAutomaticPermanentDeletion
                    && item.cleanability == .regenerable
                    && item.disposition == .deletePermanently
                    && !config.whitelistPaths.contains(item.path)
                    && !config.keptItemIDs.contains(item.id)
            }
            .sorted { left, right in
                let leftRate = state.growthRates[left.id]
                let rightRate = state.growthRates[right.id]
                if let leftRate, let rightRate, leftRate != rightRate {
                    return leftRate > rightRate
                }
                if leftRate != nil, rightRate == nil { return true }
                if leftRate == nil, rightRate != nil { return false }
                return left.reclaimableBytes > right.reclaimableBytes
            }
            .first
    }

    /// 预计手动清理第一个处理的项目：按可清理量从小到大，
    /// 与 Cleaner 的新顺序一致（排除废纸篓、保留项、白名单及"需退出/需确认"项）
    private func firstPlannedItem() -> ScanItem? {
        let config = loadConfig()
        return state.items
            .filter {
                $0.reclaimableBytes > 0
                    && $0.cleanability != .watchOnly
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
        let updated = item.replacing(
            sizeBytes: item.sizeBytes + bytes,
            allocatedBytes: item.allocatedBytes + bytes,
            reclaimableBytes: item.reclaimableBytes + bytes,
            fileCount: item.fileCount + 1
        )
        var items = state.items
        items[index] = updated
        state.items = items
    }

    func loadConfig() -> Config {
        (try? JSONStore().load(Config.self, from: paths.configURL)) ?? .default
    }

    /// Missing config means first launch and safely uses defaults. A present
    /// but unreadable/corrupt config pauses automation instead of erasing the
    /// user's whitelist and disabled rules through a fail-open fallback.
    private func loadAutomationConfig() -> Config? {
        if !FileManager.default.fileExists(atPath: paths.configURL.path) {
            return .default
        }
        return try? JSONStore().load(Config.self, from: paths.configURL)
    }

    func saveConfig(_ config: Config) {
        // 设置页整体保存时只更新它管理的字段，避免覆盖 keptItemIDs/cloneRatios（由其它入口维护）
        var existing = loadConfig()
        existing.waterlineGB = config.waterlineGB
        existing.rules = config.rules
        existing.whitelistPaths = config.whitelistPaths
        existing.protectedCacheChildren = config.protectedCacheChildren
        existing.minimumCleanItemMB = config.minimumCleanItemMB
        existing.autoEmptyOwnTrashBatches = config.autoEmptyOwnTrashBatches
        writeConfig(existing)
        // 水位线配置立即生效并重绘标尺（不再等下次扫描）
        state.waterlineBytes = waterlineBytes()
        refreshGaugeImage()
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

    /// Full analyses record growth only for the explicit recipe catalog. Broad
    /// surface scans and automatic recipe discovery are intentionally excluded.
    private func updateGrowthInsights(previous: Snapshot?, latest: Snapshot) async {
        let home = NSHomeDirectory()
        let builder = GrowthLedgerBuilder()
        let entries = builder.entries(previous: previous, latest: latest, homeDirectory: home)
        try? growthLedgerStore.append(entries)
        try? growthLedgerStore.prune(retainingDays: 30)
        let allEntries = (try? growthLedgerStore.entries()) ?? []
        state.growthReport = growthReport(from: allEntries)
    }

    /// Deliberate secondary action: compare the existing surface-scan roots
    /// without changing recipes, cleanup permissions, or the automatic loop.
    func discoverGrowthSources() async {
        guard !state.isGrowthDiscovering else { return }
        state.isGrowthDiscovering = true
        state.growthDiscoveryMessage = nil
        defer { state.isGrowthDiscovering = false }

        let store = growthLedgerStore
        let home = paths.homeDirectory
        let result = await Task.detached(priority: .utility) {
            try? SurfaceGrowthDiscovery(
                store: store,
                roots: SurfaceScanner.defaultRoots(homeDirectory: home),
                homeDirectory: home
            ).run()
        }.value
        guard let result else {
            state.growthDiscoveryMessage = Localized.string("insights.discovery_failed")
            return
        }
        state.growthReport = growthReport(from: (try? growthLedgerStore.entries()) ?? [])
        if result.establishedBaseline {
            state.growthDiscoveryMessage = Localized.string("insights.discovery_baseline")
        } else if result.entries.isEmpty {
            state.growthDiscoveryMessage = Localized.string("insights.discovery_no_growth")
        } else {
            state.growthDiscoveryMessage = Localized.string("insights.discovery_complete")
        }
    }

    /// 启动时从磁盘恢复增长洞察与候选配方状态。
    private func refreshGrowthState() {
        recheckGrowthInsights()
    }

    /// Re-read historical evidence and stat visible paths without a recursive
    /// scan. Opening Growth Insights may call this; disk use remains unverified.
    func recheckGrowthInsights() {
        let allEntries = (try? growthLedgerStore.entries()) ?? []
        state.growthReport = growthReport(from: allEntries)
        state.candidateRecipes = dedupeCandidatesAgainstDevRoots(
            (try? recipeSuggestionStore.load()) ?? []
        )
    }

    /// 统一刷新“配方建议”：增长台账 + 主动发现 + 近期写活动三个来源，
    /// 归并成“加入现有配方作用域”的候选。开发目录建议就是其中的
    /// “项目目录”配方族——发现/活跃/增长只是同一类建议的不同来源。
    /// 主动发现默认每 1 小时最多执行一次，避免频繁全量测量；force 时立即执行。
    private func refreshRecipeSuggestions(forceDiscovery: Bool = false) async {
        let home = NSHomeDirectory()
        var raw: [CandidateRecipe] = []
        if forceDiscovery || Date().timeIntervalSince(lastDevDiscoveryAt) >= 3600 {
            lastDevDiscoveryAt = Date()
            let found = await Task.detached(priority: .utility) {
                DevDirectoryDiscovery.discover(homeDirectory: home)
            }.value
            raw += RecipeSuggester.discoveryCandidates(
                discovered: found,
                homeDirectory: home
            )
            #if DEBUG
            let line = "[\(Date())] discovery: found=\(found.count) "
                + "first=\(found.prefix(3).map(\.path).joined(separator: "|"))\n"
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
        // A surface measurement is evidence for the read-only report, not
        // evidence that an unfamiliar path is safe to add to a cleanup recipe.
        let allEntries = ((try? growthLedgerStore.entries()) ?? [])
            .filter { $0.kind != .surface }
        raw += RecipeSuggester().suggest(
            entries: allEntries,
            existingRecipes: activeRecipes(),
            homeDirectory: home
        )
        let normalized = RecipeSuggester.normalize(raw, homeDirectory: home)
        let live = dedupeCandidatesAgainstDevRoots(normalized)
        try? recipeSuggestionStore.merge(live)
        // 丢弃旧设计残留 / 已不再生成的候选（如历史版本对 Xcode、CoreSimulator 的错误建议）
        try? recipeSuggestionStore.prune(keeping: Set(live.map(\.id)))
        state.candidateRecipes = dedupeCandidatesAgainstDevRoots(
            (try? recipeSuggestionStore.load()) ?? []
        )
    }

    /// 供 UI 手动/打开洞察时刷新配方建议。
    func refreshSuggestions(forceDiscovery: Bool = true) async {
        await refreshRecipeSuggestions(forceDiscovery: forceDiscovery)
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

    /// 只筛选界面列表；完整扫描结果继续用于容量归因与清理决策。
    func visibleItems(_ items: [ScanItem]) -> [ScanItem] {
        ScanDisplayPolicy.visibleItems(items, recipes: activeRecipes())
    }

    /// 旧快照可能还没有逐子目录标志；始终以当前配方为删除权限来源。
    func isChildOnly(_ item: ScanItem) -> Bool {
        item.cleanByChildOnly
            || activeRecipes().first(where: { $0.id == item.recipeID })?.cleanByChildOnly == true
    }

    func canCleanWholeItem(_ item: ScanItem) -> Bool {
        guard let recipe = activeRecipes().first(where: { $0.id == item.recipeID }) else {
            return false
        }
        let itemPaths = item.paths.isEmpty ? [item.path] : item.paths
        let scanProbe: Result<OwnerCommandTarget, OwnerCommandFailure> = currentPnpmStoreTarget
            .map(Result.success) ?? .failure(lastPnpmProbeFailure ?? .unavailable)
        let knownPaths = knownPnpmStorePaths
        if itemPaths.contains(where: {
            !OwnerManagedPathGuard.mayDelete(
                path: $0, recipeID: item.recipeID, probe: scanProbe,
                homeDirectory: paths.homeDirectory, knownStorePaths: knownPaths,
                historyOverflowed: pnpmHistoryOverflowed
            )
        }) {
            return false
        }
        return item.cleanability.allowsManualCleanup
            && recipe.cleanability.allowsManualCleanup
            && !item.cleanByChildOnly
            && !recipe.cleanByChildOnly
    }

    func probePnpmStore() async -> Result<OwnerCommandTarget, OwnerCommandFailure> {
        let pnpmRunner = self.pnpmRunner
        return await Task.detached(priority: .userInitiated) {
            pnpmRunner.probe()
        }.value
    }

    func prunePnpmStore(
        confirmed target: OwnerCommandTarget,
        onJournalResult: @escaping @MainActor (OwnerCommandJournalResult) -> Void
    ) async -> OwnerCommandJournalResult {
        await cleanupCoordinator.run { [self] in
            let recordStore = self.ownerCommandRecordStore
            let pnpmRunner = self.pnpmRunner
            let result = await Task.detached(priority: .userInitiated) {
                OwnerCommandJournal(store: recordStore).execute(
                    recipeID: OwnerCommandRecipe.pnpmStorePrune.id, targetPath: target.path
                ) {
                    pnpmRunner.perform(confirmed: target)
                }
            }.value
            let execution: Result<OwnerCommandOutcome, OwnerCommandFailure>
            switch result {
            case .startNotSaved:
                onJournalResult(result)
                return result
            case .completed(let commandResult, let record):
                self.state.lastOwnerCommandRecord = record
                execution = commandResult
            case .completionNotSaved(let commandResult, let attempt):
                self.state.lastOwnerCommandRecord = attempt
                execution = commandResult
            }
            // Report persistence failure before capacity refresh or a potentially long scan.
            onJournalResult(result)
            if case .success = execution {
                self.scanRevision &+= 1
                await self.refreshVolumeCapacity()
                await self.scanNow(autoClean: false, clearCleanSummary: false)
                self.refreshCleanLogEntries()
            } else {
                await self.refreshVolumeCapacity()
            }
            return result
        }
    }

    /// 当前生效的配方：系统内置 + 用户确认的项目目录配方。
    func activeRecipes() -> [Recipe] {
        recipes(pnpmTarget: currentPnpmStoreTarget)
    }

    private func recipes(pnpmTarget: OwnerCommandTarget?) -> [Recipe] {
        let config = loadConfig()
        return RecipeRegistry.builtIn()
            + (pnpmTarget.map { [OwnerCommandRecipe.pnpmStorePrune.scanRecipe(target: $0)] } ?? [])
            + [PackageManagerRecipes.make(
                extraRoots: [],
                homeDirectory: paths.homeDirectory
            )]
            + (config.packageManagerCacheRoots.isEmpty
                ? []
                : [PackageManagerRecipes.makeCustom(extraRoots: config.packageManagerCacheRoots)])
            + ProjectRecipes.make(devRoots: config.devRoots, homeDirectory: paths.homeDirectory)
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

    /// 配方 → 所属组（组级开关/闲置天数/进程守卫）。
    private func recipeGroups(_ recipes: [Recipe]) -> [String: RecipeGroup] {
        Dictionary(uniqueKeysWithValues: recipes.map { ($0.id, $0.group) })
    }

    /// 配方 → 声明的默认闲置天数（组级/配方级规则未配置时回落）。
    private func recipeDefaultAges(_ recipes: [Recipe]) -> [String: Int] {
        Dictionary(uniqueKeysWithValues: recipes.map { ($0.id, $0.defaultAgeDays) })
    }

    /// Project artifacts are manual-only. Activity remains a veto concept, but
    /// the app no longer runs continuous filesystem surveillance to infer it.
    private func projectActiveRootsByRecipe(recipes: [Recipe]) -> [String: Set<String>] {
        [:]
    }

    /// 各配方最短闲置小时数（mtime 判定），供 RuleEvaluator 使用。
    private func idleHoursByRecipe(recipes: [Recipe]) -> [String: Double] {
        Dictionary(uniqueKeysWithValues: recipes.map { ($0.id, $0.minimumIdleHours) })
    }

    /// 从监控中移除用户添加的开发目录。
    func removeDevRoot(_ path: String) {
        var config = loadConfig()
        config.devRoots.removeAll { $0 == path }
        writeConfig(config)
    }

    /// 从监控中移除用户添加的包管理器缓存目录。
    func removePackageManagerCacheRoot(_ path: String) {
        var config = loadConfig()
        config.packageManagerCacheRoots.removeAll { $0 == path }
        writeConfig(config)
    }

    /// Keep the latest historical event per path and check whether its path
    /// still exists. No current size is implied by this cheap stat pass.
    private func growthReport(from allEntries: [GrowthEntry]) -> GrowthInsightReport {
        let known = uncoveredInsights(allEntries.filter { $0.kind != .surface })
        let latestSurface = uncoveredInsights(
            (try? growthLedgerStore.surfaceSnapshot())?.latestEntries ?? []
        )
        return GrowthInsightReconciler().reconcile(entries: known + latestSurface)
    }

    /// 已列入任一配方作用域（devRoots / 包管理器缓存）或忽略列表的目录
    /// 不再作为“加入现有配方”候选展示。
    private func dedupeCandidatesAgainstDevRoots(_ candidates: [CandidateRecipe]) -> [CandidateRecipe] {
        let config = loadConfig()
        let known = config.devRoots + config.declinedDevRoots + config.packageManagerCacheRoots
        return candidates.filter { candidate in
            guard GrowthCandidateAdmission.canDisplay(candidate) else { return false }
            // 候选位于某个已确认/忽略的根之内（或其自身）→ 不再建议；
            // 已知根只是候选的子目录时仍保留候选（父目录建议可覆盖其余部分）。
            return !known.contains { $0 == candidate.samplePath || candidate.samplePath.hasPrefix($0 + "/") }
        }
    }

    func acceptCandidate(id: String) {
        guard let candidate = state.candidateRecipes.first(where: { $0.id == id }),
              GrowthCandidateAdmission.canAccept(candidate) else { return }
        var config = loadConfig()
        // Project roots expose only nested node_modules/build products to the
        // existing manual Trash recipes. This action never deletes files.
        if !config.devRoots.contains(candidate.samplePath) {
            config.devRoots.append(candidate.samplePath)
        }
        config.declinedDevRoots.removeAll { $0 == candidate.samplePath }
        writeConfig(config)
        setCandidateStatus(id: id, status: .accepted)
        // 立即重扫，让项目配方（聚合条目）出现在清理列表中
        Task { await scanNow(autoClean: false) }
    }

    func dismissCandidate(id: String) {
        // 项目配方族额外记入忽略列表（兼容旧流程）；包管理器配方族由
        // store 状态抑制重复建议
        if let candidate = state.candidateRecipes.first(where: { $0.id == id }) {
            if candidate.recipeID == RecipeSuggester.projectFamilyID {
                var config = loadConfig()
                if !config.declinedDevRoots.contains(candidate.samplePath) {
                    config.declinedDevRoots.append(candidate.samplePath)
                    writeConfig(config)
                }
            }
        }
        setCandidateStatus(id: id, status: .dismissed)
    }

    private func setCandidateStatus(id: String, status: CandidateStatus) {
        try? recipeSuggestionStore.setStatus(id: id, status: status)
        state.candidateRecipes = dedupeCandidatesAgainstDevRoots(
            (try? recipeSuggestionStore.load()) ?? []
        )
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

    private func notifyTrashChanged() {
        NSWorkspace.shared.noteFileSystemChanged(
            URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent(".Trash", isDirectory: true)
                .path
        )
    }

    nonisolated private static func readDashboardConsistency(
        homeDirectory: String,
        currentItems: [ScanItem],
        lastScanAt: Date?,
        previousFingerprints: [String: TrashDirectoryFingerprint]
    ) -> DashboardConsistencyReading {
        let volume = VolumeReader.read(fileURL: URL(fileURLWithPath: homeDirectory))
        let standardPaths = [
            homeDirectory + "/.Trash",
            homeDirectory + "/Library/Mobile Documents/.Trash",
        ]
        let cachedByPath = Dictionary(
            uniqueKeysWithValues: currentItems
                .filter { $0.recipeID == "trash" }
                .map { ($0.path, $0) }
        )
        let paths = Set(standardPaths + Array(cachedByPath.keys)).sorted()
        var replacements: [String: ScanItem] = [:]
        var fingerprints: [String: TrashDirectoryFingerprint] = [:]
        var allReadable = true

        for path in paths {
            let exists = POSIXDirectoryWalker.itemExists(path: path)
            guard exists else {
                let fingerprint = TrashDirectoryFingerprint(
                    exists: false,
                    childCount: 0,
                    modificationDate: nil
                )
                fingerprints[path] = fingerprint
                if let cached = cachedByPath[path] {
                    replacements[path] = cached.replacing(
                        sizeBytes: 0,
                        allocatedBytes: 0,
                        reclaimableBytes: 0,
                        fileCount: 0,
                        lastModified: .some(nil)
                    )
                }
                continue
            }

            let childCount = POSIXDirectoryWalker.firstLevelCount(path: path)
            let rootModified = POSIXDirectoryWalker.modificationDate(path: path)
            let fingerprint = TrashDirectoryFingerprint(
                exists: true,
                childCount: childCount,
                modificationDate: rootModified
            )
            fingerprints[path] = fingerprint
            guard let childCount else {
                allReadable = false
                continue
            }

            let cached = cachedByPath[path]
            if childCount == 0 {
                replacements[path] = makeTrashItem(
                    path: path,
                    cached: cached,
                    sizeBytes: 0,
                    allocatedBytes: 0,
                    fileCount: 0,
                    lastModified: rootModified
                )
                continue
            }

            let changedSinceSnapshot = rootModified.map { modified in
                lastScanAt.map { modified > $0 } ?? true
            } ?? (lastScanAt == nil)
            let fingerprintChanged = previousFingerprints[path].map {
                $0.exists != fingerprint.exists
                    || $0.childCount != fingerprint.childCount
                    || $0.modificationDate != fingerprint.modificationDate
            } ?? false
            let cachedWasEmpty = cached.map { $0.fileCount == 0 || $0.allocatedBytes == 0 } ?? true
            guard changedSinceSnapshot || fingerprintChanged || cachedWasEmpty else {
                continue
            }
            guard let walk = POSIXDirectoryWalker.walk(
                url: URL(fileURLWithPath: path, isDirectory: true),
                itemID: "trash:\(path)",
                includeRecords: false
            ) else {
                allReadable = false
                continue
            }
            replacements[path] = makeTrashItem(
                path: path,
                cached: cached,
                sizeBytes: walk.sizeBytes,
                allocatedBytes: walk.allocatedBytes,
                fileCount: walk.fileCount,
                lastModified: newest(walk.newest, rootModified)
            )
        }

        return DashboardConsistencyReading(
            volume: volume,
            trashReplacements: replacements,
            trashFingerprints: fingerprints,
            allTrashPathsReadable: allReadable
        )
    }

    nonisolated private static func makeTrashItem(
        path: String,
        cached: ScanItem?,
        sizeBytes: Int64,
        allocatedBytes: Int64,
        fileCount: Int,
        lastModified: Date?
    ) -> ScanItem {
        if let cached {
            return cached.replacing(
                sizeBytes: sizeBytes,
                allocatedBytes: allocatedBytes,
                reclaimableBytes: allocatedBytes,
                fileCount: fileCount,
                lastModified: .some(lastModified)
            )
        }
        return ScanItem(
            id: "trash:\(path)",
            recipeID: "trash",
            name: "废纸篓",
            path: path,
            category: .common,
            safety: .userConfirm,
            disposition: .none,
            sizeBytes: sizeBytes,
            allocatedBytes: allocatedBytes,
            reclaimableBytes: allocatedBytes,
            fileCount: fileCount,
            lastModified: lastModified,
            cleanability: .displayOnly
        )
    }

    nonisolated private static func newest(_ first: Date?, _ second: Date?) -> Date? {
        switch (first, second) {
        case let (a?, b?): max(a, b)
        case let (a?, nil): a
        case let (nil, b?): b
        case (nil, nil): nil
        }
    }

    nonisolated private static func recipeStoragePaths(homeDirectory: String) -> StoragePaths {
        StoragePaths(
            baseURL: URL(fileURLWithPath: homeDirectory, isDirectory: true)
                .appendingPathComponent("Library/Application Support/PoolProblem", isDirectory: true),
            homeDirectory: homeDirectory
        )
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
