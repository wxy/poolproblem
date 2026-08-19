# 项目目录监控配方实现计划（增长洞察 → 用户确认 → 监控/清理）

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking。
> 本计划遵循会话内约定：**提交/推送/创建 PR 一律等待用户明确指令**，计划中的 Commit 步骤标注为"待用户指令"。

**Goal:** 从增长洞察与 FSEvents 写活动两个方向交叉发现开发项目目录，提示用户一键确认；确认后将其加入 `Config.devRoots`，由"项目目录"配方族（`category: .project`）监控其中的 `node_modules`/`dist`/`build`/`.build`，并按"最近无修改 + 当前无写活动"双重判定是否建议清理——**只清理可再生子目录，绝不清除项目根**。用户添加的配方与系统内置配方在设置页明确区分。

**Architecture:** 识别与判定全部在 Core：新增 `DevDirectoryDetector`（项目标记浅查）、`DevDirectoryDiscovery`（按可重建大小主动发现）、`DevActivityTracker`（FSEvents 写活动识别：监听家目录，命中 node_modules/.git/dist/build 等名字的事件，记录"项目根 + 最近活动时间"）、`ProjectRecipes.make(devRoots:)`（动态路径配方族）、`UsageProbe.parentAndSelfNewestModified`（node_modules 需自身+上级项目根均无变化才可清理）。App 层负责闭环：三条信号（增长洞察增量、主动发现的大小、FSEvents 写活动）汇入开发目录建议卡 → 用户确认写入 `Config.devRoots`/`declinedDevRoots` → 由 `activeRecipes()` 纳入监控；清理时 RuleEvaluator 额外跳过"最近有写活动"的项目（实时保护，配合 mtime 年龄规则）。设置页将"系统内置配方"与"你添加的项目目录"分区展示，用户配方可移除。

**Tech Stack:** Swift 6、SwiftUI、Swift Testing、现有 `Recipe`/`UsageProbe`/`RuleEvaluator`/`POSIXDirectoryWalker`/`JSONStore`/`GrowthLedgerStore`/`RecipeCoverage`/`RecipeSuggester`。

**Spec:** 本计划即设计文档（2026-08-19 会话确认的方向：从增长洞察生成用户开发目录监控配方；完整产品设计见 `docs/superpowers/specs/2026-08-09-the-pool-problem-design.md`）。

## Global Constraints

- macOS 14+；领域逻辑（识别、路径展开、探测）一律进 `DiskReservoirCore`；App 层只做编排与展示。
- 用户确认是唯一写入 `devRoots` 的途径：自动识别只产生"建议"，绝不自动添加；`declinedDevRoots` 用于避免重复提示。
- 清理判定以"最近是否变化 + 当前无写活动"为准：`node_modules` 使用 `parentAndSelfNewestModified`（自身与上级项目根均无变化才可清理）；`dist`/`build`/`.build`/`.dist` 使用默认目录探针；RuleEvaluator 额外跳过"最近 24 小时有 FSEvents 写活动"的项目。**不做进程判定、不做读取跟踪**（FSEvents 只覆盖写/创建/删除/重命名）。
- **清理粒度 = 可再生子目录**：只清理项目下的 `node_modules`/`dist`/`build`/`.build`/`.dist`，任何情况下都不删除项目根本身。
- 发现信号三路交叉：① 增长洞察增量（基线后新增）；② 主动发现大小（基线前存量）；③ FSEvents 写活动（无标记/新项目、实时活跃）。三者汇入同一张"开发目录建议卡"，来源分别标注。
- 项目配方族按"族"管理（一个配方、多个项目条目），项目在 UI 中以独立行展示，可单独清理；同目录去重；识别粒度到"项目"，不要求统一开发根。
- `Config` 新增字段必须 `decodeIfPresent` 兼容旧配置。
- 提交规范：conventional commits；每任务 `swift test`（Core）/`xcodebuild build`（App）通过后才可提交；提交动作等待用户指令。
- 本计划不做：自动清理（只建议）、低空间主动提醒（后续）、把项目配方并入 L3/L4 上报。

---

## 文件结构

