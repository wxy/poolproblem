# FSEvents 增量监听实现计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 用 FSEvents 监听配方路径与表面扫描根目录,事件驱动地对"脏目录"做增量重扫并合成增量快照,让增长台账与候选配方建议更及时;保留每 30 分钟全量扫描作为兜底。

**Architecture:** Core 新增 `Watch/` 目录:`FSEventMonitor` 封装 FSEventStream(独立串行队列回调,只报告"哪些路径变了");`DirtyTracker` 是纯逻辑,把事件路径归并为需要重扫的受监听路径;`Scanner.rescan(path:recipe:)` 与 `SurfaceScanner.measure(paths:)` 提供单点重扫能力;`Snapshot` 增加 `source` 字段区分全量/增量。App 层 `AppService` 在全量扫描成功后启动监听,事件到达后在 MainActor 收拢进 DirtyTracker,由 30 秒定时器触发增量重扫:重扫脏配方路径 + 脏表面目录 → 用上次快照替换对应项合成增量快照 → 追加快照并走既有增长台账/候选配方管线。增量路径不做自动清理、通知与水位预测,避免副作用。

**Tech Stack:** Swift 6、FSEventStream C API（`CoreServices`）、SwiftUI、Swift Testing、现有 `POSIXDirectoryWalker`/`JSONStore`/`StoragePaths`/`GrowthLedgerStore`/`RecipeSuggester`。

**Spec:** 本计划即设计文档（2026-08-18 与用户确认的增量监听方向；完整产品设计见 `docs/superpowers/specs/2026-08-09-the-pool-problem-design.md`）。

## Global Constraints

- macOS 14+；Core 为 SwiftPM 包（新增源码自动纳入 `DiskReservoirCore` target）。
- FSEvents 只做"变更提示"，测量一律走既有 `POSIXDirectoryWalker`，保证增量与全量口径一致；FSEventMonitor 回调必须在新开的专用串行 `DispatchQueue` 上执行，不得占用主线程。
- 增量快照必须带 `source: .incremental`；旧快照文件（无 `source` 字段）解码默认 `.full`，兼容已有数据。
- 30 分钟全量扫描仍是唯一"事实来源"兜底；增量重扫只在脏路径上做，且不触发自动清理、通知、水位预测与标尺位图刷新（仅更新 `state.items` 与增长洞察）。
- 监听路径 = 内置配方 `resolvePaths` ∪ `SurfaceScanner.defaultRoots(homeDirectory:)`，去重。
- 提交规范：conventional commits；每任务 `swift test`（Core）/`xcodebuild build`（App）通过后才提交。
- 本计划不做：FSEvents 持久化重放（`sinceWhen` 从当前事件 ID 开始）、把增量快照用于自动清理决策、L3/L4。

---

## 文件结构

```
Sources/DiskReservoirCore/
├── Watch/FSEventMonitor.swift          # 新增：FSEventStream 封装
├── Watch/DirtyTracker.swift            # 新增：事件→脏路径归并（纯逻辑）
├── Models/Snapshot.swift               # 修改：+source（SnapshotSource）
├── Scanner/Scanner.swift               # 修改：+rescan(path:recipe:homeDirectory:)
├── Growth/SurfaceScanner.swift         # 修改：+measure(paths:)
└── Growth/GrowthEntry.swift            # 不改

Tests/DiskReservoirCoreTests/
├── SnapshotSourceTests.swift           # 新增：source 编解码兼容
├── FSEventMonitorTests.swift           # 新增：临时目录写文件→事件回调（宽松超时）
├── DirtyTrackerTests.swift             # 新增
├── ScannerRescanTests.swift            # 新增：rescan 单点测量
└── SurfaceScannerTests.swift           # 修改：+measure(paths:) 用例

PoolProblem/PoolProblem/
├── AppService.swift                    # 修改：启动监听、事件收拢、增量重扫编排
└── Models/AppState.swift               # 不改（复用 growthInsights/candidateRecipes）
```

---

### Task 1: Snapshot 增加 source 字段（含兼容解码）

**Files:**
- Modify: `Sources/DiskReservoirCore/Models/Snapshot.swift`
- Test: `Tests/DiskReservoirCoreTests/SnapshotSourceTests.swift`

