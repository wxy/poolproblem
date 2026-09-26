import Foundation

/// 包管理器缓存配方族：npm / pnpm / uv / CocoaPods / Homebrew 等
/// “可再生的全局缓存”归为一个配方，多路径聚合为一个清理条目。
/// 与项目内 node_modules（进回收站、需用户确认、活跃窗口保护）性质不同：
/// 全局包管理器缓存可安全永久删除。
/// 用户可在增长洞察中把新发现的缓存目录加入该配方作用域（extraRoots）。
public enum PackageManagerRecipes {
    public static let familyID = "package-manager-caches"

    public static func defaultPaths(homeDirectory: String) -> [String] {
        // 准入遵循增长证据门槛与恢复契约（方案 §1.3）。明确不纳入的 non-target：
        // - `~/go/pkg/mod`：Go 模块缓存，文件只读，owner 命令 `go clean -modcache`
        //   才是文档化重置路径（ownerCommand 机制接入后单独处理）；
        // - `~/.cargo/registry/src`：解压源码是混合态，可能被离线构建直接消费；
        // - `~/.cargo/.crates.toml` / `.crates2.json`：cargo 安装清单，删除会孤儿化已装二进制；
        // - `~/.gradle/caches`：daemon 常驻，见独立 gradle-caches 配方。
        [
            homeDirectory + "/.npm",
            homeDirectory + "/Library/pnpm",
            homeDirectory + "/.cache/uv",
            // Go 构建缓存：纯再生，重建成本只是重新编译
            homeDirectory + "/.cache/go-build",
            // 仅 registry/cache（压缩包镜像）；registry/src 是 non-target
            homeDirectory + "/.cargo/registry/cache",
            homeDirectory + "/.yarn/berry/cache",
            homeDirectory + "/.bun/install/cache",
            homeDirectory + "/Library/Caches/CocoaPods",
            homeDirectory + "/Library/Caches/Homebrew",
        ]
    }

    /// Gradle 缓存独立配方：daemon 可能长期常驻并持有缓存锁，不适合
    /// 「safeWhileRunning + 永久删除」的族默认。降级为 userConfirm + 回收站，
    /// 不授予无人值守永久删除；用户手动确认时逐项进回收站，可恢复。
    public static let gradleCacheID = "gradle-caches"

    public static func makeGradle() -> Recipe {
        Recipe(
            id: gradleCacheID,
            name: "Gradle 缓存",
            category: .packageManager,
            group: .packageManager,
            safety: .userConfirm,
            disposition: .trash,
            cleanability: .regenerable,
            defaultAgeDays: 30,
            minimumSizeMB: 100,
            processName: nil,
            allowsAutomaticPermanentDeletion: false,
            resolvePaths: { paths in [paths.homeDirectory + "/.gradle/caches"] }
        )
    }

    /// Go 模块缓存：文件只读、owner 文档化重置（`go clean -modcache`）。
    /// owner 命令失败（go 不可用）时降级为逐路径删除——只读目录使 unlink
    /// 自然失败，等于天然失败安全；两种路径都不会破坏 envs 的硬链接。
    public static let goModuleCacheID = "go-module-caches"

    public static func makeGoModule() -> Recipe {
        Recipe(
            id: goModuleCacheID,
            name: "Go 模块缓存",
            category: .packageManager,
            group: .packageManager,
            safety: .safeWhileRunning,
            disposition: .deletePermanently,
            cleanability: .regenerable,
            defaultAgeDays: 30,
            minimumSizeMB: 100,
            processName: nil,
            allowsAutomaticPermanentDeletion: true,
            ownerCommand: OwnerCommand(executable: "go", arguments: ["clean", "-modcache"]),
            resolvePaths: { paths in [paths.homeDirectory + "/go/pkg/mod"] }
        )
    }

    public static func make(
        extraRoots: [String],
        homeDirectory: String
    ) -> Recipe {
        let paths = Array(
            Set(defaultPaths(homeDirectory: homeDirectory) + extraRoots)
        ).sorted()
        return Recipe(
            id: familyID,
            name: "包管理器缓存",
            category: .packageManager,
            group: .packageManager,
            safety: .safeWhileRunning,
            disposition: .deletePermanently,
            cleanability: .regenerable,
            defaultAgeDays: 30,
            minimumSizeMB: 10,
            processName: nil,
            aggregatesPaths: true,
            allowsAutomaticPermanentDeletion: true,
            resolvePaths: { _ in paths }
        )
    }

    /// User-added paths remain manual-only even when they look like package
    /// manager caches. Classification confidence must not silently expand the
    /// unattended deletion boundary.
    public static func makeCustom(extraRoots: [String]) -> Recipe {
        Recipe(
            id: "package-manager-custom",
            name: "用户添加的包管理器缓存",
            category: .packageManager,
            group: .packageManager,
            safety: .userConfirm,
            disposition: .trash,
            cleanability: .regenerable,
            defaultAgeDays: 30,
            minimumSizeMB: 10,
            processName: nil,
            aggregatesPaths: true,
            resolvePaths: { _ in Array(Set(extraRoots)).sorted() }
        )
    }
}