```
Sources/DiskReservoirCore/
├── Models/Config.swift                    # 修改：+devRoots/+declinedDevRoots（兼容解码）
├── Models/UsageProbe.swift                # 修改：+parentAndSelfNewestModified
├── Project/DevDirectoryDetector.swift     # 新增：项目标记启发式
├── Project/ProjectRecipes.swift           # 新增：项目配方族（node-modules / build-output）
├── Scanner/Scanner.swift                  # 修改：parentAndSelf 探针测量
└── Recipes/BuiltInRecipes.swift           # 不改（项目配方独立于内置）

Tests/DiskReservoirCoreTests/
├── ConfigTests.swift                      # 新增：devRoots 编解码
├── DevDirectoryDetectorTests.swift        # 新增
├── ProjectRecipesTests.swift              # 新增
└── ScannerTests.swift                     # 修改：parentAndSelf 探针用例

PoolProblem/PoolProblem/
├── Models/AppState.swift                  # 修改：+pendingDevRoots
├── AppService.swift                       # 修改：activeRecipes()/confirmDevRoot/declineDevRoot/下钻检测
├── Views/GrowthInsightsView.swift         # 修改：开发目录建议卡
├── Views/SettingsView.swift               # 修改：项目目录分区（含移除）
├── Localized.swift                        # 修改（如需）
└── Localizable.xcstrings                  # 修改：新文案（en + zh-Hans）
```

---

### Task 1: Config 增加 devRoots 与 declinedDevRoots

**Files:**
- Modify: `Sources/DiskReservoirCore/Models/Config.swift`
- Test: `Tests/DiskReservoirCoreTests/ConfigTests.swift`

**Interfaces:**
- Consumes: 无。
- Produces: `Config.devRoots: [String]`（用户确认的开发目录）、`Config.declinedDevRoots: [String]`（用户忽略，避免重复提示），均默认 `[]`、旧配置解码为空。

- [ ] **Step 1: 写失败测试**

```swift
@Test func configRoundTripsDevRoots() throws {
    var config = Config.default
    config.devRoots = ["/Users/alice/develop"]
    config.declinedDevRoots = ["/Users/alice/tmp"]
    let encoder = JSONEncoder()
    let data = try encoder.encode(config)
    let decoded = try JSONDecoder().decode(Config.self, from: data)
    #expect(decoded.devRoots == ["/Users/alice/develop"])
    #expect(decoded.declinedDevRoots == ["/Users/alice/tmp"])
}

@Test func configDecodesLegacyWithoutDevRoots() throws {
    let legacy = """
    {"waterlineGB":30,"rules":[],"whitelistPaths":[],"enabledRecipes":[]}
    """
    let config = try JSONDecoder().decode(Config.self, from: Data(legacy.utf8))
    #expect(config.devRoots.isEmpty)
    #expect(config.declinedDevRoots.isEmpty)
}
```

- [ ] **Step 2: 运行确认失败**

Run: `swift test --filter ConfigTests`
Expected: FAIL（字段不存在）。

- [ ] **Step 3: 实现**（属性 + CodingKeys + `decodeIfPresent ?? []`，`default`/`init` 同步补默认值）
- [ ] **Step 4: 运行确认通过**
- [ ] **Step 5: 提交（待用户指令）**

```bash
git add Sources/DiskReservoirCore Tests/DiskReservoirCoreTests
git commit -m "feat: add dev roots and declined dev roots to config"
```

---

### Task 2: DevDirectoryDetector（项目标记启发式）

**Files:**
- Create: `Sources/DiskReservoirCore/Project/DevDirectoryDetector.swift`
- Test: `Tests/DiskReservoirCoreTests/DevDirectoryDetectorTests.swift`

**Interfaces:**
- Consumes: 无（`FileManager` 浅查）。
- Produces: `DevDirectoryDetector.detect(path:) -> DevProjectKind?`；`DevProjectKind`（`.project`）；`DevDirectoryDetector.markers`（标记清单）。

- [ ] **Step 1: 写失败测试**

