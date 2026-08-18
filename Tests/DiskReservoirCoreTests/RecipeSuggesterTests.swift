import Testing
import Foundation
@testable import DiskReservoirCore

private func entry(_ pattern: String, _ delta: Int64, _ path: String, at date: Date = Date()) -> GrowthEntry {
    GrowthEntry(
        observedAt: date, elapsedDays: 1, name: "x", path: path,
        pattern: pattern, kind: .surface, deltaBytes: delta, rateBytesPerDay: Double(delta)
    )
}

private func sample(_ id: String, total: Int64, status: CandidateStatus = .pending) -> CandidateRecipe {
    CandidateRecipe(
        id: id, pattern: id, status: status, totalGrowthBytes: total,
        peakRateBytesPerDay: 1, evidenceCount: 1, firstSeenAt: Date(), lastSeenAt: Date(),
        suggestedSafety: .userConfirm, suggestedCleanability: .displayOnly,
        suggestedCategory: .custom, samplePath: id
    )
}

@Test func suggesterClustersSurfaceGrowthAndSkipsCoveredPatterns() {
    let now = Date()
    let entries = [
        entry("~/Library/Caches/NewTool/*", 600 << 20, "/Users/alice/Library/Caches/NewTool/cache", at: now),
        entry("~/Library/Caches/NewTool/*", 200 << 20, "/Users/alice/Library/Caches/NewTool/other", at: now),
        entry("~/Library/Developer/Xcode/DerivedData/*", 900 << 20, "/Users/alice/Library/Developer/Xcode/DerivedData/HASH", at: now),
    ]
    let coveredRecipe = Recipe(
        id: "deriveddata", name: "DerivedData", category: .xcode, safety: .safeWhileRunning,
        disposition: .deletePermanently, cleanability: .regenerable,
        defaultAgeDays: 7, minimumSizeMB: 0, processName: nil,
        resolvePaths: { _ in ["/Users/alice/Library/Developer/Xcode/DerivedData"] }
    )
    let candidates = RecipeSuggester(minTotalBytes: 100 << 20)
        .suggest(entries: entries, existingRecipes: [coveredRecipe], homeDirectory: "/Users/alice")
    #expect(candidates.count == 1)
    #expect(candidates[0].pattern == "~/Library/Caches/NewTool/*")
    #expect(candidates[0].totalGrowthBytes == 800 << 20)
    #expect(candidates[0].evidenceCount == 2)
    #expect(candidates[0].suggestedSafety == .safeWhileRunning)
    #expect(candidates[0].status == .pending)
}

@Test func suggesterRespectsMinimumAndTopK() {
    let entries = [
        entry("~/a", 900 << 20, "/Users/alice/a"),
        entry("~/b", 700 << 20, "/Users/alice/b"),
        entry("~/c", 100 << 20, "/Users/alice/c"),
    ]
    let candidates = RecipeSuggester(minTotalBytes: 500 << 20, topK: 1)
        .suggest(entries: entries, existingRecipes: [], homeDirectory: "/Users/alice")
    #expect(candidates.count == 1)
    #expect(candidates[0].pattern == "~/a")
}

@Test func suggestionStorePreservesUserDecisions() throws {
    let base = FileManager.default.temporaryDirectory
        .appendingPathComponent("pp-suggest-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: base) }
    let paths = StoragePaths(baseURL: base)
    let store = RecipeSuggestionStore(paths: paths)
    try store.merge([sample("~/p", total: 1)])
    try store.setStatus(id: "~/p", status: .accepted)
    #expect(try store.load().first?.status == .accepted)
    try store.merge([sample("~/p", total: 2)])
    #expect(try store.load().first?.status == .accepted)
    #expect(try store.load().first?.totalGrowthBytes == 2)
}
