# 增长台账与配方建议（L1+L2）实现计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在 The Pool Problem 中落地 L1（本地增长台账：及时记录并展示"哪些地方在快速增长"，含配方外未知增长）与 L2（本地候选配方建议：从台账模式聚类出尚未被配方覆盖的增长源，用户可采纳/忽略），并在现有菜单栏面板与设置窗口中给出合适的展示方式。

**Architecture:** 领域逻辑全部落在 SwiftPM 包 `DiskReservoirCore`（新目录 `Growth/` 与 `Suggest/`），App 层只做调度与展示。每次扫描后由 `AppService` 调用 `GrowthLedgerBuilder` 对比新旧快照生成增长条目并落盘（`growth-ledger.json`）；当"未覆盖空间"增量超过阈值时，事件驱动地跑一次轻量 `SurfaceScanner`（对 `~/Library/Caches|Logs|Developer|Application Support|~/.cache` 一级子目录做 POSIX 汇总），再把这些目录的增量写进台账；`RecipeSuggester` 从最近 30 天台账中按路径模式聚类、过滤掉已被配方覆盖的模式，产出候选配方（`recipe-suggestions.json`，保留用户采纳/忽略状态）。UI：菜单栏右侧面板新增"增长洞察"卡片（点击弹 sheet 看明细与候选配方卡），设置窗口"专家模式"下新增"候选配方"区。

**Tech Stack:** Swift 6、SwiftUI、macOS 14+、Swift Testing（`#expect`）、现有 `POSIXDirectoryWalker`/`JSONStore`/`StoragePaths`。

**Spec:** 本计划即设计文档（2026-08-18 与用户确认的 L1+L2 方案；完整产品设计见 `docs/superpowers/specs/2026-08-09-the-pool-problem-design.md`）。

## Global Constraints

- macOS 14+；Core 为 SwiftPM 包（新增源码文件自动纳入 `DiskReservoirCore` target）；App target 使用 `PBXFileSystemSynchronizedRootGroup`，`PoolProblem/PoolProblem/` 下新增文件自动纳入工程。
- 领域逻辑（增长计算、模式聚类、候选评分）禁止写在 View/AppService 层；一律进 `DiskReservoirCore`。
- 存储沿用 `JSONStoring`（iso8601 日期）；`StoragePaths` 新增 URL 必须带 `decodeIfPresent`/默认值语义（新文件不存在即返回空数组）。
- 增长条目必须脱敏后才可展示/持久化：台账保存"真实路径 + patternized 模式"双字段；候选配方只暴露 `pattern` 与一个 `samplePath`。
- 一切增长阈值有默认值：已知项增量 ≥ 100MB、未知空间增量 ≥ 300MB、表面目录增量 ≥ 200MB、候选配方累计 ≥ 500MB；均为可注入参数，便于测试。
- 提交规范：conventional commits；每任务 `swift test` 通过、最终 `xcodebuild build` 通过后才提交。
- 本计划不做：上报/telemetry（L3）、AI 建议（L4）、通知入口、采纳候选后的自动扫描接线（用户配方）。这些留作后续计划。

---

## 文件结构

```
Sources/DiskReservoirCore/
├── Growth/GrowthEntry.swift          # 新增：增长条目模型 + GrowthKind
├── Growth/SurfaceDirectory.swift     # 新增：表面目录（一级子目录）模型
├── Growth/SurfaceScanner.swift       # 新增：轻量表面扫描
├── Growth/GrowthLedger.swift         # 新增：GrowthLedgerBuilder（快照/表面 diff）
├── Growth/GrowthLedgerStore.swift    # 新增：台账 + 表面快照持久化
├── Suggest/PathPatternizer.swift     # 新增：路径模式化（脱敏）
├── Suggest/CandidateRecipe.swift     # 新增：候选配方模型 + CandidateStatus
├── Suggest/RecipeSuggester.swift     # 新增：聚类/评分/过滤
├── Suggest/RecipeSuggestionStore.swift # 新增：候选持久化（保留用户决定）
└── Storage/StoragePaths.swift        # 修改：+growthLedgerURL/+surfaceSnapshotURL/+recipeSuggestionsURL

Tests/DiskReservoirCoreTests/
├── GrowthLedgerTests.swift           # 新增
├── SurfaceScannerTests.swift         # 新增
├── PathPatternizerTests.swift        # 新增
├── RecipeSuggesterTests.swift        # 新增
└── StoragePathsTests.swift           # 修改：断言新 URL

PoolProblem/PoolProblem/
├── Models/AppState.swift             # 修改：+growthInsights/+candidateRecipes/+showGrowthInsights
├── AppService.swift                  # 修改：scanNow 后接台账与建议；accept/dismiss 方法
├── Views/GrowthInsightsView.swift    # 新增：增长明细 + 候选配方 sheet
├── Views/MenuBarView.swift           # 修改：右侧面板"增长洞察"卡片 + sheet 入口
├── Views/SettingsView.swift          # 修改：专家模式"候选配方"区
├── Localized.swift                   # 修改：+recipeSafetyName 等
└── Localizable.xcstrings             # 修改：新增 keys（en + zh-Hans）
```

---

### Task 1: 增长条目与表面目录模型 + 存储路径

**Files:**
- Create: `Sources/DiskReservoirCore/Growth/GrowthEntry.swift`
- Create: `Sources/DiskReservoirCore/Growth/SurfaceDirectory.swift`
- Modify: `Sources/DiskReservoirCore/Storage/StoragePaths.swift`
- Test: `Tests/DiskReservoirCoreTests/StoragePathsTests.swift`