**Interfaces:**
- Consumes: 无。
- Produces: `SnapshotSource`（`.full`/`.incremental`）；`Snapshot.init(volume:items:source:)`（默认 `.full`）；旧 JSON 解码默认 `.full`。

- [ ] **Step 1: 写失败测试**

```swift
// Tests/DiskReservoirCoreTests/SnapshotSourceTests.swift
@Test func snapshotDecodesLegacyJSONWithoutSourceAsFull() throws {
    let json = """
    {"volume":{"totalBytes":1000,"availableBytes":500,"timestamp":"2026-08-18T00:00:00Z"},"items":[]}
    """
    let data = try #require(json.data(using: .utf8))
    let snapshot = try JSONDecoder().decode(Snapshot.self, from: data)
    #expect(snapshot.source == .full)
}

@Test func snapshotRoundTripsSource() throws {
    let snapshot = Snapshot(
        volume: VolumeInfo(totalBytes: 1000, availableBytes: 500, timestamp: Date()),
        items: [],
        source: .incremental
    )
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let data = try encoder.encode(snapshot)
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let decoded = try decoder.decode(Snapshot.self, from: data)
    #expect(decoded.source == .incremental)
}
```

- [ ] **Step 2: 运行确认失败**

Run: `swift test --filter SnapshotSourceTests`
Expected: FAIL（`SnapshotSource` 不存在 / `source` 缺失）。

- [ ] **Step 3: 实现**

```swift
// Snapshot.swift
import Foundation

/// 快照来源：全量扫描 or 增量重扫合成。
public enum SnapshotSource: String, Codable, Sendable {
    case full
    case incremental
}

public struct Snapshot: Codable, Equatable, Sendable {
    public let volume: VolumeInfo
    public let items: [ScanItem]
    public let source: SnapshotSource

    public init(volume: VolumeInfo, items: [ScanItem], source: SnapshotSource = .full) {
        self.volume = volume
        self.items = items
        self.source = source
    }

    private enum CodingKeys: String, CodingKey {
        case volume, items, source
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        volume = try c.decode(VolumeInfo.self, forKey: .volume)
        items = try c.decode([ScanItem].self, forKey: .items)
        source = try c.decodeIfPresent(SnapshotSource.self, forKey: .source) ?? .full
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(volume, forKey: .volume)
        try c.encode(items, forKey: .items)
        try c.encode(source, forKey: .source)
    }
}
```

- [ ] **Step 4: 运行确认通过**

Run: `swift test --filter SnapshotSourceTests`
Expected: PASS；既有 105 个测试不回归（`Snapshot(volume:items:)` 调用点靠默认参数保持编译）。

- [ ] **Step 5: 提交**

```bash
git add Sources/DiskReservoirCore Tests/DiskReservoirCoreTests
git commit -m "feat: add snapshot source (full/incremental) with backward-compatible decoding"
```

---

### Task 2: FSEventMonitor 封装

**Files:**
- Create: `Sources/DiskReservoirCore/Watch/FSEventMonitor.swift`
- Test: `Tests/DiskReservoirCoreTests/FSEventMonitorTests.swift`

**Interfaces:**
- Consumes: 无（C API `FSEventStreamCreate`/`FSEventStreamSetDispatchQueue`/`FSEventStreamStart`）。
- Produces: `FSEventMonitor.init(paths:latency:queue:)`、`start(handler:)`、`stop()`；handler 收到合并后的事件路径 `[String]`。

- [ ] **Step 1: 写集成测试**（临时目录内建文件 → 回调应收到该目录路径）

