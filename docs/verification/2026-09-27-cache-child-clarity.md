# 子目录展示与清理边界验证（2026-09-27）

## 环境与可重复命令

- 当前仓库分支：`codex/cache-child-clarity`，基于已合并 PR34 的 `ab809de`。
- macOS 26.6.2（Apple Silicon）、Xcode 27.0、Swift 6.4。
- 前置条件：在仓库根目录执行；端到端夹具只读写系统临时目录内的 UUID 文件树，模拟废纸篓也设在同一夹具内，不触碰用户真实缓存或废纸篓。
- 全套包测试：`swift test --scratch-path "$TMPDIR/poolproblem-child-clarity-build"`。
- App 无签名编译和链接：`xcodebuild -project PoolProblem/PoolProblem.xcodeproj -scheme PoolProblem -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath "$TMPDIR/poolproblem-child-clarity-derived-data" CODE_SIGNING_ALLOWED=NO build`。
- 现有 App 测试尝试：在上一条命令中把 `build` 改为 `-only-testing:PoolProblemTests CODE_SIGNING_ALLOWED=NO test`（只执行现有测试，不新增隔离测试）。
- 资料格式与补丁：`python3 -m json.tool PoolProblem/PoolProblem/Localizable.xcstrings > /dev/null`、`git diff --check`。

## 端到端输入与结果

| 场景 | 输入与操作 | 结果 |
| --- | --- | --- |
| 子目录展示与增长 | 临时缓存树内构造约 11 MB、1 MB 的目录及一个指向树外的符号链接；给大目录先后写入 9 MB、3 MB 的增长观测，另模拟 800 MB 历史增量 | 仅展示达到 10 MB 且真实存在的目录；取最近一次 3 MB 观测及其实际时长；增量超过当前占用时不显示增长 |
| 清理资格与移动 | 临时 DerivedData 树中构造普通项目、共享缓存、深层目录、树外路径和符号链接；修改目录时间、替换同名目录；把允许的项目移入夹具内的模拟废纸篓 | 根目录、深层目录、共享目录、符号链接、近期活跃目录、未授权父目录及被替换的同名目录均拒绝；只移动选择的旧项目，父目录与共享缓存留存 |
| 主列表门槛 | 扫描临时 1 KB 配方目录及 1 KB 废纸篓目录，二者配方门槛均设为 100 MB | 原始扫描仍含两项；界面筛选隐藏小配方项，废纸篓入口保留 |
| 短间隔趋势 | 对临时目录做两次真实扫描，第二次增加文件，分别用 1 小时和 2 天的快照跨度输入趋势计算 | 1 小时跨度不产生“每日/每周增长”速率；2 天跨度保留增长趋势 |
| 开发工具大目录 | 读取当前内置配方 | DerivedData 只允许逐项、共享缓存受保护；CoreSimulator 设备数据列入可展开的“只观察”项目，不提供整目录删除 |

上述新断言先于相应实现添加并观察到失败；修正后全套 `swift test` **202 项通过**（199 项核心、3 项 CLI）。macOS Debug 无签名构建 **BUILD SUCCEEDED**；JSON 解析及 `git diff --check` 通过。额外尝试的 Xcode App 测试宿主在建立测试连接前退出，报 `Early unexpected exit, operation never finished bootstrapping`，没有执行到测试断言；此项未验证通过，也不能作为代码失败的证据。本文档是可复核工件，临时构建目录和日志可由上面的命令重新生成。

## 验收边界

- 已验证真实文件树枚举、增长数据筛选、子项清理资格、模拟废纸篓内的单项移动、配方边界、编译和链接。
- 未对用户真实缓存、DerivedData 或模拟器设备执行清理。移动到废纸篓不等于立即增加磁盘可用容量。
- 菜单栏浮层的实际排版、Finder 按钮点击和辅助功能仍需在用户当前仓库重建运行后人工检查；本次无签名构建不代表此项已通过。