**Interfaces:**
- Consumes: 无。
- Produces: `GrowthKind`、`GrowthEntry`、`SurfaceDirectory`；`StoragePaths.growthLedgerURL`、`StoragePaths.surfaceSnapshotURL`、`StoragePaths.recipeSuggestionsURL`。

- [ ] **Step 1: 写失败测试**

```swift
// Tests/DiskReservoirCoreTests/StoragePathsTests.swift 内新增
@Test func growthURLsPointIntoBase() {
    let paths = StoragePaths(baseURL: URL(fileURLWithPath: "/tmp/pp-test"))
    #expect(paths.growthLedgerURL.lastPathComponent == "growth-ledger.json")
    #expect(paths.surfaceSnapshotURL.lastPathComponent == "surface-snapshot.json")
    #expect(paths.recipeSuggestionsURL.lastPathComponent == "recipe-suggestions.json")
}
```

- [ ] **Step 2: 运行确认失败**

Run: `swift test --filter growthURLsPointIntoBase`
Expected: FAIL（growthLedgerURL 等未定义）。

- [ ] **Step 3: 实现模型与路径**

```swift
// GrowthEntry.swift
import Foundation

public enum GrowthKind: String, Codable, Sendable {
    case known        // 已知配方项增长
    case new          // 新出现的已知配方项
    case unknownSpace // 配方未覆盖的卷空间增长
    case surface      // 表面扫描发现的一级目录增长
}

public struct GrowthEntry: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let observedAt: Date
    public let elapsedDays: Double
    public let itemID: String?
    public let recipeID: String?
    public let name: String
    public let path: String
    public let pattern: String
    public let kind: GrowthKind
    public let deltaBytes: Int64
    public let rateBytesPerDay: Double

    public init(
        id: UUID = UUID(),
        observedAt: Date,
        elapsedDays: Double,
        itemID: String? = nil,
        recipeID: String? = nil,
        name: String,
        path: String,
        pattern: String,
        kind: GrowthKind,
        deltaBytes: Int64,
        rateBytesPerDay: Double
    ) { ... }
}
```

```swift
// SurfaceDirectory.swift
import Foundation

public struct SurfaceDirectory: Codable, Equatable, Identifiable, Sendable {
    public let path: String
    public let sizeBytes: Int64
    public let fileCount: Int
    public let lastModified: Date?

    public var id: String { path }

    public init(path: String, sizeBytes: Int64, fileCount: Int, lastModified: Date?) { ... }
}
```

```swift
// StoragePaths.swift 追加
public var growthLedgerURL: URL { baseURL.appendingPathComponent("growth-ledger.json") }
public var surfaceSnapshotURL: URL { baseURL.appendingPathComponent("surface-snapshot.json") }
public var recipeSuggestionsURL: URL { baseURL.appendingPathComponent("recipe-suggestions.json") }
```

- [ ] **Step 4: 运行确认通过**

Run: `swift test --filter growthURLsPointIntoBase`
Expected: PASS。

- [ ] **Step 5: 提交**

```bash
git add Sources/DiskReservoirCore Tests/DiskReservoirCoreTests
git commit -m "feat: add growth entry and surface directory models"
```

---

### Task 2: 路径模式化（脱敏）

**Files:**
- Create: `Sources/DiskReservoirCore/Suggest/PathPatternizer.swift`
- Test: `Tests/DiskReservoirCoreTests/PathPatternizerTests.swift`

**Interfaces:**
- Consumes: 无。
- Produces: `PathPatternizer.patternize(_:homeDirectory:) -> String`。

- [ ] **Step 1: 写失败测试**

```swift
@Test func patternizeReplacesHomeAndHashes() {
    let home = "/Users/alice"
    #expect(PathPatternizer.patternize("/Users/alice/Library/Caches/MyApp", homeDirectory: home)
            == "~/Library/Caches/MyApp")
    #expect(PathPatternizer.patternize("/Users/alice/Library/Developer/Xcode/DerivedData/AB12CD34EF56",
            homeDirectory: home) == "~/Library/Developer/Xcode/DerivedData/*")
    #expect(PathPatternizer.patternize("/Users/alice/Library/Caches/Tool/8F4B2C1A-9D3E-4A5B-8C6D-7E8F9A0B1C2D",
            homeDirectory: home) == "~/Library/Caches/Tool/*")
}
```

- [ ] **Step 2: 运行确认失败**

Run: `swift test --filter patternizeReplacesHomeAndHashes`
Expected: FAIL。

- [ ] **Step 3: 实现**

```swift
public enum PathPatternizer {
    public static func patternize(_ path: String, homeDirectory: String = NSHomeDirectory()) -> String {
        var result = path
        if result == homeDirectory {
            result = "~"
        } else if result.hasPrefix(homeDirectory + "/") {
            result = "~" + result.dropFirst(homeDirectory.count)
        }
        result = result.replacingOccurrences(
            of: #"[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}"#,
            with: "*", options: .regularExpression
        )
        result = result.replacingOccurrences(
            of: #"[0-9A-Fa-f]{8,}"#, with: "*", options: .regularExpression
        )
        return result
    }
}
```

- [ ] **Step 4: 运行确认通过**（同上，Expected: PASS）
- [ ] **Step 5: 提交**

```bash
git add Sources/DiskReservoirCore Tests/DiskReservoirCoreTests
git commit -m "feat: add path patternizer for anonymized growth patterns"
```