```swift
@Test func detectsProjectByManifestOrGit() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("pp-dev-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let swift = root.appendingPathComponent("SwiftProj")
    try FileManager.default.createDirectory(at: swift, withIntermediateDirectories: true)
    try Data().write(to: swift.appendingPathComponent("Package.swift"))
    #expect(DevDirectoryDetector.detect(path: swift.path) == .project)

    let node = root.appendingPathComponent("NodeProj")
    try FileManager.default.createDirectory(at: node, withIntermediateDirectories: true)
    try Data().write(to: node.appendingPathComponent("package.json"))
    #expect(DevDirectoryDetector.detect(path: node.path) == .project)

    let git = root.appendingPathComponent("GitOnly")
    try FileManager.default.createDirectory(at: git.appendingPathComponent(".git"), withIntermediateDirectories: true)
    #expect(DevDirectoryDetector.detect(path: git.path) == .project)

    let plain = root.appendingPathComponent("Plain")
    try FileManager.default.createDirectory(at: plain, withIntermediateDirectories: true)
    #expect(DevDirectoryDetector.detect(path: plain.path) == nil)
}

@Test func detectsProjectByRegenerableDir() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("pp-dev2-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let p = root.appendingPathComponent("WithNM")
    try FileManager.default.createDirectory(at: p.appendingPathComponent("node_modules"), withIntermediateDirectories: true)
    #expect(DevDirectoryDetector.detect(path: p.path) == .project)
}
```

- [ ] **Step 2: 运行确认失败**
- [ ] **Step 3: 实现**

```swift
public enum DevProjectKind: String, Sendable, Equatable {
    case project
}

/// 开发目录启发式：浅查（仅首级）项目标记，不做全量遍历。
public enum DevDirectoryDetector {
    /// 文件型标记（存在任一即命中）
    public static let fileMarkers = [
        "Package.swift", "package.json", "Cargo.toml", "go.mod",
        "pyproject.toml", "pom.xml", "build.gradle", "composer.json",
    ]
    /// 目录型标记
    public static let directoryMarkers = [".git", "node_modules"]

    public static func detect(path: String) -> DevProjectKind? {
        let url = URL(fileURLWithPath: path, isDirectory: true)
        let fm = FileManager.default
        for marker in fileMarkers where fm.fileExists(atPath: url.appendingPathComponent(marker).path) {
            return .project
        }
        for marker in directoryMarkers
        where fm.fileExists(atPath: url.appendingPathComponent(marker).path) {
            return .project
        }
        // 允许开发根本身直接含可再生产物（如 ~/develop 下散落项目）
        let children = (try? fm.contentsOfDirectory(atPath: path)) ?? []
        for child in children where child == "dist" || child == "build"
            || child == ".build" || child == ".dist" {
            return .project
        }
        return nil
    }
}
```

- [ ] **Step 4: 运行确认通过**
- [ ] **Step 5: 提交（待用户指令）**

---

### Task 3: UsageProbe.parentAndSelfNewestModified + Scanner 适配

**Files:**
- Modify: `Sources/DiskReservoirCore/Models/UsageProbe.swift`
- Modify: `Sources/DiskReservoirCore/Scanner/Scanner.swift`
- Test: `Tests/DiskReservoirCoreTests/ScannerTests.swift`

**Interfaces:**
- Consumes: 现有测量逻辑。
- Produces: `UsageProbe.parentAndSelfNewestModified`；`Scanner` 对该探针的条目把 `lastModified` 设为 `max(自身目录最新 mtime, 上级目录最新 mtime)`。

- [ ] **Step 1: 写失败测试**（临时目录：父目录内新建一个比子目录更新的文件 → 子目录项 lastModified 应等于父目录的新 mtime）

```swift
@Test func parentAndSelfProbeUsesParentNewest() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("pp-probe-\(UUID().uuidString)", isDirectory: true)
    let project = root.appendingPathComponent("Proj", isDirectory: true)
    let nm = project.appendingPathComponent("node_modules", isDirectory: true)
    try FileManager.default.createDirectory(at: nm, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try Data().write(to: nm.appendingPathComponent("old.bin"))
    Thread.sleep(forTimeInterval: 1.1)
    try Data().write(to: project.appendingPathComponent("new.swift"))  // 上级目录更新
    let recipe = Recipe(
        id: "project-node-modules", name: "NM", category: .project, safety: .userConfirm,
        disposition: .trash, cleanability: .regenerable,
        defaultAgeDays: 30, minimumSizeMB: 100, processName: nil,
        usageProbe: .parentAndSelfNewestModified,
        resolvePaths: { _ in [nm.path] }
    )
    let items = Scanner().rescan(path: nm.path, recipe: recipe, homeDirectory: root.path)
    let selfNewest = (try? FileManager.default.attributesOfItem(atPath: nm.path)[.modificationDate] as? Date) ?? .distantPast
    let parentNewest = (try? FileManager.default.attributesOfItem(atPath: project.path)[.modificationDate] as? Date) ?? .distantPast
    #expect((items.first?.lastModified ?? .distantPast) >= max(selfNewest, parentNewest).addingTimeInterval(-2))
}
```

