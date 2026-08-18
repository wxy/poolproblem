import Foundation

/// 从增长台账聚合成候选配方：
/// 只考虑表面扫描条目，过滤已被内置配方覆盖的路径模式，按累计增长排序取前 K。
public struct RecipeSuggester: Sendable {
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
        let covered = existingRecipes
            .flatMap { $0.resolvePaths(StoragePaths(baseURL: nil, homeDirectory: homeDirectory)) }
            .map { PathPatternizer.patternize($0, homeDirectory: homeDirectory) }
        func isCovered(_ pattern: String) -> Bool {
            covered.contains { $0 == pattern || pattern.hasPrefix($0 + "/") }
        }
        var grouped: [String: [GrowthEntry]] = [:]
        for entry in entries where entry.kind == .surface && entry.deltaBytes > 0 {
            guard !isCovered(entry.pattern) else { continue }
            grouped[entry.pattern, default: []].append(entry)
        }
        let candidates: [CandidateRecipe] = grouped.compactMap { pattern, group in
            let total = group.reduce(Int64(0)) { $0 + $1.deltaBytes }
            guard total >= minTotalBytes else { return nil }
            let sorted = group.sorted { $0.observedAt < $1.observedAt }
            let cacheish = pattern.contains("/Caches/")
                || pattern.contains("/Logs/")
                || pattern.contains("/DerivedData")
                || pattern.hasPrefix("~/.cache")
            return CandidateRecipe(
                id: pattern,
                pattern: pattern,
                totalGrowthBytes: total,
                peakRateBytesPerDay: group.map(\.rateBytesPerDay).max() ?? 0,
                evidenceCount: group.count,
                firstSeenAt: sorted.first?.observedAt ?? Date(),
                lastSeenAt: sorted.last?.observedAt ?? Date(),
                suggestedSafety: cacheish ? .safeWhileRunning : .userConfirm,
                suggestedCleanability: cacheish ? .regenerable : .displayOnly,
                suggestedCategory: .custom,
                samplePath: group.first?.path ?? pattern
            )
        }
        return candidates
            .sorted { $0.totalGrowthBytes > $1.totalGrowthBytes }
            .prefix(topK)
            .map { $0 }
    }
}
