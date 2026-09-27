# 测试夹具污染系统废纸篓：诊断与隔离验证

## 原因与现存状态

- `progressiveCleanerPrefersFastGrowingCandidates` 原先每次在系统临时目录创建 `child-a/data.bin`（600,000,000 字节）和 `child-b/data.bin`（800,000,000 字节），把目录修改时间设为 30 天前，再用 `FileManagerFileDeleter` 按 `.trash` 清理 `child-a`。该删除器调用系统 `FileManager.trashItem`，所以临时目录虽随后删除，`child-a` 仍留在用户真正的废纸篓。
- Finder 只读检查见到多个 `~/.Trash/child-a .../data.bin`，展开条目的文件大小为 600 MB；在本次修复前，Finder 显示系统废纸篓共有 13 个顶层项目。终端直接枚举 `~/.Trash` 被 macOS 拒绝；上述判断依据 Finder 可见条目和代码，不对其他废纸篓项目作推断。
- 现存条目没有删除、恢复或修改。修正仅防止将来的测试继续产生此类条目。

## 修正与可重复验证

- 把增长优先场景的夹具大小缩为 600,000 与 800,000 字节，增长输入和候选门槛等比例降低，仍覆盖“增长较快的小候选优先于更大的静态候选”。同文件的最小候选规模场景也从约 770 MB 的夹具缩至约 770 KB，保持原有候选排序和门槛关系。
- 清理器使用 `TrashBatchDeleter(trashRoot: <该测试的临时根目录>/.Trash)`；断言选中项的 `data.bin` 进入该临时废纸篓，原路径消失。测试结束时临时根目录及其中的废纸篓一起移除。
- 环境：macOS arm64；在仓库根目录执行。输入由测试在 `$TMPDIR` 下用 UUID 目录自动生成；不依赖用户文件。
- 单项：`/usr/bin/arch -arm64 /usr/bin/env PATH="$PATH" swift test --scratch-path "$TMPDIR/poolproblem-trash-test-fix/build" --filter progressiveCleanerPrefersFastGrowingCandidates`，1 项通过。
- 全套：`/usr/bin/arch -arm64 /usr/bin/env PATH="$PATH" swift test --scratch-path "$TMPDIR/poolproblem-trash-test-fix/build"`，核心 200 项和 CLI 3 项通过。
- 全套结束后用 Finder 再次只读核对：系统废纸篓仍显示 13 个顶层项目，未新增 `child-a`。这只证明本次运行没有增加可见顶层项目；不代表现存条目已被清理。

验证记录是持久工件；临时构建与日志目录可由上述命令重新生成。