- [ ] **Step 2: 运行确认失败**
- [ ] **Step 3: 实现**：`Scanner` 在 `rescan`/`scan` 测量完成后，若 `recipe.usageProbe == .parentAndSelfNewestModified`，用 `POSIXDirectoryWalker.walk(父目录, includeRecords: false)` 的 `newest` 与自身 `newest` 取 max 覆盖 `lastModified`（父目录 walk 已含子目录，直接取父目录 newest 亦可；保守起见取 max）。
- [ ] **Step 4: 运行确认通过**
- [ ] **Step 5: 提交（待用户指令）**

---

### Task 4: ProjectRecipes 配方族

**Files:**
- Create: `Sources/DiskReservoirCore/Project/ProjectRecipes.swift`
- Test: `Tests/DiskReservoirCoreTests/ProjectRecipesTests.swift`

**Interfaces:**
- Consumes: `Config.devRoots`、`DevDirectoryDetector`、`Recipe`。
- Produces: `ProjectRecipes.make(devRoots:homeDirectory:) -> [Recipe]`（`project-node-modules`、`project-build-output` 两个配方；resolvePaths 展开各开发根下项目子目录中的可再生产物路径，仅返回存在的路径，去重）。

- [ ] **Step 1: 写失败测试**

```swift
@Test func projectRecipesExpandDevRoots() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("pp-pr-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let dev = root.appendingPathComponent("dev", isDirectory: true)
    let projA = dev.appendingPathComponent("A", isDirectory: true)
    try FileManager.default.createDirectory(at: projA.appendingPathComponent("node_modules"), withIntermediateDirectories: true)
    try Data().write(to: projA.appendingPathComponent("package.json"))
    try FileManager.default.createDirectory(at: projA.appendingPathComponent("dist"), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: dev.appendingPathComponent("B", isDirectory: true), withIntermediateDirectories: true)

    let recipes = ProjectRecipes.make(devRoots: [dev.path], homeDirectory: root.path)
    let ids = recipes.map(\.id)
    #expect(ids.contains("project-node-modules"))
    #expect(ids.contains("project-build-output"))
    let nm = recipes.first { $0.id == "project-node-modules" }
    let nmPaths = nm?.resolvePaths(StoragePaths(baseURL: nil, homeDirectory: root.path)) ?? []
    #expect(nmPaths == [projA.appendingPathComponent("node_modules").path])
    let build = recipes.first { $0.id == "project-build-output" }
    let buildPaths = build?.resolvePaths(StoragePaths(baseURL: nil, homeDirectory: root.path)) ?? []
    #expect(buildPaths.contains(projA.appendingPathComponent("dist").path))
    #expect(!buildPaths.contains(projA.appendingPathComponent("missing").path))
}
```

- [ ] **Step 2: 运行确认失败**
- [ ] **Step 3: 实现**

