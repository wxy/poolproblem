# The Pool Problem（蓄水池问题）

> 你的磁盘，就是那道经典的蓄水池问题——进水管、出水管、水位、什么时候会满。The Pool Problem 负责把它解出来。

面向开发者的磁盘"归因与治理"工具：测量各产废源（Xcode 构建产物、模拟器快照、包管理器缓存等）的流速，预测磁盘何时会满，追踪清理后空间为何回涨，并在源头治理——让可用空间稳定在健康水位。

## 当前状态

- ✅ M1 Core（SwiftPM 库 `DiskReservoirCore`）：配方库、扫描器（含硬链接去重的诚实计量）、快照存储、流量分析（归因/回涨/增长警报）、满盘预测、规则评估、进程检测、文件删除、水线清理引擎（含量规实测 `actualFreedBytes`）
- ✅ M2 CLI（`poolproblem`）：`scan` / `suggest` / `clean` / `status`，稳定 JSON 输出
- ✅ M3 App（SwiftUI 菜单栏）：蓄水池水位面板（E 字型水位标尺、天空主读数、分层水位）、智能清理、傻瓜/专家设置、通知、完全磁盘访问引导、开机自启、自定义状态栏水位图标、弹簧动效与无障碍适配
- ⏳ M4 小组件 —— 暂缓
- ✅ M5 打包 —— v1.0.0（DMG + Apple 公证，GitHub Releases 分发）

## 安装

从 [GitHub Releases](https://github.com/wxy/poolproblem/releases/latest) 下载 `PoolProblem-1.0.0.dmg`：

- DMG 已通过 **Apple 公证**（Developer ID 签名 + Hardened Runtime），下载后可直接打开；
- 打开 DMG，把 `PoolProblem.app` 拖入 Applications 即可。

## App（macOS 菜单栏）

构建并运行（Xcode 工程在 `PoolProblem/PoolProblem.xcodeproj`）：

```bash
xcodebuild -project PoolProblem/PoolProblem.xcodeproj -scheme PoolProblem -configuration Debug -derivedDataPath .build/xcode-derived build
open .build/xcode-derived/Build/Products/Debug/PoolProblem.app
```

菜单栏出现蓄水池水位图标（水位随磁盘占用实时变化）：

- 点击弹出面板：可用空间主读数、满盘预测、可清理项列表（含安全级别徽标）、一键"智能清理"（先预览后确认）；
- 设置：目标水位（默认 30GB）、傻瓜/专家模式、配方开关与保留天数、白名单、完全磁盘访问状态与引导、开机自启；
- 通知：空间紧张（<20GB）、异常增长、需要操作（如退出 Simulator）、清理摘要；
- 每 30 分钟自动扫描并保存快照（`~/Library/Application Support/PoolProblem` 或 App Group 容器）。

首次使用请到 系统设置 → 隐私与安全性 → 完全磁盘访问 授权，才能扫描 `~/Library/Containers` 等受保护目录。

## 构建与测试

```bash
swift build        # 构建（首次需联网拉取 swift-argument-parser）
swift test         # 运行全部测试
```

## CLI 用法

```bash
poolproblem scan               # 扫描各配方，输出可释放量
poolproblem scan --json        # 机器可读 JSON
poolproblem suggest            # 按规则给出清理建议
poolproblem clean --dry-run    # 预览将清理的内容
poolproblem clean              # 按水线与规则执行清理
poolproblem status             # 水位、满盘预测、最近清理记录
```

数据目录解析顺序：环境变量 `POOLPROBLEM_DATA_DIR` → App Group 容器 → `~/Library/Application Support/PoolProblem`。测试通过 `POOLPROBLEM_DATA_DIR` 指向临时目录隔离。

## 诚实计量的说明

APFS 克隆文件（`cp -c` / Xcode 测试快照）的 inode 与资源标识不共享，但物理块共享——删除前无法用公开 API 精确测量真实可释放空间。因此：

- `reclaimableBytes` 基于硬链接去重（inode 相同才去重），对克隆密集型目录是上界；
- `clean` 输出同时报告估算释放（`freedBytes`）与量规实测（`actualFreedBytes`），以实测为准。

## 未来计划

- M4：macOS 桌面小组件（暂缓）
- 应用图标打磨
- FSEvents 源头治理、MCP server 供 AI Agent 调用

## 设计文档

- 设计：[docs/superpowers/specs/2026-08-09-the-pool-problem-design.md](docs/superpowers/specs/2026-08-09-the-pool-problem-design.md)
- 实现计划：[docs/superpowers/plans/2026-08-09-core-cli.md](docs/superpowers/plans/2026-08-09-core-cli.md)

## 贡献 / Contributing

欢迎贡献！请先阅读 [CONTRIBUTING.md](CONTRIBUTING.md) 与 [CLA.md](CLA.md)。
提交 Pull Request 前，请将你的 GitHub 用户名添加到 `.github/CLA_SIGNERS`，即视为签署贡献者许可协议；
CI 的 `CLA` 状态检查会强制校验。

## License

本项目以 [Apache License 2.0](LICENSE) 发布。Copyright © 2026 xingyu wang.
