# 从 Mole（tw93/Mole）学什么 —— 面向 The Pool Problem 的调研

> 调研日期：2026-09-24。对象：https://github.com/tw93/Mole （GPL-3.0，bash CLI + Go TUI，当期 main 分支浅克隆通读）。
> 结论先行：Mole 与我们定位不同（它是一次性主动清理工具箱，我们是常驻水线守护器），但它的**实测知识库**（几百个 Mac 软件在哪里藏垃圾、哪些目录看着像缓存其实是用户数据）和**若干安全工程纪律**对我们有直接参考价值。

## 0. 许可证红线（先说最重要的）

Mole 是 **GPL-3.0**，我们是 **Apache-2.0**。**一个字节都不能抄**：不能复制它的 bash/Go 代码、正则、注释。可以合法吸收的是：

- **路径事实**（`~/Library/...` 这类目录位置是不受版权保护的事实）；
- **机制思想**（owner-command 清理、tri-state 进程守卫、报告不删除清单等），由我们独立实现。

本文所有内容均为路径事实与思想，未包含 Mole 源码。调研用的浅克隆 `git clone --depth 1 https://github.com/tw93/Mole` 用完即删，不留在仓库里。

## 1. Mole 的知识库长什么样（源码地图）

| 模块 | 内容 |
| --- | --- |
| `lib/clean/app_caches.sh`（~2000 行） | **逐 App 的缓存清单**：~150 个具名 App（微信、钉钉、飞书、Slack、Zoom、Adobe、Steam、Telegram……）各自的缓存路径 |
| `lib/clean/dev.sh`（~5400 行） | 开发者工具链缓存全集 + AI 工具缓存 + 模拟器孤儿运行时 |
| `lib/clean/user.sh`（~2900 行） | 浏览器（含 Chromium 旧版本清理）、邮件附件、iOS 固件/备份、设备固件 .ipsw、WebKit 缓存、**只报告不删清单** |
| `lib/clean/apps.sh` | 按「App 是否已卸载」发现 Application Support / Containers / Group Containers 孤儿残留 |
| `lib/clean/system.sh` | 系统级：统一日志、崩溃报告、icon services、`/var/folders` GPU 编译缓存 |
| `bin/installer.sh` | 安装包（DMG/PKG/ISO/XIP/ZIP）发现：**Telegram 接收目录、Mail 附件、iCloud Drive Downloads、Homebrew 缓存、/Users/Shared/Downloads** |
| `lib/clean/project.sh` | `mo purge`：项目构建产物，带密钥文件/嵌套 git/git-tracked 保护 |
| `lib/optimize/tasks.sh` | QuickLook 缩略图、icon cache、QuarantineEventsV2 vacuum 等维护任务 |

## 2. 实测出来的「异常空间占用原因」—— 我们没注意到的（核心章节）

以下按「我们目前的配方/表面扫描会漏掉的程度」排序。✅=已有覆盖，⚠️=表面扫描能看到但无配方，❌=完全不可见。

### 2.1 Xcode 系：我们自己就是开发者，仍漏了三个

- ❌ **tvOS DeviceSupport**：`~/Library/Developer/Xcode/tvOS DeviceSupport`。我们只有 iOS + watchOS。
- ❌ **Interface Builder 缓存**：`~/Library/Developer/Xcode/UserData/IB Support`。
- ❌ **CoreDevice 服务缓存**：`~/Library/Containers/com.apple.CoreDevice.CoreDeviceService/Data/Library/Caches`（Xcode 15+ 真机服务，藏在我们「表面扫描根」的 Containers 里，但无配方）。
- ⚠️ **DeviceSupport 保留策略差异**：Mole 默认保留最近 **2** 个版本（可配置），理由是多台真机可能停留在不同 OS 版本；我们只保留 mtime 最新 1 个——可能删掉用户第二台真机的支持文件，下次连接要重挂符号。
- Mole 的教训（他们踩过的坑，AGENTS.md 记录）：判断「孤儿模拟器运行时」必须用 `simctl -j` 输出的 `runtimeIdentifier` 做 join，再要求 `state: Ready` + `deletable: true`；**绝不能按 Volumes 挂载缺失推断孤儿**，也绝不能按运行时显示名 join（同一运行时在两个命令里标题不同）。我们 `simulator-runtimes` 配方目前按 Volumes 一级子目录展开，值得复核这条边界。

