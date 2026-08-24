import Foundation

/// 包管理器缓存配方族：npm / pnpm / uv / CocoaPods / Homebrew 等
/// “可再生的全局缓存”归为一个配方，多路径聚合为一个清理条目。
/// 与项目内 node_modules（进回收站、需用户确认、活跃窗口保护）性质不同：
/// 全局包管理器缓存可安全永久删除。
/// 用户可在增长洞察中把新发现的缓存目录加入该配方作用域（extraRoots）。
public enum PackageManagerRecipes {
    public static let familyID = "package-manager-caches"

    public static func defaultPaths(homeDirectory: String) -> [String] {
        [
            homeDirectory + "/.npm",
            homeDirectory + "/Library/pnpm",
            homeDirectory + "/.cache/uv",
            homeDirectory + "/Library/Caches/CocoaPods",
            homeDirectory + "/Library/Caches/Homebrew",
        ]
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
            safety: .safeWhileRunning,
            disposition: .deletePermanently,
            cleanability: .regenerable,
            defaultAgeDays: 30,
            minimumSizeMB: 10,
            processName: nil,
            aggregatesPaths: true,
            resolvePaths: { _ in paths }
        )
    }
}
