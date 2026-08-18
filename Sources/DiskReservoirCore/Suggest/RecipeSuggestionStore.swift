import Foundation

/// 候选配方持久化：按 id（模式）合并，保留用户已做的采纳/忽略决定。
public struct RecipeSuggestionStore: Sendable {
    private let paths: StoragePaths
    private let store: JSONStoring

    public init(paths: StoragePaths, store: JSONStoring = JSONStore()) {
        self.paths = paths
        self.store = store
    }

    public func load() throws -> [CandidateRecipe] {
        try store.load([CandidateRecipe].self, from: paths.recipeSuggestionsURL) ?? []
    }

    /// upsert：已有条目保留原 status 并更新统计；新条目插入。
    public func merge(_ candidates: [CandidateRecipe]) throws {
        var byID = Dictionary(uniqueKeysWithValues: try load().map { ($0.id, $0) })
        for candidate in candidates {
            if let existing = byID[candidate.id] {
                byID[candidate.id] = CandidateRecipe(
                    id: existing.id,
                    pattern: existing.pattern,
                    status: existing.status,
                    totalGrowthBytes: candidate.totalGrowthBytes,
                    peakRateBytesPerDay: candidate.peakRateBytesPerDay,
                    evidenceCount: candidate.evidenceCount,
                    firstSeenAt: candidate.firstSeenAt,
                    lastSeenAt: candidate.lastSeenAt,
                    suggestedSafety: candidate.suggestedSafety,
                    suggestedCleanability: candidate.suggestedCleanability,
                    suggestedCategory: candidate.suggestedCategory,
                    samplePath: candidate.samplePath
                )
            } else {
                byID[candidate.id] = candidate
            }
        }
        try store.save(Array(byID.values), to: paths.recipeSuggestionsURL)
    }

    public func setStatus(id: String, status: CandidateStatus) throws {
        var all = try load()
        guard let index = all.firstIndex(where: { $0.id == id }) else { return }
        all[index].status = status
        try store.save(all, to: paths.recipeSuggestionsURL)
    }
}
