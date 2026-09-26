# Mole 经验吸收与改进方案（The Pool Problem）

> 日期：2026-09-24。前置研究：[docs/research/2026-09-24-mole-lessons.md](../../research/2026-09-24-mole-lessons.md)（Mole 知识库对照报告）。
> 修订：2026-09-24 v2 —— 吸收评审意见：确立**增长证据门槛**原则，据此修剪扫描根/监视清单/配方扩容；拍板三个决策点（DeviceSupport 保持保留 1 个；watchOnly 上水位面板需先做布局设计；ownerCommand 采纳）。

**Goal:** 把 Mole 的「哪里会藏东西」知识库转译为我们的**归因与监视能力**，把它的安全纪律固化进**准入制度**；配方清理面只做与其安全模型匹配的**选择性扩容**。不变成另一个 Mole。

**定位声明（v3）：** 我们的定位不是一个全面的磁盘空间清理器，而是一个对**异常增长、反复增长的磁盘占用**进行**监控与回收**的工具——是一个**持续性**的工具，不是一次性工具。据此：本方案的一切能力都围绕「持续观察 → 识别异常 → 解释原因 → 授权后回收」这条链路；一次性清理动作（批量缓存清单、卸载器等）全部留在边界外。反复增长（清理后回涨）的识别尤其重要——它正是我们 Flow 层 rebound 分析的主场。

**产品契约符合性：** 本方案遵循 [docs/product-principles.md](../product-principles.md) 现行契约：增长只改变排序不改变资格；增长发现保持**显式二次动作**（AttributionCatalog 只在用户触发增长发现时参与匹配，不进默认五分钟循环）；健康态零递归扫描不受影响；watchOnly 条目展示只读缓存态，打开弹层永不触发扫描。

**Architecture 原则：** 我们是常驻守护器（预测 / 归因 / 授权后清理），Mole 是交互式一次性清理器。Mole 把知识库直接做成「清理目标清单」；我们把同样的知识做成「**归因知识库 + 建议管道**」，清理只发生在用户明确采纳之后。所有改动复用现有扩展点：`SurfaceScanner.defaultRoots`、`Recipe` 模型、`RecipeSuggester` 识别管道、`Cleanability` 分级。

---

## 0. 决策过滤器（先立规矩）

每个候选借鉴点过这五问，任何一问「否」就丢弃或降级为只读：

1. **服务于守护吗？** 它是否改进「发现增长 / 归因命名 / 满盘预测 / 水线决策」？仅增加「一次性清理能力」的不做。
2. **增长显著吗？（v2 新增，成本闸门）** 缓慢增长与增长幅度很小的目标**先不做关注**：不为它们新增扫描根、配方或监视条目。理由：归因命名只对已有表面条目做匹配，零边际成本；而每个新扫描根/配方都是分析期的一次全量遍历，且扩大处方面增加程序复杂度。晋升由增长台账的证据驱动（见 §0.1），不靠预先枚举。
3. **匹配恢复契约吗？** 目标是可再生存储（可入清理集）、还是下载即资产（只监视）、还是混合态（排除）。按契约分类，不按目录名。
4. **有实测值吗？** 新清理目标必须附真实机器实测可回收字节 + **non-target 清单**（同级明确不清理什么、为什么）。没有实测值的先只做归因/监视。
5. **我们有界面承接吗？** 借鉴点必须落进现有面板（水位面板 / 增长洞察 / 设置 / 通知），不为它新开交互模式。

### 0.1 增长证据门槛（晋升规则）

复用设计文档既有的增长警报阈值体系，作为「值得投入关注」的统一门槛：

- **持续型**：30 天绝对增长 ≥ 2GB，或相对增长 ≥ 50%（且 ≥ 500MB）；
- **跳变型**：单次观测增量 ≥ 1GB（模型下载、设备备份、虚拟盘扩容、安装包落地都属于此类）。

证据来自 GrowthLedger 既有记录，**不需要任何额外扫描**。低于门槛的目标保持在 L1 归因命名层（甚至不进归因表），达到门槛才由建议管道提出晋升（L1 → L2 监视 → L3 清理建议），用户采纳后生效。

**由此推导的反目标（本方案不做，等同产品边界声明）：**