---

### Task 3: 增长台账构建器与存储

**Files:**
- Create: `Sources/DiskReservoirCore/Growth/GrowthLedger.swift`
- Create: `Sources/DiskReservoirCore/Growth/GrowthLedgerStore.swift`
- Test: `Tests/DiskReservoirCoreTests/GrowthLedgerTests.swift`

**Interfaces:**
- Consumes: `Snapshot`、`ScanItem`、`GrowthEntry`、`SurfaceDirectory`、`PathPatternizer`、`StoragePaths`、`JSONStoring`。
- Produces:
  - `GrowthLedgerBuilder.entries(previous:latest:homeDirectory:) -> [GrowthEntry]`
  - `GrowthLedgerBuilder.surfaceEntries(previous:latest:homeDirectory:) -> [GrowthEntry]`
  - `GrowthLedgerBuilder.unknownSpaceDelta(previous:latest:) -> Int64`
  - `GrowthLedgerStore.append(_:)`、`entries()`、`prune(retainingDays:)`、`saveSurface(_:scannedAt:)`、`surfaceDirectories()`、`lastSurfaceScanAt()`。

- [ ] **Step 1: 写失败测试**（关键行为：已知项增量、新项、未知空间、表面增量、阈值过滤）

```swift
@Test func ledgerTracksKnownGrowth() {
    let now = Date()
    let prev = Snapshot(volume: VolumeInfo(totalBytes: 1000, availableBytes: 500, timestamp: now.addingTimeInterval(-86_400)),
                        items: [item("x1", recipe: "r", size: 100)])
    let latest = Snapshot(volume: VolumeInfo(totalBytes: 1000, availableBytes: 300, timestamp: now),
                          items: [item("x1", recipe: "r", size: 400)])
    let entries = GrowthLedgerBuilder(minimumDeltaBytes: 50).entries(previous: prev, latest: latest, homeDirectory: "/tmp")
    #expect(entries.count == 1)
    #expect(entries[0].kind == .known)
    #expect(entries[0].deltaBytes == 300)
    #expect(entries[0].rateBytesPerDay == 300)
}

@Test func ledgerReportsUnknownSpaceGrowth() {
    let now = Date()
    let prev = Snapshot(volume: VolumeInfo(totalBytes: 1000, availableBytes: 500, timestamp: now.addingTimeInterval(-86_400)), items: [item("x1", recipe: "r", size: 100)])
    let latest = Snapshot(volume: VolumeInfo(totalBytes: 1000, availableBytes: 100, timestamp: now), items: [item("x1", recipe: "r", size: 150)])
    // used: prev=500, latest=900；known: prev=100, latest=150 → unknown Δ = (900-150)-(500-100)=350
    let entries = GrowthLedgerBuilder(unknownSpaceThresholdBytes: 300).entries(previous: prev, latest: latest, homeDirectory: "/tmp")
    #expect(entries.contains { $0.kind == .unknownSpace && $0.deltaBytes == 350 })
}

@Test func ledgerDiffsSurfaceDirectories() {
    let prevDirs = [SurfaceDirectory(path: "/tmp/cache/A", sizeBytes: 100, fileCount: 1, lastModified: nil)]
    let latestDirs = [SurfaceDirectory(path: "/tmp/cache/A", sizeBytes: 500, fileCount: 1, lastModified: nil)]
    let entries = GrowthLedgerBuilder(surfaceMinimumDeltaBytes: 200)
        .surfaceEntries(previous: prevDirs, latest: latestDirs, homeDirectory: "/tmp")
    #expect(entries.count == 1)
    #expect(entries[0].kind == .surface)
    #expect(entries[0].pattern == "~/cache/A")
    #expect(entries[0].deltaBytes == 400)
}
```

- [ ] **Step 2: 运行确认失败**

Run: `swift test --filter ledgerTracksKnownGrowth --filter ledgerReportsUnknownSpaceGrowth --filter ledgerDiffsSurfaceDirectories`
Expected: FAIL（类型不存在）。

- [ ] **Step 3: 实现**