```swift
public enum ProjectRecipes {
    public static func make(devRoots: [String], homeDirectory: String) -> [Recipe] {
        let paths = devRoots.flatMap { projectPaths(in: $0) }
        return [
            Recipe(
                id: "project-node-modules",
                name: "Project node_modules",
                category: .project,
                safety: .userConfirm,
                disposition: .trash,
                cleanability: .regenerable,
                defaultAgeDays: 30,
                minimumSizeMB: 100,
                processName: nil,
                usageProbe: .parentAndSelfNewestModified,
                resolvePaths: { _ in paths.filter { $0.lastPathComponent == "node_modules" } }
            ),
            Recipe(
                id: "project-build-output",
                name: "Project build output",
                category: .project,
                safety: .userConfirm,
                disposition: .trash,
                cleanability: .regenerable,
                defaultAgeDays: 30,
                minimumSizeMB: 100,
                processName: nil,
                resolvePaths: { _ in
                    paths.filter { ["dist", "build", ".build", ".dist"].contains($0.lastPathComponent) }
                }
            ),
        ]
    }

    /// 开发根下每个项目子目录（含标记）的可再生产物路径，仅返回存在的路径。
    private static func projectPaths(in devRoot: String) -> [String] {
        guard let children = try? FileManager.default.contentsOfDirectory(atPath: devRoot) else { return [] }
        var result: [String] = []
        for child in children {
            let project = URL(fileURLWithPath: devRoot).appendingPathComponent(child).path
            guard DevDirectoryDetector.detect(path: project) != nil else { continue }
            for dir in ["node_modules", "dist", "build", ".build", ".dist"] {
                let candidate = URL(fileURLWithPath: project).appendingPathComponent(dir).path
                if FileManager.default.fileExists(atPath: candidate) {
                    result.append(candidate)
                }
            }
        }
        return result
    }
}
```

> 注意：`devRoot` 本身若被直接识别为项目（散落目录），也需展开——`projectPaths` 先检测 `devRoot` 自身，命中则把 `devRoot` 视为一个项目。实现时补充该分支。

- [ ] **Step 4: 运行确认通过**
- [ ] **Step 5: 提交（待用户指令）**

---

### Task 5: AppService 集成（activeRecipes + 确认/忽略闭环）

**Files:**
- Modify: `PoolProblem/PoolProblem/AppService.swift`
- Modify: `PoolProblem/PoolProblem/Models/AppState.swift`

**Interfaces:**
- Consumes: `ProjectRecipes`、`DevDirectoryDetector`、`Config.devRoots`。
- Produces: `AppService.activeRecipes()`（内置 + 项目配方）；`AppService.confirmDevRoot(_:)`/`declineDevRoot(_:)`；`AppState.pendingDevRoots: [DevRootCandidate]`；`DevRootCandidate`（path、marker、growthBytes）。

- [ ] **Step 1: activeRecipes() 并替换所有使用 `RecipeRegistry.builtIn()` 的扫描/过滤/建议点**（scanNow、runIncrementalScan、updateGrowthInsights、updateIncrementalInsights、drillDownUnknownSpace、startWatching、refreshGaugeImage 等）

```swift
private func activeRecipes() -> [Recipe] {
    RecipeRegistry.builtIn()
        + ProjectRecipes.make(devRoots: loadConfig().devRoots, homeDirectory: NSHomeDirectory())
}
```

- [ ] **Step 2: 下钻后检测未覆盖目录是否为开发目录，产生 pendingDevRoots**

```swift
// drillDownUnknownSpace 末尾（uncoveredInsights 之后）：
let known = Set(loadConfig().devRoots + loadConfig().declinedDevRoots)
let devCandidates = state.unknownDrillDown
    .map(\.path)
    .compactMap { path -> DevRootCandidate? in
        guard !known.contains(path),
              DevDirectoryDetector.detect(path: path) != nil else { return nil }
        return DevRootCandidate(path: path, marker: DevDirectoryDetector.detect(path: path)?.rawValue ?? "project", growthBytes: state.unknownDrillDown.first { $0.path == path }?.deltaBytes ?? 0)
    }
state.pendingDevRoots = Array(devCandidates.prefix(3))
```

- [ ] **Step 3: 确认/忽略**

```swift
func confirmDevRoot(_ path: String) {
    var config = loadConfig()
    guard !config.devRoots.contains(path) else { return }
    config.devRoots.append(path)
    config.declinedDevRoots.removeAll { $0 == path }
    writeConfig(config)
    state.pendingDevRoots.removeAll { $0.path == path }
}

func declineDevRoot(_ path: String) {
    var config = loadConfig()
    if !config.declinedDevRoots.contains(path) {
        config.declinedDevRoots.append(path)
    }
    writeConfig(config)
    state.pendingDevRoots.removeAll { $0.path == path }
}
```

- [ ] **Step 4: AppState 增加 `@Published var pendingDevRoots: [DevRootCandidate] = []`**（`DevRootCandidate: Identifiable`，id=path）
- [ ] **Step 5: 构建验证**（xcodebuild，Expected: BUILD SUCCEEDED）
- [ ] **Step 6: 提交（待用户指令）**

