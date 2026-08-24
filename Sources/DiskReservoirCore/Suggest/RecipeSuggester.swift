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
    /// 项目目录配方族建议统一的规则（采纳后按 devRoots 展开项目配方）。
    public static let projectFamilySafety = SafetyLevel.userConfirm
    public static let projectFamilyCleanability = Cleanability.regenerable
    public static let projectFamilyDisposition = CleanDisposition.trash
    /// 包管理器缓存配方族（全局可再生缓存，可安全永久删除）。
    public static let packageManagerFamilyID = PackageManagerRecipes.familyID
    public static let packageManagerFamilyName = "Package manager caches"

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
            covered.contains { root in
                root == pattern || pattern.hasPrefix(root + "/")
            } || covered.contains { root in
                root.hasPrefix(pattern + "/") && !root.dropFirst(pattern.count + 1).contains("/")
            }
        }
        // 未覆盖增长按“所属项目根”聚合：一条增长可能来自项目目录本身或其子目录。
        var byRoot: [String: [GrowthEntry]] = [:]
        var cacheCandidates: [CandidateRecipe] = []
        for entry in entries where entry.kind == .surface && entry.deltaBytes > 0 {
            guard !isCovered(entry.pattern) else { continue }
            if let root = projectRoot(for: entry.path, homeDirectory: homeDirectory) {
                byRoot[root, default: []].append(entry)
            } else if let cache = packageManagerCandidate(
                for: entry,
                homeDirectory: homeDirectory
            ) {
                cacheCandidates.append(cache)
            }
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
                source: .growth,
                samplePath: root
            )
        }
        return (candidates + cacheCandidates)
            .sorted { $0.totalGrowthBytes > $1.totalGrowthBytes }
            .prefix(topK)
            .map { $0 }
    }

    /// 未覆盖增长中形如 `~/.cache/<工具>` 的缓存目录 → 归入“包管理器缓存”
    /// 配方族（采纳后按“可自动清理 / 永久删除”规则管理）。
    private func packageManagerCandidate(
        for entry: GrowthEntry,
        homeDirectory: String
    ) -> CandidateRecipe? {
        let path = entry.path
        let home = homeDirectory.hasSuffix("/") ? homeDirectory : homeDirectory + "/"
        // 只识别家目录下的 ~/.cache/<工具>：这类是全局工具/包管理器缓存；
        // 项目内或更深层的 .cache 不归入该配方族。
        let cacheish = path.hasPrefix(home + ".cache/")
        guard cacheish else { return nil }
        let pattern = PathPatternizer.patternize(path, homeDirectory: homeDirectory)
        return CandidateRecipe(
            id: pattern,
            pattern: pattern,
            totalGrowthBytes: entry.deltaBytes,
            peakRateBytesPerDay: entry.rateBytesPerDay,
            evidenceCount: 1,
            firstSeenAt: entry.observedAt,
            lastSeenAt: entry.observedAt,
            recipeID: Self.packageManagerFamilyID,
            recipeName: Self.packageManagerFamilyName,
            suggestedSafety: .safeWhileRunning,
            suggestedCleanability: .regenerable,
            suggestedCategory: .packageManager,
            suggestedDisposition: .deletePermanently,
            source: .growth,
            samplePath: path
        )
    }

    /// 判断一条增长路径是否属于一个可纳入项目配方族的项目根：
    /// 路径本身是项目（散落项目），或其父目录是项目（增长来自项目内子目录）。
    private func projectRoot(for path: String, homeDirectory: String) -> String? {
        if DevDirectoryDetector.detect(path: path) != nil { return path }
        let parent = URL(fileURLWithPath: path).deletingLastPathComponent().path
        guard parent != path, DevDirectoryDetector.detect(path: parent) != nil else { return nil }
        return parent
    }

    /// 主动发现（可再生产物大小）→ 项目目录配方族候选。
    public static func discoveryCandidates(
        discovered: [DevProjectCandidate],
        homeDirectory: String
    ) -> [CandidateRecipe] {
        discovered.map { project in
            let pattern = PathPatternizer.patternize(project.path, homeDirectory: homeDirectory)
            return CandidateRecipe(
                id: pattern,
                pattern: pattern,
                totalGrowthBytes: project.regenerableBytes,
                peakRateBytesPerDay: 0,
                evidenceCount: 1,
                firstSeenAt: Date(),
                lastSeenAt: Date(),
                recipeID: projectFamilyID,
                recipeName: projectFamilyName,
                suggestedSafety: projectFamilySafety,
                suggestedCleanability: projectFamilyCleanability,
                suggestedCategory: .project,
                suggestedDisposition: projectFamilyDisposition,
                source: .discovery,
                samplePath: project.path
            )
        }
    }

    /// 近期写活动（FSEvents）→ 项目目录配方族候选。
    public static func activityCandidates(
        activities: [DevActivity],
        homeDirectory: String
    ) -> [CandidateRecipe] {
        activities.map { activity in
            let pattern = PathPatternizer.patternize(
                activity.projectRoot,
                homeDirectory: homeDirectory
            )
            return CandidateRecipe(
                id: pattern,
                pattern: pattern,
                totalGrowthBytes: 0,
                peakRateBytesPerDay: 0,
                evidenceCount: 1,
                firstSeenAt: activity.lastActivityAt,
                lastSeenAt: activity.lastActivityAt,
                recipeID: projectFamilyID,
                recipeName: projectFamilyName,
                suggestedSafety: projectFamilySafety,
                suggestedCleanability: projectFamilyCleanability,
                suggestedCategory: .project,
                suggestedDisposition: projectFamilyDisposition,
                source: .activity,
                samplePath: activity.projectRoot
            )
        }
    }

    /// 把多来源候选归并成展示级建议：
    /// 1) 同一父目录下有 ≥2 个建议 → 合并为父目录一条（一次采纳覆盖全部），
    ///    但父目录为家目录/根目录时不合并（避免把整个家目录纳入监控）。
    /// 2) 相同路径的多来源候选合并统计。
    /// 3) 祖先/后代重叠时保留父目录建议（覆盖更广），丢弃仅落在其内的子建议。
    public static func normalize(
        _ candidates: [CandidateRecipe],
        homeDirectory: String
    ) -> [CandidateRecipe] {
        var byParent: [String: [CandidateRecipe]] = [:]
        var homeLevel: [CandidateRecipe] = []
        for candidate in candidates {
            // 父目录归并只用于项目配方族：把多个项目合并为一个开发根是安全的
            // （ProjectRecipes 按子项目展开）；包管理器缓存若归并到父目录，
            // 会把整个 ~/.cache 纳入永久删除范围，风险过大，保持逐目录建议。
            guard candidate.recipeID == projectFamilyID else {
                homeLevel.append(candidate)
                continue
            }
            let parent = URL(fileURLWithPath: candidate.samplePath)
                .deletingLastPathComponent().path
            if parent == homeDirectory || parent == "/" {
                // 家目录/根目录下的散落项目保持单独建议（避免把整个家目录纳入监控）
                homeLevel.append(candidate)
                continue
            }
            byParent[parent, default: []].append(candidate)
        }
        var grouped: [CandidateRecipe] = []
        grouped.append(contentsOf: homeLevel)
        for (parent, group) in byParent {
            if group.count >= 2 {
                let names = Array(Set(
                    group.compactMap { URL(fileURLWithPath: $0.samplePath).lastPathComponent }
                )).sorted()
                grouped.append(merged(group, path: parent, homeDirectory: homeDirectory, childNames: names))
            } else if let single = group.first {
                grouped.append(single)
            }
        }
        // 同路径合并
        var byPath: [String: CandidateRecipe] = [:]
        for candidate in grouped {
            if let existing = byPath[candidate.samplePath] {
                let names = Array(Set(existing.childNames + candidate.childNames)).sorted()
                byPath[candidate.samplePath] = merged(
                    [existing, candidate],
                    path: candidate.samplePath,
                    homeDirectory: homeDirectory,
                    childNames: names
                )
            } else {
                byPath[candidate.samplePath] = candidate
            }
        }
        // 按路径深度排序后保留最浅的覆盖建议
        let depthSorted = byPath.values.sorted { $0.samplePath.count < $1.samplePath.count }
        var kept: [CandidateRecipe] = []
        for candidate in depthSorted {
            if kept.contains(where: { candidate.samplePath.hasPrefix($0.samplePath + "/") }) {
                continue
            }
            kept.append(candidate)
        }
        return kept.sorted { $0.totalGrowthBytes > $1.totalGrowthBytes }
    }

    private static func merged(
        _ group: [CandidateRecipe],
        path: String,
        homeDirectory: String,
        childNames: [String]
    ) -> CandidateRecipe {
        let first = group[0]
        let pattern = PathPatternizer.patternize(path, homeDirectory: homeDirectory)
        return CandidateRecipe(
            id: pattern,
            pattern: pattern,
            totalGrowthBytes: group.reduce(Int64(0)) { $0 + $1.totalGrowthBytes },
            peakRateBytesPerDay: group.map(\.peakRateBytesPerDay).max() ?? 0,
            evidenceCount: group.reduce(0) { $0 + $1.evidenceCount },
            firstSeenAt: group.map(\.firstSeenAt).min() ?? Date(),
            lastSeenAt: group.map(\.lastSeenAt).max() ?? Date(),
            recipeID: first.recipeID,
            recipeName: first.recipeName,
            suggestedSafety: first.suggestedSafety,
            suggestedCleanability: first.suggestedCleanability,
            suggestedCategory: first.suggestedCategory,
            suggestedDisposition: first.suggestedDisposition,
            source: first.source,
            childNames: childNames,
            samplePath: path
        )
    }
}
