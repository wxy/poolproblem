# Watch Only 资产监视验证记录（2026-09-27）

## 环境与前置条件

- 基线：草稿 PR #33 的 `6f2c382`；本次变更在同一独立工作树追加。
- macOS arm64、Xcode 27.0、Apple Swift 6.4；系统临时目录可读写。
- 测试不读取或修改真实设备备份、Docker、虚拟机或模型目录。

## 可重复生成的端到端工件

从仓库根目录运行：

```sh
swift test \
  --scratch-path "$TMPDIR/poolproblem-watch-only-verification/build" \
  --filter watchOnlyAssetsRemainVisibleAndCannotEnterCleanup
```

测试源码 `Tests/DiskReservoirCoreTests/WatchOnlyAssetsEndToEndTests.swift` 是可重复生成验证结果的工件。它在系统临时目录创建假主目录，输入为近期写入的 1,024 字节设备备份文件和 2,048 字节模型文件；测试结束移除该临时目录。

测试贯通真实文件目录、内置配方、完整扫描、增量重扫和清理引擎，并断言：

1. 两类资产均可见；只有 `.lmstudio/models` 存在时，聚合条目仍指向该实际路径，近期更新不会被清理年龄规则过滤。
2. 扫描所得 `reclaimableBytes` 为零；手动清理资格和自动永久删除授权均为否。
3. 将旧快照模拟为错误的正数可回收量后，强制清理仍无日志且删除探针零调用；输入文件留在原位。

本次结果：该端到端场景通过。首次先写测试时因缺少 `WatchRecipes` 和 `watchOnly` 而无法编译；迁入实现后通过。
实际运行时的 `--scratch-path` 使用了同在 `$TMPDIR` 下的任务专用目录。

## 回归、构建与边界

```sh
swift test \
  --scratch-path "$TMPDIR/poolproblem-watch-only-verification/build" \
  --skip cliScan
python3 -m json.tool PoolProblem/PoolProblem/Localizable.xcstrings >/dev/null
git diff --check
xcodebuild -quiet -project PoolProblem/PoolProblem.xcodeproj \
  -scheme PoolProblem -configuration Debug -sdk macosx \
  -derivedDataPath "$TMPDIR/poolproblem-watch-only-verification/DerivedData" \
  CODE_SIGNING_ALLOWED=NO build
```

本次结果：191 项 Swift Testing 测试及单独 1 项 CLI 测试通过；本地化 JSON、diff 检查和 macOS App 无签名编译链接通过。构建仅提示存在多个匹配的 macOS destination，自动选择第一个。

沙盒环境无法写入系统 Swift/Xcode 模块缓存时，命令在编译前报 `Operation not permitted`；本次通过结果来自允许访问模块缓存的本地环境。

尚未验证真实菜单栏的视觉布局、磁盘权限限制和大目录扫描耗时。资产区显示文件已分配空间的估算值；共享 APFS 块可能重复计算。#32 的 Owner Command 运行代码未迁入，也未执行任何真实工具清理命令。
