import Foundation

/// 监视清单配方（watchOnly，docs/superpowers/plans/2026-09-24-mole-informed-improvements.md §1.2）。
///
/// 这些条目是「下载即资产」或 daemon 管理的数据：参与扫描、归因与满盘预测，
/// 但 `Cleanability.watchOnly` 使它们被清理引擎与建议器硬排除——只监视增长，
/// 永不清理、永不建议。准入遵循增长证据门槛：只收录跳变型或持续型增长显著的条目
/// （conda pkgs、Maven/NuGet、统一日志、iOS 固件等缓慢/一次性增长项留在
/// AttributionCatalog 的 info 层，不建配方）。
public enum WatchRecipes {
    public static let all: [Recipe] = [
        iosDeviceBackups,
        dockerDesktopData,
        vmData,
        localAIModels,
    ]

    /// iOS 设备备份：每台设备可达数十 GB，备份时 GB 级跳变。
    static let iosDeviceBackups = Recipe(
        id: "ios-device-backups",
        name: "iOS 设备备份",
        category: .asset,
        group: .assets,
        safety: .userConfirm,
        disposition: .none,
        cleanability: .watchOnly,
        defaultAgeDays: 30,
        minimumSizeMB: 200,
        processName: nil,
        resolvePaths: { paths in
            [paths.homeDirectory + "/Library/Application Support/MobileSync/Backup"]
        }
    )

    /// Docker Desktop 数据：Docker.raw 只增不减，空间回收属于 daemon 域
    /// （docker system prune），宿主侧只做监视。
    static let dockerDesktopData = Recipe(
        id: "docker-desktop-data",
        name: "Docker Desktop 数据",
        category: .asset,
        group: .assets,
        safety: .userConfirm,
        disposition: .none,
        cleanability: .watchOnly,
        defaultAgeDays: 30,
        minimumSizeMB: 200,
        processName: nil,
        resolvePaths: { paths in
            [paths.homeDirectory + "/Library/Containers/com.docker.docker/Data"]
        }
    )

    /// 虚拟机数据：OrbStack（Group Containers 内 `*.dev.orbstack`）、Lima、Colima。
    /// 容器运行期增长快，镜像与磁盘属各 VM 工具管理。
    static let vmData = Recipe(
        id: "vm-data",
        name: "虚拟机数据",
        category: .asset,
        group: .assets,
        safety: .userConfirm,
        disposition: .none,
        cleanability: .watchOnly,
        defaultAgeDays: 30,
        minimumSizeMB: 200,
        processName: nil,
        aggregatesPaths: true,
        resolvePaths: { paths in
            var result: [String] = []
            let groupContainers = paths.homeDirectory + "/Library/Group Containers"
            if let children = try? FileManager.default.contentsOfDirectory(atPath: groupContainers) {
                result += children
                    .filter { $0.hasSuffix("dev.orbstack") }
                    .map { groupContainers + "/" + $0 }
            }
            result.append(paths.homeDirectory + "/.lima")
            result.append(paths.homeDirectory + "/.colima")
            return result
        }
    )

    /// 本地大模型：下载时 GB 级跳变；模型权重是资产而非缓存。
    /// LM Studio ≤0.3.5 曾把整个用户目录放在 ~/.cache/lm-studio（含聊天记录）——
    /// 「目录名带 cache」不可信，这正是 watchOnly 存在的理由。
    static let localAIModels = Recipe(
        id: "local-ai-models",
        name: "本地大模型",
        category: .asset,
        group: .assets,
        safety: .userConfirm,
        disposition: .none,
        cleanability: .watchOnly,
        defaultAgeDays: 30,
        minimumSizeMB: 200,
        processName: nil,
        aggregatesPaths: true,
        resolvePaths: { paths in
            [
                paths.homeDirectory + "/.ollama/models",
                paths.homeDirectory + "/.lmstudio/models",
            ]
        }
    )

    /// 用户添加的监视目录（增长建议采纳后纳入）：与内置监视配方同级语义，
    /// watchOnly 硬排除确保用户添加路径绝不因「采纳建议」而升级为可清理。
    public static let customWatchID = "watch-assets-custom"

    public static func makeCustom(extraRoots: [String]) -> Recipe {
        Recipe(
            id: customWatchID,
            name: "用户添加的监视目录",
            category: .asset,
            group: .assets,
            safety: .userConfirm,
            disposition: .none,
            cleanability: .watchOnly,
            defaultAgeDays: 30,
            minimumSizeMB: 200,
            processName: nil,
            aggregatesPaths: true,
            resolvePaths: { _ in Array(Set(extraRoots)).sorted() }
        )
    }
}
