import Foundation

/// 监视清单配方（watchOnly，docs/superpowers/plans/2026-09-24-mole-informed-improvements.md §1.2）。
///
/// 这些条目是「下载即资产」或 daemon 管理的数据：参与扫描与容量归因，
/// 但 `Cleanability.watchOnly` 使它们在所有清理入口中都不可操作。
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

    /// Docker Desktop 数据由 daemon 管理，宿主侧只做监视。
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
    /// 目录名含 cache 不足以证明内容可再生，模型权重只做监视。
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
}
