import Foundation

/// 包管理器缓存配方族：npm / uv / CocoaPods / Homebrew 等。
/// pnpm store 由独立的手动官方命令配方管理，绝不按路径删除。
/// “可再生的全局缓存”归为一个配方，多路径聚合为一个清理条目。
/// 与项目内 node_modules（进回收站、需用户确认、活跃窗口保护）性质不同：
/// 全局包管理器缓存可安全永久删除。
/// 用户可在增长洞察中把新发现的缓存目录加入该配方作用域（extraRoots）。
public enum PackageManagerRecipes {
    public static let familyID = "package-manager-caches"
    public static let customID = "package-manager-custom"

    /// Reject old snapshot targets too; removing the path from current scan
    /// recipes alone does not invalidate persisted aggregate scan items.
    public static func isLegacyPnpmPath(_ path: String, homeDirectory: String) -> Bool {
        let input = URL(fileURLWithPath: path).standardizedFileURL.path
        let candidate = URL(fileURLWithPath: path)
            .resolvingSymlinksInPath().standardizedFileURL.path
        // A saved aggregate may refer to an earlier HOME. Check path segments
        // as well as the current home's canonical root; the latter also catches
        // aliases into a symlinked pnpm directory.
        if [input, candidate].contains(where: { path in
            let lower = path.lowercased()
            return lower.hasSuffix("/library/pnpm") || lower.contains("/library/pnpm/")
        }) {
            return true
        }
        let root = URL(fileURLWithPath: homeDirectory + "/Library/pnpm")
            .resolvingSymlinksInPath().standardizedFileURL.path
        return candidate == root || candidate.hasPrefix(root + "/")
    }

    public static func defaultPaths(homeDirectory: String) -> [String] {
        [
            homeDirectory + "/.npm",
            homeDirectory + "/.cache/uv",
            homeDirectory + "/Library/Caches/CocoaPods",
            homeDirectory + "/Library/Caches/Homebrew",
        ]
    }

    /// Persisted aggregate paths are untrusted. The built-in family can only
    /// delete exact current default roots, even if an old scan included a
    /// parent directory or a formerly configured extra root.
    public static func isApprovedDefaultCachePath(_ path: String, homeDirectory: String) -> Bool {
        let target = URL(fileURLWithPath: path).standardizedFileURL.path
        return defaultPaths(homeDirectory: homeDirectory).contains {
            URL(fileURLWithPath: $0).standardizedFileURL.path == target
        }
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
            id: customID,
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