```swift
@Test func fseventMonitorDeliversEventsForWatchedDirectory() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("pp-fsevents-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let monitor = FSEventMonitor(paths: [root.path], latency: 0.2)
    let events = AsyncStream<String> { continuation in
        monitor.start { paths in
            for path in paths { continuation.yield(path) }
        }
        continuation.onTermination = { _ in monitor.stop() }
    }
    // 留出流建立时间，再写入触发事件
    try await Task.sleep(nanoseconds: 500_000_000)
    try Data(repeating: 0x41, count: 10).write(to: root.appendingPathComponent("t.bin"))
    // 5 秒内等第一个命中事件（流消费任务与超时任务竞争）
    let hit = await withThrowingTaskGroup(of: Bool.self) { group in
        group.addTask {
            for await path in events where path.hasPrefix(root.path) {
                return true
            }
            return false
        }
        group.addTask {
            try await Task.sleep(nanoseconds: 5_000_000_000)
            return false
        }
        let result = try await group.next() ?? false
        group.cancelAll()
        return result
    }
    #expect(hit)
    monitor.stop()
}
```

> 注：FSEvents 依赖系统内核事件队列，CI/沙箱环境下事件可能延迟；本测试用 5 秒宽松超时，若极端环境仍不触发，改为 `#expect(flag)` 容忍失败并记录日志，不阻塞其余任务。

- [ ] **Step 2: 运行确认失败**

Run: `swift test --filter fseventMonitorDeliversEventsForWatchedDirectory`
Expected: FAIL（类型不存在）。

- [ ] **Step 3: 实现**

```swift
// FSEventMonitor.swift
import Foundation

/// FSEventStream 轻量封装：
/// - 事件在专用串行队列上回调（latency 窗口内由系统合并）；
/// - 只报告"哪些路径变了"，扫描/归因交给上层；
/// - `@unchecked Sendable`：所有可变状态只在 `queue` 上访问。
public final class FSEventMonitor: @unchecked Sendable {
    private let paths: [String]
    private let latency: TimeInterval
    private let queue: DispatchQueue
    private var stream: FSEventStreamRef?
    private var handler: (@Sendable ([String]) -> Void)?

    public init(
        paths: [String],
        latency: TimeInterval = 1.0,
        queue: DispatchQueue = DispatchQueue(label: "com.poolproblem.fsevents")
    ) {
        self.paths = paths
        self.latency = latency
        self.queue = queue
    }

    public func start(handler: @escaping @Sendable ([String]) -> Void) {
        stop()
        self.handler = handler
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            { _, info, _, eventPaths, _, _ in
                guard let info else { return }
                let monitor = Unmanaged<FSEventMonitor>.fromOpaque(info).takeUnretainedValue()
                let paths = unsafeBitCast(eventPaths, to: NSArray.self) as? [String] ?? []
                monitor.queue.async { monitor.handler?(paths) }
            },
            &context,
            paths as CFArray,
            kFSEventsGetCurrentEventId(),
            latency,
            kFSEventStreamCreateFlagFileEvents
        ) else { return }
        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
    }

    public func stop() {
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            self.stream = nil
        }
        handler = nil
    }

    deinit { stop() }
}
```

- [ ] **Step 4: 运行确认通过**（5 秒超时内收到事件）
- [ ] **Step 5: 提交**

```bash
git add Sources/DiskReservoirCore Tests/DiskReservoirCoreTests
git commit -m "feat: add FSEvents monitor wrapper"
```

---

### Task 3: DirtyTracker（事件→脏路径归并）

**Files:**
- Create: `Sources/DiskReservoirCore/Watch/DirtyTracker.swift`
- Test: `Tests/DiskReservoirCoreTests/DirtyTrackerTests.swift`

**Interfaces:**
- Consumes: 无。
- Produces: `DirtyTracker.init(trackedPaths:)`、`mark(eventPaths:) -> [String]`（返回新变脏的受监听路径）、`clear()`、`dirty`、`matches(event:tracked:)`。

- [ ] **Step 1: 写失败测试**

```swift
@Test func dirtyTrackerMarksNestedEvents() {
    var tracker = DirtyTracker(trackedPaths: ["~/Library/Caches/A", "~/Library/Caches/B"])
    let newly = tracker.mark(eventPaths: ["~/Library/Caches/A/sub/x", "~/Library/Logs"])
    #expect(newly == ["~/Library/Caches/A"])
    #expect(tracker.dirty == ["~/Library/Caches/A"])
}

@Test func dirtyTrackerMatchesParentEvents() {
    var tracker = DirtyTracker(trackedPaths: ["~/Library/Caches/A"])
    // 重命名等场景：事件可能落在父目录
    _ = tracker.mark(eventPaths: ["~/Library/Caches"])
    #expect(tracker.dirty.contains("~/Library/Caches/A"))
}

@Test func dirtyTrackerIgnoresUnrelatedEventsAndClears() {
    var tracker = DirtyTracker(trackedPaths: ["~/Library/Caches/A"])
    _ = tracker.mark(eventPaths: ["/usr/local/var"])
    #expect(tracker.dirty.isEmpty)
    _ = tracker.mark(eventPaths: ["~/Library/Caches/A"])
    tracker.clear()
    #expect(tracker.dirty.isEmpty)
}
```