```swift
// GrowthLedger.swift
public struct GrowthLedgerBuilder: Sendable {
    public let minimumDeltaBytes: Int64
    public let unknownSpaceThresholdBytes: Int64
    public let surfaceMinimumDeltaBytes: Int64

    public init(
        minimumDeltaBytes: Int64 = 100 << 20,
        unknownSpaceThresholdBytes: Int64 = 300 << 20,
        surfaceMinimumDeltaBytes: Int64 = 200 << 20
    ) { ... }

    public static func usedBytes(_ snapshot: Snapshot) -> Int64 {
        snapshot.volume.totalBytes - snapshot.volume.availableBytes
    }

    public static func knownBytes(_ snapshot: Snapshot) -> Int64 {
        snapshot.items.reduce(Int64(0)) { $0 + max(0, $1.sizeBytes) }
    }

    public func unknownSpaceDelta(previous: Snapshot, latest: Snapshot) -> Int64 {
        (Self.usedBytes(latest) - Self.knownBytes(latest))
            - (Self.usedBytes(previous) - Self.knownBytes(previous))
    }

    public func entries(previous: Snapshot?, latest: Snapshot, homeDirectory: String = NSHomeDirectory()) -> [GrowthEntry] {
        guard let previous else { return [] }
        let elapsed = max(latest.volume.timestamp.timeIntervalSince(previous.volume.timestamp) / 86_400, 1.0 / 86_400)
        var result: [GrowthEntry] = []
        let prevByID = Dictionary(uniqueKeysWithValues: previous.items.map { ($0.id, $0) })
        for item in latest.items {
            let delta = item.sizeBytes - (prevByID[item.id]?.sizeBytes ?? 0)
            guard delta >= minimumDeltaBytes else { continue }
            let kind: GrowthKind = prevByID[item.id] == nil ? .new : .known
            result.append(GrowthEntry(
                observedAt: latest.volume.timestamp,
                elapsedDays: elapsed,
                itemID: item.id,
                recipeID: item.recipeID,
                name: item.name,
                path: item.path,
                pattern: PathPatternizer.patternize(item.path, homeDirectory: homeDirectory),
                kind: kind,
                deltaBytes: delta,
                rateBytesPerDay: Double(delta) / elapsed
            ))
        }
        let unknown = unknownSpaceDelta(previous: previous, latest: latest)
        if unknown >= unknownSpaceThresholdBytes {
            result.append(GrowthEntry(
                observedAt: latest.volume.timestamp,
                elapsedDays: elapsed,
                name: "Unknown space",
                path: "",
                pattern: "unknown://space",
                kind: .unknownSpace,
                deltaBytes: unknown,
                rateBytesPerDay: Double(unknown) / elapsed
            ))
        }
        return result
    }

    public func surfaceEntries(
        previous: [SurfaceDirectory],
        latest: [SurfaceDirectory],
        homeDirectory: String = NSHomeDirectory()
    ) -> [GrowthEntry] {
        let prevByPath = Dictionary(uniqueKeysWithValues: previous.map { ($0.path, $0.sizeBytes) })
        var result: [GrowthEntry] = []
        for dir in latest {
            guard let old = prevByPath[dir.path] else { continue }
            let delta = dir.sizeBytes - old
            guard delta >= surfaceMinimumDeltaBytes else { continue }
            result.append(GrowthEntry(
                observedAt: Date(),
                elapsedDays: 1,
                name: URL(fileURLWithPath: dir.path).lastPathComponent,
                path: dir.path,
                pattern: PathPatternizer.patternize(dir.path, homeDirectory: homeDirectory),
                kind: .surface,
                deltaBytes: delta,
                rateBytesPerDay: Double(delta)
            ))
        }
        return result.sorted { $0.deltaBytes > $1.deltaBytes }
    }
}
```

```swift
// GrowthLedgerStore.swift
public struct SurfaceSnapshot: Codable, Sendable {
    public let scannedAt: Date
    public let directories: [SurfaceDirectory]
    public init(scannedAt: Date, directories: [SurfaceDirectory]) { ... }
}

public struct GrowthLedgerStore: Sendable {
    private let paths: StoragePaths
    private let store: JSONStoring

    public init(paths: StoragePaths, store: JSONStoring = JSONStore()) { ... }

    public func entries() throws -> [GrowthEntry] {
        try store.load([GrowthEntry].self, from: paths.growthLedgerURL) ?? []
    }

    public func append(_ entries: [GrowthEntry]) throws {
        var all = try self.entries()
        all.append(contentsOf: entries)
        all.sort { $0.observedAt < $1.observedAt }
        try store.save(all, to: paths.growthLedgerURL)
    }

    public func prune(retainingDays: Int = 30) throws {
        let cutoff = Date().addingTimeInterval(-Double(retainingDays) * 86_400)
        try store.save(try entries().filter { $0.observedAt >= cutoff }, to: paths.growthLedgerURL)
    }

    public func saveSurface(_ dirs: [SurfaceDirectory], scannedAt: Date) throws {
        try store.save(SurfaceSnapshot(scannedAt: scannedAt, directories: dirs), to: paths.surfaceSnapshotURL)
    }

    public func surfaceDirectories() throws -> [SurfaceDirectory] {
        try store.load(SurfaceSnapshot.self, from: paths.surfaceSnapshotURL)?.directories ?? []
    }

    public func lastSurfaceScanAt() -> Date? {
        try? store.load(SurfaceSnapshot.self, from: paths.surfaceSnapshotURL)?.scannedAt
    }
}
```

- [ ] **Step 4: 运行确认通过**
- [ ] **Step 5: 提交**

```bash
git add Sources/DiskReservoirCore Tests/DiskReservoirCoreTests
git commit -m "feat: add growth ledger builder and store"
```

---

### Task 4: 表面扫描器

**Files:**
- Create: `Sources/DiskReservoirCore/Growth/SurfaceScanner.swift`
- Test: `Tests/DiskReservoirCoreTests/SurfaceScannerTests.swift`

**Interfaces:**
- Consumes: `POSIXDirectoryWalker`、`SurfaceDirectory`。
- Produces: `SurfaceScanner.scan(roots:minimumSizeBytes:) -> [SurfaceDirectory]`、`SurfaceScanner.defaultRoots(homeDirectory:) -> [String]`。

- [ ] **Step 1: 写失败测试**（用 `FileManager` 在临时目录造两个一级子目录，其中一个超过下限）

```swift
@Test func surfaceScannerMeasuresFirstLevelChildren() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("pp-surface-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let big = root.appendingPathComponent("Big")
    try FileManager.default.createDirectory(at: big, withIntermediateDirectories: true)
    try Data(repeating: 0x41, count: 300_000).write(to: big.appendingPathComponent("f.bin"))
    let dirs = SurfaceScanner().scan(roots: [root.path], minimumSizeBytes: 100_000)
    #expect(dirs.contains { $0.path == big.path && $0.sizeBytes >= 300_000 })
    #expect(dirs.allSatisfy { $0.fileCount >= 0 })
}

@Test func surfaceScannerDefaultRootsAreHomeScoped() {
    let roots = SurfaceScanner.defaultRoots(homeDirectory: "/Users/alice")
    #expect(roots.contains("/Users/alice/Library/Caches"))
    #expect(roots.contains("/Users/alice/.cache"))
}
```