- ❌ 应用卸载器 / 残留清扫（`mo uninstall` 域）
- ❌ 系统维护优化（DNS 刷新、icon 重建、数据库 vacuum，`mo optimize` 域）
- ❌ 磁盘浏览器 TUI / 全盘映射（`mo analyze` 域）
- ❌ CPU/网络/健康分状态面板（`mo status` 域）
- ❌ 把 Mole 的 150 个 App 缓存清单整体搬成自动清理目标——它们首先是**归因知识**
- ❌ 安装包批量清理命令——我们只做「安装包落地」的归因提示
- ❌ 为缓慢/小幅增长目标建配方或监视条目（v2 新增）：conda pkgs、Maven/NuGet 本地仓库、统一日志、IB Support 等，仅保留为归因表中的「已知项」，无独立扫描成本

## 1. 核心转译：知识库 → 三层结构

| 层 | 语义 | 实现载体 | 默认动作 |
| --- | --- | --- | --- |
| L1 归因命名 | 「这 5GB 是什么」 | 表面条目 + `AttributionCatalog` 识别表（零扫描成本） | 计入增长台账，有名字 |
| L2 监视清单 | 「它在显著增长，但永远不归我清」 | 新 `Cleanability.watchOnly` 配方 | 展示体积与增速，永不产生清理候选 |
| L3 清理配方 | 「可清理，且分级明确」 | 现有 `Recipe`（三级安全） | 按既有水线/规则引擎走 |

### 1.1 L1 归因命名（零扫描成本，立即有价值）

**SurfaceScanner 根扩充**（`Growth/SurfaceScanner.swift`）——按增长证据原则修剪后只加两处：

```text
~/Library/Group Containers        # OrbStack 等虚拟盘（开发期增长快）
~/go                              # Go module 缓存默认位置（活跃开发期增长快）
```

**剔除与理由**（v2）：`~/.conda` 与 anaconda/miniconda/miniforge/mambaforge 五处 pkgs（缓慢增长）、`~/Library/iTunes` 固件缓存（每台设备一次性数 GB 后长期静止，收益不大）、`~/Library/Mobile Documents`（废纸篓已由 `trash` 配方覆盖，Drive Downloads 归 P2 安装包落地归因）。

**具名识别表**（新文件 `Growth/AttributionCatalog.swift`）：纯数据表，`路径模式 → (展示名, 层别)`。**只对表面扫描已产出的条目做匹配，零额外遍历**。首批条目：国产 IM 六个、Electron 缓存家族（`DawnCache`/`GraphiteCache`/`Code Cache`…）、浏览器旧版本目录、`MobileSync/Backup`、conda pkgs、`IB Support`。归因结果经 `GrowthInsightMerger` 展示为「微信缓存 · 12.3GB · +400MB/天」。

**具名下钻**：对命中识别表的一级子目录（如 App Support 下的 `Slack`、`iDingTalk`、`com.tencent.xinWeChat`）才展开一层定位缓存子目录；不做全量二级扫描。

### 1.2 L2 监视清单（watchOnly，按增长证据修剪）

**模型改动**：`Cleanability` 增加 `.watchOnly`——参与扫描、归因、增长台账与满盘预测；`RecipeSuggester` 与水线清理引擎**硬排除**（回归测试锁定：watchOnly 配方永远不出现在 suggest/clean 输出中）。`Category` 增加 `.asset`（下载即资产：备份/模型权重/虚拟盘）。

**首批监视配方**——只保留「跳变型或持续型增长都显著」的四项：

| 配方 | 路径 | 增长形态 |
| --- | --- | --- |
| iOS 设备备份 | `~/Library/Application Support/MobileSync/Backup` | 设备备份时 GB 级跳变 |
| Docker Desktop 数据 | `~/Library/Containers/com.docker.docker/Data` | 容器活跃期持续快涨，Docker.raw 只增不减 |
| OrbStack / Lima / Colima | Group Containers `*dev.orbstack`、`~/.lima`、`~/.colima` | 同上 |
| 本地大模型 | `~/.ollama/models`、`~/.lmstudio/models` | 下载时 GB 级跳变 |

**移入「不关注清单」**（v2）：conda pkgs、Maven/NuGet 仓库（缓慢）、统一日志（缓慢）、iOS 固件缓存（一次性后静止）。它们保留在 AttributionCatalog 里作为已知项，满足晋升门槛时由建议管道提出，再考虑升级。

**TM 本地快照计数**（`tmutil listlocalsnapshots /`，只读）进 `status` 输出与满盘预测脚注：**「已删文件但可用空间未回升」的解释器**——守护器本职，零删除语义。

### 1.3 L3 清理配方扩容（带准入纪律，按增长证据修剪）

**Xcode 缺口**（决策点 1 已拍板：DeviceSupport 保留策略**维持现状 1 个**，不做 keep-N）：