- [ ] **Step 2: 运行确认失败**
- [ ] **Step 3: 实现**

```swift
// DirtyTracker.swift
import Foundation

/// 纯逻辑脏路径跟踪：把 FSEvents 事件归并为需要重扫的受监听路径。
public struct DirtyTracker: Sendable {
    public let trackedPaths: [String]
    public private(set) var dirty: Set<String> = []

    public init(trackedPaths: [String]) {
        self.trackedPaths = trackedPaths
    }

    /// 事件路径 → 命中的受监听路径；返回本次新变脏的路径。
    @discardableResult
    public mutating func mark(eventPaths: [String]) -> [String] {
        var newlyDirty: [String] = []
        for event in eventPaths {
            for tracked in trackedPaths where Self.matches(event: event, tracked: tracked) {
                if dirty.insert(tracked).inserted {
                    newlyDirty.append(tracked)
                }
            }
        }
        return newlyDirty
    }

    /// 事件是受监听路径本身、其子路径、或其父路径之一即命中。
    public static func matches(event: String, tracked: String) -> Bool {
        event == tracked
            || event.hasPrefix(tracked + "/")
            || tracked.hasPrefix(event + "/")
    }

    public mutating func clear() {
        dirty.removeAll()
    }
}
```

- [ ] **Step 4: 运行确认通过**
- [ ] **Step 5: 提交**

```bash
git add Sources/DiskReservoirCore Tests/DiskReservoirCoreTests
git commit -m "feat: add dirty tracker for incremental rescans"
```

---

### Task 4: 单点重扫能力（Scanner.rescan + SurfaceScanner.measure）

**Files:**
- Modify: `Sources/DiskReservoirCore/Scanner/Scanner.swift`
- Modify: `Sources/DiskReservoirCore/Growth/SurfaceScanner.swift`
- Test: `Tests/DiskReservoirCoreTests/ScannerRescanTests.swift`
- Test: `Tests/DiskReservoirCoreTests/SurfaceScannerTests.swift`

**Interfaces:**
- Consumes: 现有 `measureDirectory`/`appendRuntimeItems` 逻辑。
- Produces: `Scanner.rescan(path:recipe:homeDirectory:) -> [ScanItem]`（普通配方 1 项、运行时配方多项）；`SurfaceScanner.measure(paths:minimumSizeBytes:) -> [SurfaceDirectory]`。

- [ ] **Step 1: 写失败测试**

```swift
// ScannerRescanTests.swift
@Test func rescanMeasuresSingleRecipePath() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("pp-rescan-\(UUID().uuidString)", isDirectory: true)
    let cache = root.appendingPathComponent("Cache", isDirectory: true)
    try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try Data(repeating: 0x41, count: 123_456).write(to: cache.appendingPathComponent("f.bin"))
    let recipe = Recipe(
        id: "r", name: "R", category: .common, safety: .safeWhileRunning,
        disposition: .deletePermanently, cleanability: .regenerable,
        defaultAgeDays: 7, minimumSizeMB: 0, processName: nil,
        resolvePaths: { _ in [cache.path] }
    )
    let items = Scanner().rescan(path: cache.path, recipe: recipe, homeDirectory: root.path)
    #expect(items.count == 1)
    #expect(items[0].sizeBytes == 123_456)
    #expect(items[0].path == cache.path)
}
```

