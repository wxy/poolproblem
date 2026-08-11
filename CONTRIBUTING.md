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

## 行为准则 / Code of Conduct

保持友善、尊重与建设性。技术讨论对事不对人。
