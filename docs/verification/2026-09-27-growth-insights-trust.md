# 增长洞察可信度核验（2026-09-27）

## 环境与命令

- 环境：macOS Apple Silicon，Swift Testing，Xcode `PoolProblem` scheme；工作分支 `codex/growth-insights-trust`。
- 前置条件：在仓库根目录执行；测试只读写系统临时目录中的 UUID 隔离夹具，不使用用户实际目录，也不执行清理。
- Swift 端到端夹具与全套核心测试：`swift test --scratch-path "$TMPDIR/poolproblem-growth-insights-20260927/build" --skip cliScan`。
- macOS 无签名编译与链接：`xcodebuild -quiet -project PoolProblem/PoolProblem.xcodeproj -scheme PoolProblem -configuration Debug -destination 'platform=macOS' -derivedDataPath "$TMPDIR/poolproblem-growth-insights-20260927/DerivedData" CODE_SIGNING_ALLOWED=NO build`。
- 文案格式与补丁检查：`python3 -m json.tool PoolProblem/PoolProblem/Localizable.xcstrings > /dev/null` 和 `git diff --check`。

## 端到端夹具输入与结果

| 夹具 | 输入及操作 | 可复核结果 |
| --- | --- | --- |
| `persistedGrowthIsHistoricalAndReconciledWithLivePaths` | 临时目录内写入同一路径两个不同观测窗口、另一个首次记录路径；持久化增长台账，然后删除路径并重新读取 | 每个路径只取最近一次事件，不相加；已删除路径不显示且计入排除数量；历史台账原样保留 |
| `aCacheNameAloneCannotCreateAnActionableRecipeSuggestion` | 临时 `~/.cache/unknown-tool` 与旧版持久化包管理器候选 | 目录名不生成清理建议；旧候选不能显示或采纳 |
| `aPersistedProjectSuggestionRequiresARecognizedProjectAtItsCurrentPath` | 临时项目先有 `package.json`，随后移除标记 | 标记存在时可展示；移除后不能展示或采纳 |

上述第三个夹具在实现复核前按预期失败，实现后通过。2026-09-27 最终运行：**194 项 Swift 测试全部通过**；无签名 macOS Debug 构建通过；JSON 解析及 `git diff --check` 通过。临时构建目录可由上述命令重复生成。

## 验收边界

- 已验证增长数值与时间语义、历史路径过滤、建议拦截、编译与链接。
- 路径存在性不是当前体积测量；弹窗明确写出“当前占用未复测”。完整表面扫描保持显式操作。
- 未在当前运行的菜单栏 App 中完成弹窗布局、键盘与屏幕阅读器实际验收；无签名构建通过不等于这一验收。
- 未执行真实目录删除、废纸篓操作、签名安装或主分支合并。
