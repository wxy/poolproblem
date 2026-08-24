import Foundation

/// 从增长台账发现“符合现有配方类型、但尚未纳入其管理范围”的目录：
/// 只考虑表面扫描条目，过滤已被配方覆盖的路径，再判断是否命中现有
/// 可扩展配方（当前为项目目录配方族：node_modules / 构建产物）。命中后
/// 按项目根聚合成候选，采纳时把该目录加入现有配方的管理范围（devRoots）。
public struct RecipeSuggester: Sendable {
    /// 项目目录配方族的稳定标识（采纳时加入 devRoots，同时扩展
    /// “node_modules”与“项目构建产物”两个配方的作用域）。
    public static let projectFamilyID = "project-recipes"
    /// 项目目录配方族的展示名（英文回退，UI 按 recipeID 本地化）。
    public static let projectFamilyName = "node_modules / Project build output"

    public let minTotalBytes: Int64
    public let topK: Int

    public init(minTotalBytes: Int64 = 500 << 20, topK: Int = 5) {
        self.minTotalBytes = minTotalBytes
        self.topK = topK
    }

    public func suggest(
        entries: [GrowthEntry],
        existingRecipes: [Recipe],
        homeDirectory: String = NSHomeDirectory()
    ) -> [CandidateRecipe] {
        let covered = RecipeCoverage.coveredPatterns(
            recipes: existingRecipes,
            homeDirectory: homeDirectory
        )
        func isCovered(_ pattern: String) -> Bool {
            covered.contains { $0 == pattern || pattern.hasPrefix($0 + "/") }
        }
        // 未覆盖增长按“所属项目根”聚合：一条增长可能来自项目目录本身或其子目录。
        var byRoot: [String: [GrowthEntry]] = [:]
        for entry in entries where entry.kind == .surface && entry.deltaBytes > 0 {
            guard !isCovered(entry.pattern) else { continue }
            guard let root = projectRoot(for: entry.path, homeDirectory: homeDirectory) else { continue }
            byRoot[root, default: []].append(entry)
        }
        let candidates: [CandidateRecipe] = byRoot.compactMap { root, group in
            let total = group.reduce(Int64(0)) { $0 + $1.deltaBytes }
            guard total >= minTotalBytes else { return nil }
            let sorted = group.sorted { $0.observedAt < $1.observedAt }
            let pattern = PathPatternizer.patternize(root, homeDirectory: homeDirectory)
            return CandidateRecipe(
                id: pattern,
                pattern: pattern,
                totalGrowthBytes: total,
                peakRateBytesPerDay: group.map(\.rateBytesPerDay).max() ?? 0,
                evidenceCount: group.count,
                firstSeenAt: sorted.first?.observedAt ?? Date(),
                lastSeenAt: sorted.last?.observedAt ?? Date(),
                recipeID: Self.projectFamilyID,
                recipeName: Self.projectFamilyName,
                // 项目配方族的既有规则：需用户确认、可再生、进回收站。
                suggestedSafety: .userConfirm,
                suggestedCleanability: .regenerable,
                suggestedCategory: .project,
                suggestedDisposition: .trash,
                samplePath: root
            )
        }
        return candidates
            .sorted { $0.totalGrowthBytes > $1.totalGrowthBytes }
            .prefix(topK)
            .map { $0 }
    }

    /// 判断一条增长路径是否属于一个可纳入项目配方族的项目根：
    /// 路径本身是项目（散落项目），或其父目录是项目（增长来自项目内子目录）。
    private func projectRoot(for path: String, homeDirectory: String) -> String? {
        if DevDirectoryDetector.detect(path: path) != nil { return path }
        let parent = URL(fileURLWithPath: path).deletingLastPathComponent().path
        guard parent != path, DevDirectoryDetector.detect(path: parent) != nil else { return nil }
        return parent
    }
}