### 2.2 iOS 生态：最大的隐形户

- ❌ **设备备份**：`~/Library/Application Support/MobileSync/Backup`——每台设备可轻松 20–60GB，增长缓慢且不在任何缓存目录里。Mole 识别并报告它（只报告）。
- ❌ **缓存的固件**：`~/Library/iTunes/iPhone Software Updates` / `iPad…` / `iPod…`，以及 Finder / Apple Configurator 的 `.ipsw` 缓存——每个数 GB。
- ⚠️ **Mail 附件双份缓存**：`~/Library/Mail Downloads` **和** `~/Library/Containers/com.apple.mail/Data/Library/Mail Downloads`。两处都可能数 GB，后者在容器里，没有完全磁盘访问根本看不见。

### 2.3 虚拟机与容器：只增不减的经典

- ⚠️ **Docker Desktop**：`~/Library/Containers/com.docker.docker/Data`（Docker.raw 稀疏文件只增不减，`docker system prune` 之前宿主机看不到回收）。Mole 的处置是**只报告 + 指引 `docker system df`**，永不直接删。
- ❌ 同类：**OrbStack**（`~/Library/Group Containers/*dev.orbstack/data`、`~/OrbStack`）、**Lima**（`~/.lima`）、**Colima**（`~/.colima`）、**tart**（`~/.tart/cache`，这个可清）。这些都不在我们的任何表面扫描根之下（Group Containers 不是我们的表面根）。

### 2.4 本地大模型（2024–2026 新增长源）

- ❌ **Ollama**：`~/.ollama/models`；**LM Studio**：`~/.lmstudio/models`。Mole 把这两个放进**默认白名单**（保护清单），只做体积报告。理由：那是「下载即资产」的模型权重，不是缓存。
- **最佳反面教材**（Mole 注释里记录的实测史）：LM Studio ≤0.3.5 把**整个用户目录**放在 `~/.cache/lm-studio`——里面有模型、预设、聊天记录。0.3.6 迁到 `~/.lmstudio` 且旧数据不迁移。教训直接命中我们的分类学：**「目录名带 cache」不等于可再生存储**；我们的 `cleanability` 分类必须看恢复契约，不能看名字。

### 2.5 国产 IM / 协作工具（Mole 中国用户群实测的独特积累）

这批 App 的共同点：缓存大头常在 **Application Support 而非 Caches**，且体积容易到 10GB+：

- ❌ 微信 `com.tencent.xinWeChat`、QQ、企业微信 `com.tencent.WeWorkMac`
- ❌ 钉钉 `dd.work.exclusive4aliding`（Caches）+ `~/Library/Application Support/iDingTalk/log`、`holmeslogs`（日志在 App Support！）
- ❌ 飞书 `com.feishu.*`、腾讯会议、腾讯视频、QQ音乐、网易 163 音乐、爱奇艺、斗鱼、虎牙、哔哩哔哩 `tv.danmaku.bili`
- ✅ Telegram `ru.keepcoder.Telegram`（在 Caches，我们的通用 Caches 配方按子目录能覆盖到）

### 2.6 Electron 系应用：缓存不止一种

Mole 对 Claude Desktop、Qoder、Filo、Antigravity、Codex Desktop 等 Electron 应用逐叶清理，实测出新版 Chromium/Electron 的**缓存家族**：

`Cache`、`Code Cache`、`GPUCache`、`ShaderCache`/`GrShaderCache`、**`DawnCache` / `DawnWebGPUCache`（WebGPU 着色器）、`GraphiteCache`（Dawn 新后端）**、`SentryCrash`。

- ❌ 我们只有「应用缓存」一个笼统概念。WebGPU 四件套是 2024 之后才出现的，多数清理工具都没跟上。
- 同族实测大户：Slack（`~/Library/Application Support/Slack/Cache`——在 App Support！）、Zoom、Notion、Obsidian、Figma、Teams。

### 2.7 浏览器自更新的「旧版本堆积」