- [ ] **Step 2: 运行确认失败**
- [ ] **Step 3: 实现**

```swift
public struct SurfaceScanner: Sendable {
    public init() {}

    public static func defaultRoots(homeDirectory: String) -> [String] {
        [
            "\(homeDirectory)/Library/Caches",
            "\(homeDirectory)/Library/Logs",
            "\(homeDirectory)/Library/Developer",
            "\(homeDirectory)/Library/Application Support",
            "\(homeDirectory)/.cache",
        ].filter { FileManager.default.fileExists(atPath: $0) }
    }

    public func scan(roots: [String], minimumSizeBytes: Int64 = 50 << 20) -> [SurfaceDirectory] {
        var result: [SurfaceDirectory] = []
        for root in roots {
            let rootURL = URL(fileURLWithPath: root, isDirectory: true)
            guard let children = try? FileManager.default.contentsOfDirectory(
                at: rootURL,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ) else { continue }
            for child in children {
                guard let walk = POSIXDirectoryWalker.walk(url: child, itemID: child.path, includeRecords: false) else { continue }
                guard walk.sizeBytes >= minimumSizeBytes else { continue }
                result.append(SurfaceDirectory(
                    path: child.path,
                    sizeBytes: walk.sizeBytes,
                    fileCount: walk.fileCount,
                    lastModified: walk.newest
                ))
            }
        }
        return result.sorted { $0.sizeBytes > $1.sizeBytes }
    }
}
```

- [ ] **Step 4: 运行确认通过**
- [ ] **Step 5: 提交**

```bash
git add Sources/DiskReservoirCore Tests/DiskReservoirCoreTests
git commit -m "feat: add lightweight surface scanner for uncovered growth"
```

---

### Task 5: 候选配方模型与建议器

**Files:**
- Create: `Sources/DiskReservoirCore/Suggest/CandidateRecipe.swift`
- Create: `Sources/DiskReservoirCore/Suggest/RecipeSuggester.swift`
- Test: `Tests/DiskReservoirCoreTests/RecipeSuggesterTests.swift`

**Interfaces:**
- Consumes: `GrowthEntry`、`Recipe`、`PathPatternizer`、`StoragePaths`。
- Produces: `CandidateStatus`、`CandidateRecipe`、`RecipeSuggester.suggest(entries:existingRecipes:homeDirectory:) -> [CandidateRecipe]`。

- [ ] **Step 1: 写失败测试**

```swift
@Test func suggesterClustersSurfaceGrowthAndSkipsCoveredPatterns() {
    let now = Date()
    func entry(_ pattern: String, _ delta: Int64, _ path: String) -> GrowthEntry {
        GrowthEntry(observedAt: now, elapsedDays: 1, name: "x", path: path,
                    pattern: pattern, kind: .surface, deltaBytes: delta, rateBytesPerDay: Double(delta))
    }
    let entries = [
        entry("~/Library/Caches/NewTool/*", 600 << 20, "/Users/alice/Library/Caches/NewTool/cache"),
        entry("~/Library/Caches/NewTool/*", 200 << 20, "/Users/alice/Library/Caches/NewTool/other"),
        entry("~/Library/Developer/Xcode/DerivedData/*", 900 << 20, "/Users/alice/Library/Developer/Xcode/DerivedData/HASH"),
    ]
    let coveredRecipe = Recipe(
        id: "deriveddata", name: "DerivedData", category: .xcode, safety: .safeWhileRunning,
        disposition: .deletePermanently, cleanability: .regenerable,
        defaultAgeDays: 7, minimumSizeMB: 0, processName: nil,
        resolvePaths: { _ in ["/Users/alice/Library/Developer/Xcode/DerivedData"] }
    )
    let candidates = RecipeSuggester(minTotalBytes: 100 << 20)
        .suggest(entries: entries, existingRecipes: [coveredRecipe], homeDirectory: "/Users/alice")
    #expect(candidates.count == 1)
    #expect(candidates[0].pattern == "~/Library/Caches/NewTool/*")
    #expect(candidates[0].totalGrowthBytes == 800 << 20)
    #expect(candidates[0].evidenceCount == 2)
    #expect(candidates[0].suggestedSafety == .safeWhileRunning)
    #expect(candidates[0].status == .pending)
}
```

- [ ] **Step 2: 运行确认失败**
- [ ] **Step 3: 实现**

