# pnpm store Recipe 验证

## 实现前失败方式清单

1. GUI `PATH` 的首个 pnpm 是不可用的 Corepack shim，而 NVM 等目录有可用 pnpm；首个失败不应阻断后续候选。
2. 多个可执行候选报告不同的规范化 store 路径；必须拒绝歧义，不能随意选择。
3. 同一 store 经符号链接、重复 PATH 或多个 pnpm 返回时，应该去重并接受。
4. 进程退出非零、超时、启动失败、输出为空、多行、相对路径、根目录、HOME 目录、非目录或逃逸路径；不得形成 Recipe。
5. stderr 包含警告或错误时，不能污染 stdout 的路径解析；失败诊断必须有界。
6. Corepack 探测可能尝试网络；探测环境必须禁用网络，且不得经 shell 命令字符串执行。
7. 扫描后目标变化或探测失败，旧 Recipe 和旧 ScanItem 不得获得路径删除权限。
8. store 小于 10 MB 时不能出现在占用列表；达到阈值时显示实际测量占用。
9. CLI、Cleaner、自动清理、智能清理及旧快照都不能按路径删除 store；官方 `pnpm store prune` 只能通过明确确认的 owner-command 流程执行。
10. 确认后可执行文件消失或同一可执行文件的 store 路径变化；执行前必须重新探测并拒绝变化。
11. 旧快照或用户自定义包管理器根目录可能恰好等于 store、是 store 的父目录，或经符号链接别名指向这些目录；即使条目 Recipe ID 不是 pnpm，也不得整体清理。
12. pnpm store 在扫描后迁移；清理时必须重新探测，不能只用扫描时的路径。若重新探测失败或歧义，自定义根目录必须拒绝按路径清理。
13. 自定义聚合条目混合安全路径与 store 父目录；可以跳过危险路径并保留安全路径，但 UI 整项按钮不能误导用户认为危险路径可清理。
14. pnpm store 可被配置在已批准的默认缓存根目录（例如 `~/.npm`）之下；重新探测失败时，包管理器缓存家族也必须拒绝清理，不能把已批准根目录当作 store 安全证明。
15. pnpm store 可位于 `~/Library/Caches/pnpm` 等一级缓存子目录；详情列表不能提供其清理操作，最终 `cleanCacheChild` 也必须重新探测并拒绝移动该子目录或其父目录。
16. pnpm 可执行文件被卸载但 store 仍留在已知历史 target 或常见 pnpm 目录；仍需阻止原始路径清理。若没有任何可识别路径或历史记录，任意自定义位置的孤儿 store 无法从本机当前状态推断，保留普通缓存清理并明确记录这一剩余边界。
17. store 从 A（例如 `~/.npm/pnpm-store`）迁至 B（例如 `~/Library/pnpm`）后，A 仍可保留实体文件；只记录最近一次 B 会令旧 A 被自动清理。必须持久保存有界、去重的所有已观察规范化 store 路径，且重启后加载，不能依赖会按 90 天清理的快照。
18. A→B 后旧 A 不能继续计入 `.npm` 聚合条目的可回收量；当前 B 仍应独立计量。旧路径保护不得妨碍与 A 无重叠的安全缓存兄弟路径清理。

## 端到端验证记录

运行命令：

```sh
mkdir -p "$TMPDIR/poolproblem-pnpm-recipe-verification/cache"
CLANG_MODULE_CACHE_PATH="$TMPDIR/poolproblem-pnpm-recipe-verification/cache" \
SWIFT_MODULE_CACHE_PATH="$TMPDIR/poolproblem-pnpm-recipe-verification/cache" \
swift test --disable-sandbox --filter PnpmStoreRecipeEndToEndTests
```

环境：macOS arm64、Xcode Swift 6；模块缓存置于 `$TMPDIR` 以满足工作区权限。输入：测试生成的假 pnpm 可执行文件和假 store，执行后自动删除 fixture；不会对真实 store 运行 prune。结果：10 项通过，覆盖路径别名、旧快照、嵌套及完全相同根目录、A→B 持久历史、快照清理后仍保留 A、1,024 条上限溢出保护、探测失败时的拒绝清理，以及安全缓存的保留清理能力。可重复核验的实际输出见 [测试日志](verification-artifacts/pnpm-store-recipe-e2e.log) 和 [运行记录](verification-artifacts/pnpm-store-recipe-e2e.txt)。

实现前运行的针对性失败复现及断言输出见 [失败复现记录](verification-artifacts/pnpm-store-recipe-failfirst.txt)。

A→B 新失败复现的命令、输入和缺失 API 编译错误见 [历史路径失败复现](verification-artifacts/pnpm-store-history-failfirst.txt)。历史路径写入 `pnpm-known-store-paths.json`，按规范化路径去重，最多保存 1,024 条；超过上限后持久化溢出标记，所有原始路径清理失败关闭，直到历史状态可恢复。初次升级从现存快照迁移历史路径；已在升级前被 90 天快照保留策略删除的更早路径无法恢复。

首次 GitHub CI 全量运行暴露了 A→B 测试环境假设：测试把水位固定在 90 MB，但 CI 机器的实际可用空间已经高于这个数，因此 Cleaner 正确地未进入清理。测试现以扫描时的实际可用空间加 10 MB 作为水位，确保测试的清理前置条件成立；改后 10 项针对性端到端测试通过。命令、环境、输入、结果与 CI 失败链接见 [CI 修复验证记录](verification-artifacts/pnpm-store-ci-fix.txt)和 [完整日志](verification-artifacts/pnpm-store-ci-fix.log)。

探测总预算为 30 秒，每个候选最多 8 秒；任一候选超时则拒绝形成可操作 target。现有错误 API 只返回进程退出码，stderr 已与路径输出分离并丢弃；因此如 Corepack 退出 11，界面能展示退出码但无法展示原始原因。这项诊断展示仍待补充。

AppService 的 macOS 端到端测试源码覆盖 `~/Library/Caches/pnpm` 子项列表与最终删除守卫。最新源码的 `xcodebuild build-for-testing` 成功，[编译记录](verification-artifacts/pnpm-store-child-build-for-testing.txt)含命令与结果；本环境的 test runner 在握手前以 0 退出，Xcode 判定 `Early unexpected exit`，因此断言未执行，[测试运行记录](verification-artifacts/pnpm-store-child-xcode-test.txt)保存此限制。先前一次 Swift Package 全量测试因并发探测耗时超过 3 分钟而中断；本轮最终全量测试的 helper 运行超过 7 分钟仍无输出且处于休眠，遂中断，均无全量结论；[记录](verification-artifacts/pnpm-store-recipe-full-swift-test.txt)保留了命令和结果。两次之间以 `$TMPDIR/poolproblem-pnpm-recipe-ci` 为 scratch 路径执行 `swift test --skip cliScan -q`，报告当时的 210 项 Core 与 1 项 CLI 测试通过；`cliScan` 未包含在该次验证中。新增功能以本页的 10 项针对性端到端结果为准。