---

### Task 6: 增长洞察"开发目录建议"卡

**Files:**
- Modify: `PoolProblem/PoolProblem/Views/GrowthInsightsView.swift`
- Modify: `PoolProblem/PoolProblem/Localizable.xcstrings`

**界面设计：** 在候选配方区上方新增"开发目录建议"区（有 `pendingDevRoots` 时显示）：每张卡 = 路径（脱敏显示）+ 检测到的标记 + 增长量 + [加入监控][忽略]。加入后下次扫描起该目录的 `node_modules/dist/build` 进入已知监控与清理建议。

- [ ] **Step 1: 实现 devRootSection**（ForEach `state.pendingDevRoots`，按钮调 `service.confirmDevRoot/declineDevRoot`）
- [ ] **Step 2: 本地化 keys**：`devroot.section_title`（开发目录建议 / Suggested dev directories）、`devroot.add`（加入监控 / Add to monitoring）、`devroot.ignore`（忽略 / Ignore）、`devroot.marker`（检测到 %@ / Detected %@）
- [ ] **Step 3: 构建验证**
- [ ] **Step 4: 提交（待用户指令）**

---

### Task 7: 设置页"你添加的项目目录"分区

**Files:**
- Modify: `PoolProblem/PoolProblem/Views/SettingsView.swift`
- Modify: `PoolProblem/PoolProblem/Localizable.xcstrings`

**界面设计：** 配方区之后新增"你添加的项目目录"区：列出 `config.devRoots`（每项显示路径 + [移除]），空态提示"在增长洞察中发现开发目录后可一键加入"；忽略列表可查看并恢复。

- [ ] **Step 1: 实现 devRootsSection**（读取 `config.devRoots`，移除走 `service` 写回；`service` 增加 `removeDevRoot(_:)`）
- [ ] **Step 2: 本地化 keys**：`settings.devroots_section`（你添加的项目目录 / Your dev directories）、`settings.devroots_empty`（在增长洞察中确认开发目录后会自动出现在这里 / Dev directories you confirm in Growth Insights will appear here）
- [ ] **Step 3: 构建验证**
- [ ] **Step 4: 提交（待用户指令）**

---

### Task 8: FSEvents 写活动识别（DevActivityTracker）与清理保护

**Files:**
- Create: `Sources/DiskReservoirCore/Project/DevActivityTracker.swift`
- Modify: `PoolProblem/PoolProblem/AppService.swift`（启动家目录活动监听、建议卡来源、清理保护）
- Modify: `PoolProblem/PoolProblem/Models/AppState.swift`（`DevRootSource.activity`）
- Modify: `PoolProblem/PoolProblem/Views/GrowthInsightsView.swift`（活动来源标签）
- Modify: `Sources/DiskReservoirCore/Cleaner/RuleEvaluator.swift`（可选 `recentlyActiveProjectRoots` 跳过）
- Test: `Tests/DiskReservoirCoreTests/DevActivityTrackerTests.swift`

**Interfaces:**
- Consumes: `FSEventMonitor`（家目录监听）、`POSIXDirectoryWalker`（不需要，仅字符串过滤）。
- Produces: `DevActivityTracker.record(eventPaths:at:) -> [DevActivity]`、`activeProjects(since:) -> [DevActivity]`；`DevActivity`（projectRoot、artifact、lastActivityAt）。

- [ ] **Step 1: 写失败测试**

```swift
@Test func activityTrackerRecordsProjectRoots() {
    let tracker = DevActivityTracker()
    let now = Date()
    let activities = tracker.record(eventPaths: [
        "/Users/alice/develop/A/node_modules/pkg/x.js",
        "/Users/alice/develop/B/.git/HEAD",
        "/Users/alice/Documents/C/package.json",
    ], at: now)
    let roots = Set(activities.map(\.projectRoot))
    #expect(roots.contains("/Users/alice/develop/A"))
    #expect(roots.contains("/Users/alice/develop/B"))
    #expect(roots.contains("/Users/alice/Documents/C"))
}

@Test func activityTrackerFiltersByWindow() {
    let tracker = DevActivityTracker()
    tracker.record(eventPaths: ["/Users/alice/dev/P/node_modules/a"], at: Date().addingTimeInterval(-48 * 3600))
    tracker.record(eventPaths: ["/Users/alice/dev/Q/node_modules/a"], at: Date())
    #expect(tracker.activeProjects(since: 24 * 3600).map(\.projectRoot) == ["/Users/alice/dev/Q"])
}
```