```swift
public enum CandidateStatus: String, Codable, Sendable {
    case pending, accepted, dismissed
}

public struct CandidateRecipe: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let pattern: String
    public var status: CandidateStatus
    public let totalGrowthBytes: Int64
    public let peakRateBytesPerDay: Double
    public let evidenceCount: Int
    public let firstSeenAt: Date
    public let lastSeenAt: Date
    public let suggestedSafety: SafetyLevel
    public let suggestedCleanability: Cleanability
    public let suggestedCategory: Category
    public let samplePath: String

    public init(
        id: String, pattern: String, status: CandidateStatus = .pending,
        totalGrowthBytes: Int64, peakRateBytesPerDay: Double, evidenceCount: Int,
        firstSeenAt: Date, lastSeenAt: Date,
        suggestedSafety: SafetyLevel, suggestedCleanability: Cleanability,
        suggestedCategory: Category, samplePath: String
    ) { ... }
}

public struct RecipeSuggester: Sendable {
    public let minTotalBytes: Int64
    public let topK: Int

    public init(minTotalBytes: Int64 = 500 << 20, topK: Int = 5) { ... }

    public func suggest(
        entries: [GrowthEntry],
        existingRecipes: [Recipe],
        homeDirectory: String = NSHomeDirectory()
    ) -> [CandidateRecipe] {
        let covered = existingRecipes
            .flatMap { $0.resolvePaths(StoragePaths(baseURL: nil, homeDirectory: homeDirectory)) }
            .map { PathPatternizer.patternize($0, homeDirectory: homeDirectory) }
        func isCovered(_ pattern: String) -> Bool {
            covered.contains { $0 == pattern || pattern.hasPrefix($0 + "/") }
        }
        var grouped: [String: [GrowthEntry]] = [:]
        for entry in entries where entry.kind == .surface && entry.deltaBytes > 0 {
            guard !isCovered(entry.pattern) else { continue }
            grouped[entry.pattern, default: []].append(entry)
        }
        let candidates: [CandidateRecipe] = grouped.compactMap { pattern, group in
            let total = group.reduce(Int64(0)) { $0 + $1.deltaBytes }
            guard total >= minTotalBytes else { return nil }
            let sorted = group.sorted { $0.observedAt < $1.observedAt }
            let cacheish = pattern.contains("/Caches/") || pattern.contains("/Logs/")
                || pattern.contains("/DerivedData") || pattern.hasPrefix("~/.cache")
            return CandidateRecipe(
                id: pattern, pattern: pattern,
                totalGrowthBytes: total,
                peakRateBytesPerDay: group.map(\.rateBytesPerDay).max() ?? 0,
                evidenceCount: group.count,
                firstSeenAt: sorted.first?.observedAt ?? Date(),
                lastSeenAt: sorted.last?.observedAt ?? Date(),
                suggestedSafety: cacheish ? .safeWhileRunning : .userConfirm,
                suggestedCleanability: cacheish ? .regenerable : .userDataOnly,
                suggestedCategory: .custom,
                samplePath: group.first?.path ?? pattern
            )
        }
        return candidates
            .sorted { $0.totalGrowthBytes > $1.totalGrowthBytes }
            .prefix(topK)
            .map { $0 }
    }
}
```

- [ ] **Step 4: 运行确认通过**
- [ ] **Step 5: 提交**

```bash
git add Sources/DiskReservoirCore Tests/DiskReservoirCoreTests
git commit -m "feat: add candidate recipe suggester"
```

---

### Task 6: 候选持久化（保留用户决定）

**Files:**
- Create: `Sources/DiskReservoirCore/Suggest/RecipeSuggestionStore.swift`
- Test: `Tests/DiskReservoirCoreTests/RecipeSuggesterTests.swift`（追加两个用例）

**Interfaces:**
- Consumes: `CandidateRecipe`、`CandidateStatus`、`StoragePaths`、`JSONStoring`。
- Produces: `RecipeSuggestionStore.load()`、`merge(_:)`、`setStatus(id:status:)`。

- [ ] **Step 1: 写失败测试**

```swift
@Test func suggestionStorePreservesUserDecisions() throws {
    let paths = StoragePaths(baseURL: URL(fileURLWithPath: "/tmp/pp-suggest-\(UUID().uuidString)"))
    defer { try? FileManager.default.removeItem(at: paths.baseURL) }
    let store = RecipeSuggestionStore(paths: paths)
    let a = CandidateRecipe(id: "~/p", pattern: "~/p", totalGrowthBytes: 1, peakRateBytesPerDay: 1,
                            evidenceCount: 1, firstSeenAt: Date(), lastSeenAt: Date(),
                            suggestedSafety: .userConfirm, suggestedCleanability: .userDataOnly,
                            suggestedCategory: .custom, samplePath: "~/p")
    try store.merge([a])
    try store.setStatus(id: "~/p", status: .accepted)
    let reloaded = try store.load()
    #expect(reloaded.first?.status == .accepted)
    // 下一次建议仍保留 accepted，而不是被重置为 pending
    try store.merge([CandidateRecipe(id: "~/p", pattern: "~/p", totalGrowthBytes: 2, peakRateBytesPerDay: 1,
                                     evidenceCount: 2, firstSeenAt: Date(), lastSeenAt: Date(),
                                     suggestedSafety: .userConfirm, suggestedCleanability: .userDataOnly,
                                     suggestedCategory: .custom, samplePath: "~/p")])
    #expect(try store.load().first?.status == .accepted)
}
```

- [ ] **Step 2: 运行确认失败**
- [ ] **Step 3: 实现**（按 id merge：已有条目保留原 status 并更新统计；新条目插入）
- [ ] **Step 4: 运行确认通过**
- [ ] **Step 5: 提交**

```bash
git add Sources/DiskReservoirCore Tests/DiskReservoirCoreTests
git commit -m "feat: persist recipe suggestions with user decisions"
```

---

### Task 7: AppService 接线 + AppState

**Files:**
- Modify: `PoolProblem/PoolProblem/Models/AppState.swift`
- Modify: `PoolProblem/PoolProblem/AppService.swift`

