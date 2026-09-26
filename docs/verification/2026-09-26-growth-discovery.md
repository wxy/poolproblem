# 手动增长来源扫描验证记录（2026-09-26）

## 范围与环境

- 基线：`origin/main` 的 `80ecb3a`，工作分支 `codex/growth-discovery-slice`。
- 环境：macOS arm64、Xcode 27.0 (`27A266a`)、Apple Swift 6.4。
- 验证对象：手动扫描从真实临时文件目录读取、写入独立的表面快照、再读取最新报告。此流程不写清理台账，不生成配方或候选项。

## 可重复执行的端到端场景

在仓库根目录运行：

```sh
swift test --filter surfaceGrowthDiscovery
```

输入由 `Tests/DiskReservoirCoreTests/SurfaceGrowthDiscoveryEndToEndTests.swift` 在系统临时目录中自动创建并在测试结束后移除：

1. 首次扫描有 100 字节文件的目录，只保存基线，不报告增长。
2. 两天后给旧目录增加 300 字节，另建有 300 字节文件的新目录；报告两条 300 字节增量，速率各为 150 字节/天，持久化的扫描时间和报告可重新读取，普通增长台账保持为空。
3. 第三次不修改文件，最新报告为空；无效时间或不可用根目录不会替换有效基线。
4. 另一场景先保存仅 30 字节的小目录，再增加 60 字节；应报告 60 字节，而非把当前的 90 字节误报为新增。该场景曾在修正前稳定失败，修正后通过。

结果：两个端到端场景通过。测试自身和此记录构成可重复生成的工件。

## 回归与构建

在仓库根目录运行：

```sh
swift test --skip cliScan
python3 -m json.tool PoolProblem/PoolProblem/Localizable.xcstrings >/dev/null
git diff --check
xcodebuild -quiet -project PoolProblem/PoolProblem.xcodeproj \
  -scheme PoolProblem -configuration Debug -sdk macosx \
  -derivedDataPath "$TMPDIR/poolproblem-growth-discovery-verification/DerivedData" \
  CODE_SIGNING_ALLOWED=NO build
```

本次结果：Swift Testing 的 190 项测试和单独运行的 1 项 CLI 测试通过；本地化 JSON 校验、diff 检查和 macOS App 无签名编译链接通过。`xcodebuild` 仅提示有多个匹配的 macOS destination，并自动选择第一个。

## 尚未验证的边界

- 未在实际 macOS 菜单栏界面做点击、耗时、权限弹窗或视觉验收；构建成功不能代替这些结果。
- 表面扫描只覆盖按钮说明中的主目录一级子目录，并递归统计其中可读取的文件；根目录下的独立文件不会进入结果。深层目录若被系统拒绝读取，现有 `POSIXDirectoryWalker` 会跳过该子树，因此报告不能解释所有磁盘空间变化。
- 只读报告不证明任何目录可安全清理；下一步若要引入配方或清理动作，需另行验证路径、权限、进程与回收空间语义。