- `xcode-devicesupport` 配方仅**扩展 tvOS 根**（路径不存在的机器零成本，`minimumSizeMB` 自过滤）；
- 新配方：CoreDevice 服务缓存 `Containers/com.apple.CoreDevice.CoreDeviceService/Data/Library/Caches`——真机重度调试可 GB 级；userConfirm、进回收站、30 天；
- **IB Support 不建配方**（v2：增长缓慢且幅度小），仅保留归因命名。

**包管理器配方族扩容**——全部为活跃开发期增长显著的缓存，逐个过「恢复契约」闸门（non-target 清单写在配方注释与测试里）：

| 工具 | 路径 | 层别 | 依据 |
| --- | --- | --- | --- |
| Go 构建缓存 | `~/.cache/go-build` | L3，safeWhileRunning 永久删 | 纯再生，活跃期快涨 |
| Go module | `~/go/pkg/mod` | L3，**优先 owner 命令** | owner 文档化重置 |
| Gradle | `~/.gradle/caches` | L3，processName `gradle` 守卫 | daemon 常驻数小时 |
| Cargo | 仅 `~/.cargo/registry/cache` | L3 | **non-target：`registry/src` 混合态，明确排除** |
| Yarn/bun | `~/.yarn/berry/cache`、`~/.bun/install/cache` | L3 | 纯下载缓存 |

### 1.4 ownerCommand（已拍板采纳）

`Recipe` 增加可选字段 `ownerCommand: OwnerCommand?`（可执行文件名 + 参数 + 工具存在性探测）。清理引擎语义：

1. owner 命令可用 → 执行它（遵守工具自己的锁与代际，如 `uv cache prune`、`pnpm store prune`、`go clean -modcache`）；
2. owner 不可用 → 按配方 `disposition` 走原路径删除；
3. 两者都不可用 → 跳过并给出原因。

复用 `ProcessInspecting` 协议抽象保证可测试。`actualFreedBytes` 复测照常（决策点 3：量规实测以空间变化为准，owner 命令失败/超时自然反映在复测里）。工程成本评估：`PackageManagerRecipes` 聚合多路径于一个配方，先做「路径前缀 → owner 命令」映射的聚合方案，确需拆分时保持 familyID 与本地化键稳定。

### 1.5 建议管道升级（RecipeSuggester，接入晋升门槛）

现有识别只有两类：项目族、`~/.cache/<工具>`。升级为：

- 命中 `AttributionCatalog` 的 L3 型条目 → 生成「加入包管理器族」建议（现行模式）；
- 命中 L2 型条目且**增长记录达到 §0.1 门槛** → 生成「纳入监视」建议，采纳后进用户自定义 watchOnly 列表——用户添加路径保持 manual/watchOnly，绝不静默升级为自动清理；
- 未达门槛的条目只做归因展示，不产生建议。

### 1.6 P2 探索项（有明确触发条件才启动）

- **安装包落地归因**：>500MB 的 DMG/PKG 落入 Downloads / Telegram 接收目录 → 跳变型增长归因（符合 §0.1）。只归因；是否提供一键进回收站由界面评审另定。
- **水位面板 watchOnly 布局**（决策点 2）：水位面板显示的是「空闲 + 值得清理的部分」，不是全盘，watchOnly 条目多时没有展示机会。**先做布局设计 spike，不直接实现**。候选方向：(a) 条目列表区仅在 watchOnly 项「近期增长超 §0.1 门槛」时出现带雷达图标的行，默认隐藏；(b) 仅进详情页；(c) 异常增长通知承载。产出 mockup 评审后再定。
- **僵尸进程信号**：`ps` 统计 stat 含 `Z` 的进程并归因父进程 → 通知「自动化浏览器可能泄漏」；判据沿用实测教训：profile 目录 + ppid=1 才算泄漏，守护进程本身 ppid=1 是正常态。临时产物配方补「存在活跃 playwright 会话则跳过」守卫。
- **Chromium 旧版本归因**：仅命名（「Chrome 更新残留 ×3 版本」），不建议清理——更新器语义各家不同，证据不足不动手。

## 2. 纪律固化（写入 CONTRIBUTING，不写代码）