- ❌ Chromium 系（Chrome/Edge/Brave）更新后会在数据目录留下**多个完整旧版本副本**（每份数百 MB）。Mole 有表驱动的「旧版本清理」，且注释明确 Edge 更新器的 staged payload（`App Support/Microsoft/EdgeUpdater/apps/msedge-stable`）语义不同：严格只删**小于已装版本**的，读不出已装版本时按 keep-latest 保守处理。
- ✅ WebKit 网络缓存 `~/Library/Caches/com.apple.WebKit.Networking`（通用 Caches 配方可覆盖）。

### 2.8 系统层「沉默的增长」

- ❌ **统一日志** `/private/var/db/diagnostics`：可达数十 GB，开发者机器上 `log collect`/崩溃频繁时更快。我们表面根完全不含它。
- ❌ `/private/var/db/DiagnosticPipeline`、`reportmemoryexception/MemoryLimitViolations`、`/Library/Logs/DiagnosticReports`（崩溃报告）。
- ❌ **GPU 着色器编译缓存**：`/private/var/folders/*/*/C/com.apple.metal{,fe,gpuarchiver}`——Xcode/模拟器重度用户专供。
- ⚠️ **Time Machine 本地快照**：Mole 只做只读计数提示（`tmutil listlocalsnapshots`），因为 `tmutil thinlocalsnapshots` 之外的删除属于系统状态修改。我们的「可用空间」探针应意识到：APFS 快照占用的空间在 Finder/df 里表现反直觉（删大文件后可用空间不涨）——这是水线误报/不恢复的一个被低估的根因。
- ❌ 明确禁区（Mole 立了规矩，值得抄成我们的禁区清单）：`/Library/Updates`、`/macOS Install Data`（Software Update 暂存区，任何年龄/进程证据都不足以证明它不活跃）、PowerLog 数据库（SQLite 连接无法证明已关闭）、`com.apple.*` 一律不动。

### 2.9 开发者工具链缓存：对照我们的包管理器配方族

我们已有：`.npm`、`Library/pnpm`、`.cache/uv`、CocoaPods、Homebrew。Mole 覆盖而我们有缺口的（按开发者常见度）：

| 工具 | 位置 | 我们的可见性 |
| --- | --- | --- |
| Go 构建缓存 | `~/.cache/go-build` | ⚠️ `.cache` 是表面根但无配方 |
| Go module | `$GOPATH/pkg/mod`（默认 `~/go/pkg/mod`） | ❌ |
| Gradle | `~/.gradle/caches`（+daemon 日志） | ❌ |
| Cargo | `~/.cargo/registry/cache`（注意 `registry/src` 是混合态，Mole 也不碰） | ❌ |
| Rustup | `~/.rustup/downloads` | ❌ |
| Yarn/bun/corepack/npx | 各自缓存目录 | ❌ |
| **Conda pkgs** | `~/.conda/pkgs`、`~/anaconda3/pkgs`、`~/miniconda3/pkgs`、`~/miniforge3/pkgs`、`~/mambaforge/pkgs` | ❌ **五个位置全都不在 Library/Caches 也不在 .cache，我们的表面扫描完全看不见** |
| pip | `~/Library/Caches/pip` | ✅（通用 Caches 配方） |
| 前端构建缓存 | `.eslintcache`、`.mypy_cache`、`.pytest_cache`、`.turbo`、`.vite` 等（项目内） | ⚠️ 项目配方只有 node_modules/dist/build |

Mole 的分级思想值得抄：**同类不同命**——Go module cache 走 `go clean -modcache`（owner 命令）可清；`registry/src`、`~/.m2/repository`、`~/.nuget/packages`、`~/.ivy2/cache` 是「直接消费/混合态」→ 只报告；HuggingFace/Torch 等模型缓存目录 → 只报告。

### 2.10 安装包的非常规藏身处（`mo installer` 的扫描点，可直接借鉴）

`~/Downloads` 之外：**`~/Downloads/Telegram Desktop`**、**`~/Library/Application Support/Telegram Desktop`**、**Mail Downloads**、**iCloud Drive Downloads（`~/Library/Mobile Documents/com~apple~CloudDocs/Downloads`）**、`/Users/Shared/Downloads`、Homebrew 缓存里的 DMG。对应文件类型 DMG/PKG/MPKG/ISO/XIP/安装 ZIP。我们是常驻监控，把「安装包落地」做成增长归因的一类非常自然。