**Interfaces:**
- Consumes: `GrowthLedgerBuilder`、`GrowthLedgerStore`、`SurfaceScanner`、`RecipeSuggester`、`RecipeSuggestionStore`。
- Produces: `AppState.growthInsights`、`AppState.candidateRecipes`、`AppState.showGrowthInsights`；`AppService.acceptCandidate(id:)`、`AppService.dismissCandidate(id:)`。

- [ ] **Step 1: AppState 增加发布属性**

```swift
@Published var growthInsights: [GrowthEntry] = []
@Published var candidateRecipes: [CandidateRecipe] = []
@Published var showGrowthInsights = false
```

- [ ] **Step 2: AppService 初始化增加两个 store 成员**（`growthLedgerStore`、`recipeSuggestionStore`，在 `init(paths:)` 中赋值）
- [ ] **Step 3: scanNow 后调用**

```swift
await updateFlowMetrics(snapshots: all)
await updateGrowthInsights(previous: previous, latest: snapshot)
```

- [ ] **Step 4: 实现 updateGrowthInsights 与 accept/dismiss**

```swift
private func updateGrowthInsights(previous: Snapshot?, latest: Snapshot) async {
    let home = NSHomeDirectory()
    let builder = GrowthLedgerBuilder()
    var entries = builder.entries(previous: previous, latest: latest, homeDirectory: home)
    if entries.contains(where: { $0.kind == .unknownSpace }) {
        let lastScan = growthLedgerStore.lastSurfaceScanAt()
        if lastScan == nil || Date().timeIntervalSince(lastScan!) >= 86_400 {
            let roots = SurfaceScanner.defaultRoots(homeDirectory: home)
            let dirs = await Task.detached(priority: .utility) {
                SurfaceScanner().scan(roots: roots)
            }.value
            let prevDirs = growthLedgerStore.surfaceDirectories()
            entries.append(contentsOf: builder.surfaceEntries(
                previous: prevDirs, latest: dirs, homeDirectory: home
            ))
            growthLedgerStore.saveSurface(dirs, scannedAt: Date())
        }
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

func acceptCandidate(id: String) { setCandidateStatus(id: id, status: .accepted) }
func dismissCandidate(id: String) { setCandidateStatus(id: id, status: .dismissed) }

private func setCandidateStatus(id: String, status: CandidateStatus) {
    try? recipeSuggestionStore.setStatus(id: id, status: status)
    state.candidateRecipes = (try? recipeSuggestionStore.load()) ?? []
}
```

- [ ] **Step 5: 构建验证**

Run: `xcodebuild -project PoolProblem/PoolProblem.xcodeproj -scheme PoolProblem -configuration Debug build`
Expected: BUILD SUCCEEDED。

- [ ] **Step 6: 提交**

```bash
git add PoolProblem
git commit -m "feat: wire growth ledger and recipe suggestions into app service"
```

---

### Task 8: 菜单栏面板"增长洞察"卡片 + 明细 sheet

**Files:**
- Create: `PoolProblem/PoolProblem/Views/GrowthInsightsView.swift`
- Modify: `PoolProblem/PoolProblem/Views/MenuBarView.swift`

**界面设计（本任务核心）：**

- 右侧面板在"自动清理计划"卡片之下新增一个"增长洞察"区：有数据时显示 Divider + 标题行（"增长洞察" + "查看"按钮），下方最多列 2 条最近增长：
  - 已知配方项：`配方名 ↑2.3GB`（沿用现有 `state.growthRates` 的箭头风格语义，但数据来自台账）；
  - 未覆盖空间/表面目录：`路径模式 +Δ + "新"徽标`。
  - 点击"查看"或条目 → 弹 sheet `GrowthInsightsView`。
- 无数据时不占空间（`if !state.growthInsights.isEmpty`）。
- `GrowthInsightsView` 分两段：①"增长记录"（最近 20 条：模式 + 增量 + 速率，`unknown://space` 显示为"未覆盖空间"）；②"配方建议"（候选卡片：模式、累计增量、观测次数、建议安全级徽标、"采纳/忽略"按钮；已采纳列表带"移除"）。空态显示"暂未发现异常增长"。

- [ ] **Step 1: 新建 GrowthInsightsView.swift**（SwiftUI List/Form，直接消费 `state.growthInsights`/`state.candidateRecipes`，按钮调 `service.acceptCandidate/dismissCandidate`）
- [ ] **Step 2: MenuBarView 右面板插入卡片 + sheet**

```swift
// rightPanel 内，autoCleanPlan 显示区之后：
if !state.growthInsights.isEmpty || !state.candidateRecipes.isEmpty {
    Divider()
    insightsCard
}
// body ZStack 上：
.sheet(isPresented: $state.showGrowthInsights) {
    GrowthInsightsView(state: state, service: service)
}
```

```swift
private var insightsCard: some View {
    VStack(alignment: .leading, spacing: 6) {
        Button { state.showGrowthInsights = true } label: {
            HStack {
                Text(Localized.string("insights.title"))
                    .font(.caption)
                    .fontWeight(.semibold)
                Spacer()
                Text(Localized.string("insights.view"))
                    .font(.caption2)
                    .foregroundStyle(Color.accentColor)
            }
        }
        .buttonStyle(.plain)
        ForEach(state.growthInsights.prefix(2)) { entry in
            HStack(spacing: 5) {
                Text(entry.kind == .unknownSpace
                     ? Localized.string("insights.unknown_space")
                     : entry.pattern)
                    .font(.caption2)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if entry.kind == .unknownSpace || entry.kind == .surface {
                    Text(Localized.string("insights.new_badge"))
                        .font(.caption2)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 4)
                        .background(RoundedRectangle(cornerRadius: 3).fill(Color.orange))
                }
                Spacer()
                Text(Format.bytes(entry.deltaBytes))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
    }
}
```

