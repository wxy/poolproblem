# The Pool Problem（蓄水池问题）

> 你的磁盘，就是那道经典的蓄水池问题——进水管、出水管、水位、什么时候会满。The Pool Problem 负责把它解出来。

面向开发者的磁盘"归因与治理"工具：测量各产废源（Xcode 构建产物、模拟器快照、包管理器缓存等）的流速，预测磁盘何时会满，追踪清理后空间为何回涨，并在源头治理——让可用空间稳定在健康水位。

## 当前状态

- ✅ M1 Core（SwiftPM 库 `DiskReservoirCore`）：配方库、扫描器（含硬链接去重的诚实计量）、快照存储、流量分析（归因/回涨/增长警报）、满盘预测、规则评估、进程检测、文件删除、水线清理引擎（含量规实测 `actualFreedBytes`）
- ✅ M2 CLI（`poolproblem`）：`scan` / `suggest` / `clean` / `status`，稳定 JSON 输出
- ⏳ M3 App（SwiftUI 菜单栏）、M4 小组件、M5 打包 —— 后续计划

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

- M3：SwiftUI 菜单栏 App（水位仪表、傻瓜/专家模式、通知、权限引导）
- M4：macOS 桌面小组件
- M5：DMG + 公证打包
- FSEvents 源头治理、MCP server 供 AI Agent 调用

## 设计文档

- 设计：[docs/superpowers/specs/2026-08-09-the-pool-problem-design.md](docs/superpowers/specs/2026-08-09-the-pool-problem-design.md)
- 实现计划：[docs/superpowers/plans/2026-08-09-core-cli.md](docs/superpowers/plans/2026-08-09-core-cli.md)