### 2.11 杂项但真实的实测大户

- ❌ Adobe 媒体缓存：`~/Library/Application Support/Adobe/Common/Media Cache Files`（PR/AE 用户动辄几十 GB，且在 App Support）、`/Library/Logs/Adobe`、`CreativeCloud` 日志。
- ❌ 网盘缓存：Dropbox / Google Drive / OneDrive 各自的 Caches。
- ❌ 游戏/模拟器 shader 缓存：`Steam/steamapps/shadercache`、PCSX2、RPCS3、Battle.net——开发者也打游戏。
- ❌ 数据库 GUI 工具缓存：Charles、Proxyman、Postman、Insomnia、DBeaver、TablePlus、Sequel Ace、Navicat、MongoDB Compass、Redis Insight。
- ⚠️ 小而持久的：`Saved Application State`、`HTTPStorages`、`CrashReporter`、Group Containers 里的日志/缓存（如 `useractivityd/shared-pasteboard`）。
- ⚠️ **僵尸进程信号**：`mo status` 检测僵尸进程并归因父进程（例：`Chrome for Testing ×3`）——泄漏的自动化浏览器。这与磁盘增长直接相关：每个泄漏的 headless Chrome profile 几百 MB 起步。Mole 还有一条实测坑：泄漏 profile 的判据是「`playwright_chromiumdev_profile-*` 目录 + 进程 ppid=1」，但 **playwright 守护进程本身就是 ppid=1**，不能按 ppid 杀守护进程。

## 3. 机制层面值得独立重实现的 8 个模式

1. **Owner-command 清理（工具清自己）**：`uv cache prune`、`pnpm store prune`、`go clean -modcache`、`conda clean --index-cache --tarballs --logfiles`、`brew cleanup --prune=30`、`corepack cache clean`、`gh config clear-cache`、`xcrun simctl runtime delete`。比直接删目录安全：遵守工具自己的锁与代际语义。→ 可给我们的 `Recipe` 增加 `ownerCommand`（或 `OwnerCommandCleaner` 协议）：有 owner 用 owner，owner 不可用才降级删路径，且降级路径要显式标注。
2. **Tri-state 进程守卫**：探测结果三态（运行/未运行/未知），**未知 = 拒绝清理**（fail-closed），且全库只允许一个翻译点。我们的 `ProcessGuard` 值得自查是否所有调用点都把「探测失败」当「拒绝」而不是「放行」。
3. **新清理目标的准入纪律**：「必须有实测可回收字节 + 明确的 non-target 清单（同级不清理什么、为什么）」。没有实测数值的目标不许进默认清理集——先做成只读报告。这和我们的「诚实计量」同源，但 Mole 把它做成了 PR 准入门槛，值得写进 CONTRIBUTING。
4. **报告型条目（report-only）**：对「下载即资产」或「owner 管理」的数据（Docker、OrbStack、Lima、LM Studio/Ollama 模型、Maven/NuGet 仓库），Mole 统一走 `_report_large_or_stop`：显示体积 + 指引 owner 命令，永不自动删。→ 我们 `cleanability: .displayOnly` 已有雏形，可扩成一组「增长大户监视清单」。
5. **超时与部分结果的纪律**：所有探测/清理都有超时；**超时产出的部分清单禁止流入删除循环**；宁可输出「partial + skipped 原因」也不假装完整。
6. **APFS mtime 不上溯**：父目录 mtime 不随子树变化而变化 → **任何按目录 mtime 做的缓存失效都不可靠**，必须实测。印证我们 SurfaceScanner 全量重测的做法；也提醒我们：未来若给扫描加速加缓存，不能以 mtime 为键。
7. **`mo purge` 的项目安全门**：含部署密钥文件的目录、嵌套 git 仓库、git-tracked 内容 → 发现期就剔除、删除前再验一次；7 天内活跃的产物默认不勾选；worktree 本体永不删（「worktree 是否可弃不可判定」）。→ 直接可吸收进 `ProjectRecipes` 的安全门与 `DevActivityTracker` 的活跃窗口。
8. **孤儿残留的判定锚点**：App Support/Containers 的残留清理以「bundle 精确匹配 + 宿主 App 已卸载」为证据，拒绝厂商前缀/通用词/通配符扩散；helper 文件只在「重扫全部 LaunchDaemons/Agents 后仍无引用」时才清。→ 对我们未来的「残留发现」配方是现成的判据设计。

