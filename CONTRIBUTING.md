# Contributing / 贡献指南

欢迎为 **The Pool Problem** 贡献代码、文档或想法。

## 环境 / Environment

- macOS（应用与 CLI 均以 macOS 为目标）
- Swift 6 / Xcode（应用工程在 `PoolProblem/PoolProblem.xcodeproj`）

## 构建与测试 / Build & Test

```bash
swift build        # 构建 CLI 与核心库
swift test         # 运行全部测试
```

应用（Debug）：

```bash
xcodebuild -project PoolProblem/PoolProblem.xcodeproj -scheme PoolProblem -configuration Debug -derivedDataPath .build/xcode-derived build
open .build/xcode-derived/Build/Products/Debug/PoolProblem.app
```

## 提交流程 / Workflow

1. Fork 本仓库，基于 `main` 创建功能分支；
2. 提交前先签署 [CLA](CLA.md)：把 GitHub 用户名添加到 `.github/CLA_SIGNERS`（每行一个，签署后长期有效）；
3. 提交 Pull Request（模板见 `.github/PULL_REQUEST_TEMPLATE.md`）；
4. CI 的 `CLA` 状态检查通过后即可合并。

## 代码约定 / Conventions

- Swift，遵循现有代码风格与结构；
- 用户可见文案：App 走 `Localized.swift` / `Localizable.xcstrings`（中英双语），CLI 走 `CLILocalized.swift`；
- JSON 输出保持英文 key（机器接口），不要本地化；
- 新增功能尽量附带测试（`swift test` 需全部通过）。

## 清理目标准入纪律 / Cleanup Target Admission（必读）

本产品是**持续性的异常增长监控与回收工具**，不是全面清理器。以下纪律约束一切「清理 / 监视 / 建议」目标的准入，来源见 [docs/superpowers/plans/2026-09-24-mole-informed-improvements.md](docs/superpowers/plans/2026-09-24-mole-informed-improvements.md) 与 [docs/product-principles.md](docs/product-principles.md)。

### 新增扫描根 / 配方 / 监视条目的准入清单

每一项都必须同时满足，缺任何一项就降级为只做归因命名（`AttributionCatalog`）或拒绝：

1. **增长证据门槛**：引用增长台账实测数据或明确的跳变形态预期——持续型 ≥ 2GB/30 天，或跳变型 7 天内 ≥ 1GB。缓慢增长、幅度很小、一次性增长后长期静止的目标**不做关注**（现有「不关注清单」：conda pkgs、Maven/NuGet、统一日志、iOS 固件、IB Support——剔除理由见 `AttributionCatalog` 注释）。
2. **实测值**：真实机器上实测可回收/监视字节数。
3. **non-target 清单**：明确写出同级不清理什么、为什么（参考 `PackageManagerRecipes.defaultPaths` 的注释与测试）。
4. **恢复契约分级**：可再生存储 → 清理配方（三级安全）；下载即资产 → `watchOnly`；混合态/owner 管理 → 只归因或只监视。**按恢复契约分类，不按目录名分类**（反例：LM Studio 曾把整个用户目录放在 `.cache` 里）。
5. **fixture 测试**：语义锁进测试（如 watchOnly 在 suggest/clean 输出零出现）。

### 进程与超时纪律

- 进程探测是三态的（运行 / 未运行 / **未知**），**未知 = 拒绝清理**（fail-closed），全库只允许一个翻译点（`ProcessGuard`）。
- 探测超时产生的部分清单**不得流入删除循环**；输出「partial + 跳过原因」。
- 回收站移动不等于释放空间；只有永久删除并复测容量才计入 `actualFreedBytes`。

### 禁区清单（任何情况下不得删除或建议删除）

- `/Library/Updates`、`/macOS Install Data`（Software Update 暂存区——年龄与进程证据无法证明它不活跃）；
- PowerLog 数据库（`/private/var/db/powerlog`）及任何活跃 SQLite 数据库；
- 一切 `com.apple.*` 系统组件与其容器（只读归因可以，删除不行）；
- `AttributionCatalog` 中 asset 层条目（设备备份、模型权重、虚拟盘——下载即资产）；
- 用户添加路径（`Config.watchRoots` / `devRoots` / `packageManagerCacheRoots` 之外的采纳建议路径永不静默升级为可清理）。

### 许可证边界

参考外部项目时只吸收**路径事实与机制思想**（如 Mole 的 owner-command、tri-state 进程守卫），不迁移任何代码；外部源码克隆用完即删，不留在工作区。

## 行为准则 / Code of Conduct

保持友善、尊重与建设性。技术讨论对事不对人。