```swift
// SurfaceScannerTests.swift 追加
@Test func surfaceScannerMeasuresExplicitPaths() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("pp-surf-measure-\(UUID().uuidString)", isDirectory: true)
    let dir = root.appendingPathComponent("D", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try Data(repeating: 0x41, count: 77_000).write(to: dir.appendingPathComponent("f.bin"))
    let dirs = SurfaceScanner().measure(paths: [dir.path])
    #expect(dirs.first.map { URL(fileURLWithPath: $0.path).lastPathComponent } == "D")
    #expect((dirs.first?.sizeBytes ?? 0) >= 77_000)
}
```

- [ ] **Step 2: 运行确认失败**
- [ ] **Step 3: 实现**（把 `Scanner.scan` 的按路径测量块抽成 `rescan`，运行时配方复用同一展开逻辑；`SurfaceScanner` 增加显式路径测量）

```swift
// Scanner.swift 内新增
/// 重扫单个配方路径（增量用）：普通配方返回 1 项，运行时配方返回展开的子项。
public func rescan(
    path: String,
    recipe: Recipe,
    homeDirectory: String
) -> [ScanItem] {
    guard FileManager.default.fileExists(atPath: path) else { return [] }
    if recipe.usageProbe == .simulatorRuntimeLastBooted {
        return runtimeItems(recipe: recipe, parentPath: path, homeDirectory: homeDirectory)
    }
    let url = URL(fileURLWithPath: path, isDirectory: true)
    let itemID = "\(recipe.id):\(path)"
    guard let (size, allocated, count, modified, _) = try? measureDirectory(
        url,
        itemID: itemID,
        lightWeight: recipe.disposition == .none
    ) else { return [] }
    var item = ScanItem(
        id: itemID, recipeID: recipe.id, name: recipe.name, path: path,
        category: recipe.category, safety: recipe.safety,
        disposition: recipe.disposition, cleanability: recipe.cleanability,
        sizeBytes: size, allocatedBytes: allocated, reclaimableBytes: allocated,
        fileCount: count, lastModified: modified
    )
    if recipe.cloneProne {
        item = ScanItem(
            id: item.id, recipeID: item.recipeID, name: item.name, path: item.path,
            category: item.category, safety: item.safety,
            disposition: item.disposition, cleanability: item.cleanability,
            sizeBytes: item.sizeBytes, allocatedBytes: item.allocatedBytes,
            reclaimableBytes: Int64(Double(item.allocatedBytes) * (self.cloneRatios[recipe.id] ?? 0.2)),
            fileCount: item.fileCount, lastModified: item.lastModified
        )
    }
    return [item]
}
```

> `runtimeItems(recipe:parentPath:homeDirectory:)` 由现有 `appendRuntimeItems` 重构而来（返回 `[ScanItem]` 而非 inout 追加），`scan()` 与 `rescan()` 共用。

```swift
// SurfaceScanner.swift 内新增
/// 测量显式路径（增量用）：返回每个路径的 SurfaceDirectory，不设大小下限。
public func measure(paths: [String], minimumSizeBytes: Int64 = 0) -> [SurfaceDirectory] {
    var result: [SurfaceDirectory] = []
    for path in paths {
        guard let walk = POSIXDirectoryWalker.walk(
            url: URL(fileURLWithPath: path),
            itemID: path,
            includeRecords: false
        ) else { continue }
        guard walk.sizeBytes >= minimumSizeBytes else { continue }
        result.append(SurfaceDirectory(
            path: path,
            sizeBytes: walk.sizeBytes,
            fileCount: walk.fileCount,
            lastModified: walk.newest
        ))
    }
    return result
}
```

- [ ] **Step 4: 运行确认通过**

Run: `swift test --filter 'rescanMeasuresSingleRecipePath|surfaceScannerMeasuresExplicitPaths'`
Expected: PASS；全量 `swift test` 无回归。

- [ ] **Step 5: 提交**

```bash
git add Sources/DiskReservoirCore Tests/DiskReservoirCoreTests
git commit -m "feat: add targeted rescan for recipes and surface directories"
```

---

### Task 5: AppService 增量编排

**Files:**
- Modify: `PoolProblem/PoolProblem/AppService.swift`