- [ ] **Step 2: 运行确认失败**
- [ ] **Step 3: 实现**：`DevActivityTracker`（`NSLock` 保护；`record` 从事件路径链上找最深命中的可再生产物名，项目根 = 其父目录；`activeProjects(since:)` 只返回窗口内记录）

```swift
public struct DevActivity: Sendable, Equatable {
    public let projectRoot: String
    public let artifact: String
    public let lastActivityAt: Date
}

public final class DevActivityTracker: @unchecked Sendable {
    public static let artifactNames = [
        "node_modules", ".git", "dist", "build", ".build", ".dist",
        "package.json", "Package.swift", "Cargo.toml", "go.mod",
        "pyproject.toml", "pom.xml", "build.gradle",
    ]
    private let lock = NSLock()
    private var byRoot: [String: DevActivity] = [:]
    public init() {}

    @discardableResult
    public func record(eventPaths: [String], at date: Date = Date()) -> [DevActivity] {
        var changed: [DevActivity] = []
        lock.lock(); defer { lock.unlock() }
        for path in eventPaths {
            guard let root = projectRoot(for: path) else { continue }
            let activity = DevActivity(projectRoot: root, artifact: lastArtifactComponent(path), lastActivityAt: date)
            if let old = byRoot[root] {
                if old.lastActivityAt < date { byRoot[root] = activity }
            } else {
                byRoot[root] = activity
            }
            changed.append(byRoot[root]!)
        }
        return changed
    }

    public func activeProjects(since: TimeInterval) -> [DevActivity] {
        let cutoff = Date().addingTimeInterval(-since)
        lock.lock(); defer { lock.unlock() }
        return byRoot.values.filter { $0.lastActivityAt >= cutoff }
            .sorted { $0.lastActivityAt > $1.lastActivityAt }
    }

    private func projectRoot(for path: String) -> String? {
        var current = URL(fileURLWithPath: path)
        while current.path != "/" {
            let name = current.lastPathComponent
            if Self.artifactNames.contains(name) {
                return current.deletingLastPathComponent().path
            }
            current = current.deletingLastPathComponent()
        }
        return nil
    }

    private func lastArtifactComponent(_ path: String) -> String {
        let comps = path.split(separator: "/").map(String.init)
        return comps.last { Self.artifactNames.contains($0) } ?? ""
    }
}
```

- [ ] **Step 4: AppService 接线**：新增一个监听家目录的 `FSEventMonitor`（FileEvents），回调 → `devActivityTracker.record`；`activeDevProjects` 暴露给建议卡与清理保护；`DevRootSource` 增加 `.activity`（标签"近期活跃"）
- [ ] **Step 5: 清理保护**：`RuleEvaluator.evaluate` 增加可选参数 `recentlyActiveProjectRoots: Set<String>`——项目配方条目若其父目录在集合内，返回跳过；`smartClean`/自动清理传入 `devActivityTracker.activeProjects(since: 24h)` 的项目根集合
- [ ] **Step 6: 构建验证**
- [ ] **Step 7: 提交（待用户指令）**

---

### Task 9: 全量验证

- [ ] **Step 1: Core 测试**：`swift test` 全部通过（含新增）。
- [ ] **Step 2: App 构建 + 启动冒烟**（临时数据目录，stderr 干净）。
- [ ] **Step 3: 自查**：`activeRecipes()` 覆盖所有内置配方使用点；确认/忽略不重复提示；`parentAndSelfNewestModified` 在 `RuleEvaluator` 年龄规则下正确阻断活跃项目；用户配方与内置配方在设置页分区展示。
- [ ] **Step 4: 提交（待用户指令）**

---

## 后续（不在本计划内）

- 低空间主动提醒（"N 个项目 node_modules 超 30 天未使用，可释放约 X GB"）。
- 自动识别结果批量确认页（多开发目录一次处理）。
- 项目配方参与 L3 上报（脱敏模式摘要）。