- [ ] **Step 3: 构建验证**（xcodebuild，Expected: BUILD SUCCEEDED）
- [ ] **Step 4: 提交**

```bash
git add PoolProblem
git commit -m "feat: show growth insights card and candidate sheet in menu bar panel"
```

---

### Task 9: 设置窗口"候选配方"区（专家模式）

**Files:**
- Modify: `PoolProblem/PoolProblem/Views/SettingsView.swift`

**界面设计：** 在"配方"区之后新增"候选配方"区（仅专家模式显示）：待处理候选每行 = 模式 + 累计增长 + 建议安全级 + "采纳/忽略"按钮；已采纳候选单列一块（模式 + "移除"）。调用 `service.acceptCandidate/dismissCandidate`。

- [ ] **Step 1: 在 expertMode 分支内新增 Section**

```swift
Section(Localized.string("settings.candidates_section")) {
    let pending = state.candidateRecipes.filter { $0.status == .pending }
    if pending.isEmpty {
        Text(Localized.string("insights.empty"))
            .font(.caption)
            .foregroundStyle(.secondary)
    } else {
        ForEach(pending) { candidate in
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(candidate.pattern).font(.caption).lineLimit(1).truncationMode(.middle)
                    Text(Localized.string("candidate.evidence", candidate.evidenceCount) + " · " + Format.bytes(candidate.totalGrowthBytes))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(Localized.string("candidate.accept")) { service.acceptCandidate(id: candidate.id) }
                    .cursorPointingHand()
                Button(Localized.string("candidate.dismiss")) { service.dismissCandidate(id: candidate.id) }
                    .cursorPointingHand()
            }
        }
    }
    let accepted = state.candidateRecipes.filter { $0.status == .accepted }
    if !accepted.isEmpty {
        Divider()
        ForEach(accepted) { candidate in
            HStack {
                Text(candidate.pattern).font(.caption).lineLimit(1).truncationMode(.middle)
                Spacer()
                Button(Localized.string("common.remove")) { service.dismissCandidate(id: candidate.id) }
                    .cursorPointingHand()
            }
        }
    }
}
```

- [ ] **Step 2: 构建验证**（xcodebuild，Expected: BUILD SUCCEEDED）
- [ ] **Step 3: 提交**

```bash
git add PoolProblem
git commit -m "feat: add recipe suggestion management to settings"
```

---

### Task 10: 本地化 keys

**Files:**
- Modify: `PoolProblem/PoolProblem/Localizable.xcstrings`
- Modify: `PoolProblem/PoolProblem/Localized.swift`（如需要安全级/类型显示 helper）

新增 keys（en 源语言 + zh-Hans 翻译）：`insights.title`（Growth Insights / 增长洞察）、`insights.view`（View / 查看）、`insights.unknown_space`（Uncovered space / 未覆盖空间）、`insights.new_badge`（New / 新）、`insights.empty`（No unexpected growth yet / 暂未发现异常增长）、`insights.entries`（Growth Log / 增长记录）、`candidate.section_title`（Recipe Suggestions / 候选配方）、`candidate.accept`（Add / 采纳）、`candidate.dismiss`（Ignore / 忽略）、`candidate.evidence`（%lld observations / %lld 次观测）、`settings.candidates_section`（Recipe Suggestions / 候选配方）。

- [ ] **Step 1: 编辑 xcstrings**（按现有 JSON 结构追加，en 与 zh-Hans 都标 `translated`）
- [ ] **Step 2: 构建验证**（xcodebuild，Expected: BUILD SUCCEEDED；无 MissingString 警告）
- [ ] **Step 3: 提交**

```bash
git add PoolProblem
git commit -m "chore: add localization for growth insights and candidates"
```

---

### Task 11: 全量验证与收尾

- [ ] **Step 1: Core 测试**

Run: `swift test`
Expected: 全部 PASS（含既有测试）。

- [ ] **Step 2: App 构建**

Run: `xcodebuild -project PoolProblem/PoolProblem.xcodeproj -scheme PoolProblem -configuration Debug build`
Expected: BUILD SUCCEEDED。

- [ ] **Step 3: CLI 冒烟（回归）**

Run: `swift run poolproblem status --json`（或既有 CLI 测试覆盖）
Expected: 正常输出，无回归。

- [ ] **Step 4: 自查**：确认新增 UI 文案在 `Localizable.xcstrings` 中无缺失；确认台账只落在 `StoragePaths` 基目录；确认候选状态（accepted/dismissed）跨重启保留。
- [ ] **Step 5: 提交**

```bash
git add .
git commit -m "feat: complete growth ledger and recipe suggestions (L1+L2)"
```

---

## 后续（不在本计划内）

- L3：参与式上报（默认关闭、脱敏模式摘要、提交前预览）。
- L4：本地 AI 生成配方草稿。
- 采纳候选后的"用户配方"接线：把 `accepted` 候选解析为可扫描的 `Recipe`（需扩展 Recipe.resolvePaths 支持模式化路径）。
- 增长洞察通知：新候选跨过阈值时发本地通知（现有 `NotificationCenterService` 可直接复用）。
- `SurfaceScanner` 根目录可配置化；Containers 目录（性能敏感）后续再纳入。