**Interfaces:**
- Consumes: `FSEventMonitor`、`DirtyTracker`、`Scanner.rescan`、`SurfaceScanner.measure`、`SnapshotSource`、`GrowthLedgerBuilder`/`GrowthLedgerStore`/`RecipeSuggester`。
- Produces: `AppService` 私有成员 `fseventMonitor`/`dirtyTracker`/`incrementalTimer`/`lastIncrementalAt`；`startWatching()`、`handleEvents(_:)`、`incrementalScanIfDirty()`、`runIncrementalScan(dirty:)`、`updateIncrementalInsights(previous:latest:surface:)`。

- [ ] **Step 1: 增加成员与初始化**

```swift
private let fseventMonitor = FSEventMonitor(paths: [])
private var dirtyTracker = DirtyTracker(trackedPaths: [])
private var incrementalTimer: Timer?
private var lastIncrementalAt = Date.distantPast
```

- [ ] **Step 2: `scanNow` 全量扫描成功后启动监听**（幂等：重复调用先 stop 再 start）

```swift
// scanNow 末尾、refreshGaugeImage() 之前：
startWatching()
```

```swift
private func startWatching() {
    let home = NSHomeDirectory()
    let recipePaths = RecipeRegistry.builtIn()
        .flatMap { $0.resolvePaths(StoragePaths(baseURL: nil, homeDirectory: home)) }
    let roots = SurfaceScanner.defaultRoots(homeDirectory: home)
    dirtyTracker = DirtyTracker(trackedPaths: Array(Set(recipePaths + roots)))
    fseventMonitor.start { [weak self] eventPaths in
        Task { @MainActor [weak self] in
            self?.handleEvents(eventPaths)
        }
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
```

- [ ] **Step 3: 实现增量重扫**

```swift
private func runIncrementalScan(dirty: Set<String>) async {
    let home = NSHomeDirectory()
    let paths = self.paths
    let recipes = RecipeRegistry.builtIn()
    let cloneRatios = loadConfig().cloneRatios
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
                let fresh = Scanner(cloneRatios: cloneRatios).rescan(
                    path: path,
                    recipe: recipe,
                    homeDirectory: home
                )
                items.removeAll { $0.path == path || $0.path.hasPrefix(path + "/") }
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
        existingRecipes: RecipeRegistry.builtIn(),
        homeDirectory: home
    )
    try? recipeSuggestionStore.merge(candidates)
    state.growthInsights = Array(allEntries.suffix(30).reversed())
    state.candidateRecipes = (try? recipeSuggestionStore.load()) ?? []
}
```

- [ ] **Step 4: 构建验证**

Run: `xcodebuild -project PoolProblem/PoolProblem.xcodeproj -scheme PoolProblem -configuration Debug -derivedDataPath .build/xcode-derived build`
Expected: BUILD SUCCEEDED。

- [ ] **Step 5: 提交**

```bash
git add PoolProblem
git commit -m "feat: wire FSEvents incremental rescans into app service"
```

---

### Task 6: 全量验证与收尾

- [ ] **Step 1: Core 测试**

Run: `swift test`
Expected: 全部 PASS（含既有 105 个 + 新增）。

- [ ] **Step 2: App 构建 + 启动冒烟**

Run: `xcodebuild ... build`；随后用临时 `POOLPROBLEM_DATA_DIR` 启动 App 二进制 5 秒，确认不崩溃。

- [ ] **Step 3: 自查**
  - 增量快照只出现在两次全量扫描之间；全量扫描后 `SnapshotSource.full` 仍是主序列。
  - `updateIncrementalInsights` 与既有 `updateGrowthInsights` 不重复触发 24h 表面扫描门控。
  - FSEventMonitor 在 `start()` 前先 `stop()`，重复调用安全；App 退出时 `deinit` 释放流。

- [ ] **Step 4: 提交**

```bash
git add .
git commit -m "feat: complete FSEvents incremental monitoring (L1.5)"
```

---

## 后续（不在本计划内）

- FSEvents `sinceWhen` 事件 ID 持久化：App 重启后从上次事件继续，避免漏掉退出期间的变化。
- 增量快照参与自动清理决策（需先验证合成快照与全量口径一致性）。
- 把"脏目录"按 recipe 分组并行重扫（当前串行即可，路径数有限）。