## 4. 覆盖对照总表

| 领域 | Mole | 我们 | 差距动作 |
| --- | --- | --- | --- |
| Xcode 派生物 | DerivedData/Archives/DeviceSupport(×3 平台, keep 2)/IB Support/CoreDevice/Previews/XCTestDevices/Docs | 有 iOS+watchOS 版本，缺 tvOS/IB/CoreDevice | 补 3 配方 + 评估 keep-2 |
| 模拟器 | Devices/孤儿运行时(simctl join)/dyld | Devices/Volumes/dyld ✅ | 复核孤儿判定边界 |
| 包管理器 | ~40 个工具，owner-command 优先 | 5 个，纯路径删除 | 扩族 + ownerCommand 机制 |
| VM/容器 | Docker/OrbStack/Lima/Colima/tart（报告为主） | 无 | 增加监视清单 |
| 本地大模型 | Ollama/LM Studio（默认白名单保护+报告） | 无 | 增加监视清单（保护性） |
| iOS 生态 | 备份/固件/Mail 附件/设备固件 ipsw | 无 | 补 displayOnly 配方 |
| 国产 IM | 微信/QQ/钉钉/飞书等 ~20 个具名清理 | 无（通用 Caches 兜不住 App Support 里的） | 新配方族 |
| Electron 新缓存 | Dawn/Graphite/GPU/Code Cache 家族 | 无 | 纳入 App 缓存子分类 |
| 浏览器旧版本 | Chromium 三家 + Edge 更新器特例 | 无 | 低优先配方 |
| 系统层 | 统一日志/崩溃报告/GPU 编译缓存/icon services | 无 | 补配方（注意权限） |
| 安装包 | 7 个非常规位置 | 无 | 增长归因新类别 |
| 项目产物 | purge + 密钥/嵌套 git/tracked 保护 | node_modules/dist/build ✅ | 吸收安全门 |
| 进程信号 | 僵尸进程归因 | ProcessGuard（清理侧） | 增长侧可加僵尸信号 |
| 诚实计量 | 估算+实测、超时部分结果纪律 | actualFreedBytes ✅ | 纪律已同级 |

## 5. 落地建议（按 收益/风险 比排序）

1. **零风险监视清单（displayOnly + 保护）**：MobileSync 备份、Docker/OrbStack/Lima、Ollama/LM Studio 模型、Go module、Maven/NuGet。只报告增长，永不进清理集。这一步就把「我们没注意到的原因」变成产品能力。
2. **Xcode 三连补丁**：tvOS DeviceSupport、IB Support、CoreDevice 缓存；顺手评估 DeviceSupport keep-2 策略。
3. **包管理器配方族扩容**（Go 构建缓存、Gradle、Cargo registry/cache、Yarn/bun、conda 五位置）+ `ownerCommand` 字段改造。
4. **表面扫描根增补**：`~/anaconda3`、`~/go`、`~/Library/Group Containers`、`~/Library/iTunes`、`~/Library/Mobile Documents`（一级即可）；App Support 考虑扫描**二级**具名子目录（国产 IM 的缓存都在二级）。
5. **国产 IM/Electron 缓存配方族**：参考 §2.5/§2.6 的路径事实自建；按我们三级安全分级标注（多数 `requiresQuit` + Trash）。
6. **增长归因新类别**：安装包落地（§2.10 的位置清单）、崩溃报告/统一日志（提示型）、Time Machine 本地快照计数（解释「删了文件空间没回来」）。
7. **纪律制度化**：把 Mole 的「新目标准入 = 实测值 + non-target 清单」「未知进程态 = 拒绝」「超时结果不进删除循环」写进我们的 CONTRIBUTING/设计文档。

## 6. 一句话回望

Mole 用两万行 shell 换来的是一张**「哪里会藏东西」的实测地图**和一套**「什么绝对不能碰」的禁区清单**；我们的水线守护器缺的从来不是清理引擎，而是这张地图——本文 §2 就是抄近路的版本。