1. **增长证据门槛**：新扫描根/配方/监视条目必须引用增长台账证据或明确的跳变形态预期；缓慢/小幅增长目标不投入。
2. **新清理目标准入**：附实测可回收字节 + non-target 清单 + 安全分级理由 + fixture 测试。缺一项就降级为 watchOnly 或拒绝。
3. **进程守卫三态**：审计 `ProcessGuard` 全部调用点——探测「未知」必须等于「拒绝」（fail-closed），全库只允许一个翻译点。
4. **超时纪律**：探测超时产生的部分清单**不得流入删除循环**；输出「partial + 跳过原因」。
5. **禁区清单**（设计文档成文并测试锁定）：`/Library/Updates`、`/macOS Install Data`、PowerLog 数据库、一切 `com.apple.*` 系统组件。
6. **许可证红线**：Mole 为 GPL-3.0，只吸收路径事实与思想，不迁移任何代码；调研克隆用完即删。

## 3. 实施阶段

### M-A 归因与监视（P0，无删除行为变更，零边际扫描成本）

- [ ] `SurfaceScanner.defaultRoots` 增加 Group Containers 与 `~/go` 两处 + 测试
- [ ] `Cleanability.watchOnly` + `Category.asset` + 引擎/建议器硬排除 + 测试锁定
- [ ] `AttributionCatalog.swift` 识别表（含下钻与「已知不关注项」）+ GrowthInsightMerger 展示接入
- [ ] 首批 4 个 watchOnly 配方注册
- [ ] TM 快照只读探测接入 status 与满盘预测
- [ ] App 增长洞察面板展示归因命名与 watchOnly 条目（体积/增速，无清理按钮）

### M-B 配方扩容与 owner 命令（P1）

- [ ] `xcode-devicesupport` 扩 tvOS 根（保留策略不变）；CoreDevice 缓存新配方
- [ ] 包管理器族扩容（Go/Gradle/Cargo/Yarn/bun，逐条 non-target 清单）
- [ ] `ownerCommand` 机制 + 三条降级语义 + 测试（工具存在/缺失/超时）
- [ ] RecipeSuggester 接入 AttributionCatalog 与 §0.1 晋升门槛
- [ ] CONTRIBUTING 准入纪律（含增长证据门槛）与禁区清单成文

### M-C 归因增强（P2，逐项评审触发）

- [ ] 水位面板 watchOnly 布局设计 spike → mockup 评审
- [ ] 安装包落地归因
- [ ] 僵尸进程信号 + playwright profile 守卫
- [ ] Chromium 旧版本命名归因

## 4. 验收标准

- watchOnly 配方在 `suggest` / `clean` JSON 输出中零出现（回归测试锁定）。
- **增长门槛生效**：未达 §0.1 门槛的条目不产生建议（测试锁定）。
- 新增配方全部携带 fixture 测试 + non-target 清单注释；`swift test` 全绿。
- M-A 落地后分析期遍历的根数量仅 +2（成本预算约束）。
- 满盘预测对「删后不回升」场景给出快照解释（status 可见）。
- 现有三级安全、诚实计量（`actualFreedBytes`）语义零回归。

## 5. 风险与对策

| 风险 | 对策 |
| --- | --- |
| 扫描成本随知识库扩张失控 | §0.1 增长证据门槛作为硬约束：只有显著增长目标才获得扫描根/配方；归因命名保持零边际成本 |
| Group Containers 权限拒绝 | 无权限根静默跳过（与 Containers 现状一致），FDA 引导文案补充说明 |
| 包管理器族拆配方导致 UI 回归 | 先做「路径前缀 → owner 命令」映射的聚合方案；确需拆分时保持 familyID 与本地化键稳定 |
| watchOnly 条目淹没水位面板 | M-A 只进增长洞察面板；水位面板展示待 M-C 布局 spike 结论 |
| 知识库变成维护负担 | AttributionCatalog 只收有实测证据的条目；「不关注清单」显式记录剔除理由，避免重复讨论 |

## 6. 决策点（已全部拍板，v3）

1. DeviceSupport 默认保留数：**维持现状 1 个**，只扩 tvOS 根，无行为变更。
2. watchOnly 上水位面板：**先做布局设计 spike**（M-C 首项），M-A 期间只进增长洞察面板。
3. `ownerCommand`：**采纳**；失败/超时自然反映在 `actualFreedBytes` 复测中。

## 7. 工作方式（v3）

- 每完成方案中的一个条目即做一个提交（conventional commits，`swift test` 全绿才提交）。
- 现存 WIP（压力状态机、ScanWorkloadGate、TemporaryBuildArtifacts、product-principles 等 36 文件）先打包为一个基线提交；本方案的实施提交全部叠加其后。
- M-A 走 feature 分支 `feat/attribution-watchlist`，M-B 走 `feat/recipe-expansion-owner-command`，各自形成 PR；最终以 PR 形式推送。
