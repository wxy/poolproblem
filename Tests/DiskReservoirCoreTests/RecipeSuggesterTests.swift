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
        recipeID: RecipeSuggester.projectFamilyID,
        recipeName: RecipeSuggester.projectFamilyName,
        suggestedSafety: .userConfirm, suggestedCleanability: .regenerable,
        suggestedCategory: .project, suggestedDisposition: .trash,
        samplePath: id
    )
}

/// 在临时目录创建带项目标记（package.json）的项目根。
private func makeProject(_ base: URL, _ name: String) throws -> URL {
    let dir = base.appendingPathComponent(name, isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try "{}".data(using: .utf8)!.write(to: dir.appendingPathComponent("package.json"))
    return dir
}

@Test func suggesterClustersProjectGrowthAndMapsToExistingRecipe() throws {
    let base = FileManager.default.temporaryDirectory
        .appendingPathComponent("pp-sug-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: base) }
    let home = base.appendingPathComponent("home", isDirectory: true)
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    let project = try makeProject(home.appendingPathComponent("develop", isDirectory: true), "my-app")

    let now = Date()
    let entries = [
        entry("~/develop/my-app/*", 600 << 20, project.path, at: now),
        entry("~/develop/my-app/*", 200 << 20, project.path, at: now),
    ]
    let candidates = RecipeSuggester(minTotalBytes: 100 << 20)
        .suggest(entries: entries, existingRecipes: [], homeDirectory: home.path)
    #expect(candidates.count == 1)
    #expect(candidates[0].samplePath == project.path)
    #expect(candidates[0].pattern == "~/develop/my-app")
    #expect(candidates[0].totalGrowthBytes == 800 << 20)
    #expect(candidates[0].evidenceCount == 2)
    // 归入现有“项目目录”配方族，而不是新建配方
    #expect(candidates[0].recipeID == RecipeSuggester.projectFamilyID)
    #expect(candidates[0].suggestedCategory == .project)
    #expect(candidates[0].suggestedSafety == .userConfirm)
    #expect(candidates[0].suggestedDisposition == .trash)
    #expect(candidates[0].status == .pending)
}

@Test func suggesterDetectsProjectRootFromChildGrowth() throws {
    let base = FileManager.default.temporaryDirectory
        .appendingPathComponent("pp-sug-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: base) }
    let home = base.appendingPathComponent("home", isDirectory: true)
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    let project = try makeProject(home.appendingPathComponent("work", isDirectory: true), "web")
    let child = project.appendingPathComponent("node_modules", isDirectory: true)

    let entries = [
        entry("~/work/web/node_modules/*", 700 << 20, child.path),
    ]
    let candidates = RecipeSuggester(minTotalBytes: 100 << 20)
        .suggest(entries: entries, existingRecipes: [], homeDirectory: home.path)
    #expect(candidates.count == 1)
    #expect(candidates[0].samplePath == project.path)
    #expect(candidates[0].pattern == "~/work/web")
}

@Test func suggesterIgnoresNonProjectGrowth() throws {
    let base = FileManager.default.temporaryDirectory
        .appendingPathComponent("pp-sug-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: base) }
    try FileManager.default.createDirectory(
        at: base.appendingPathComponent("archive", isDirectory: true),
        withIntermediateDirectories: true
    )

    let entries = [
        entry("~/Documents/archive", 700 << 20, base.appendingPathComponent("archive").path),
    ]
    let candidates = RecipeSuggester(minTotalBytes: 100 << 20)
        .suggest(entries: entries, existingRecipes: [], homeDirectory: "/Users/alice")
    // 没有可归入的现有配方 → 不产生配方建议（仅保留在增长记录中）
    #expect(candidates.isEmpty)
}

@Test func suggesterSkipsCoveredPatterns() throws {
    let base = FileManager.default.temporaryDirectory
        .appendingPathComponent("pp-sug-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: base) }
    let project = try makeProject(base, "app")

    let entries = [
        entry("~/Library/Developer/Xcode/DerivedData/*", 900 << 20, "/Users/alice/Library/Developer/Xcode/DerivedData/HASH"),
        entry("~/develop/app/*", 500 << 20, project.path),
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
    #expect(candidates[0].samplePath == project.path)
}

@Test func suggesterRespectsMinimumAndTopK() throws {
    let base = FileManager.default.temporaryDirectory
        .appendingPathComponent("pp-sug-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: base) }
    let a = try makeProject(base, "a")
    let b = try makeProject(base, "b")
    let c = try makeProject(base, "c")

    let entries = [
        entry("~/a", 900 << 20, a.path),
        entry("~/b", 700 << 20, b.path),
        entry("~/c", 100 << 20, c.path),
    ]
    let candidates = RecipeSuggester(minTotalBytes: 500 << 20, topK: 1)
        .suggest(entries: entries, existingRecipes: [], homeDirectory: "/Users/alice")
    #expect(candidates.count == 1)
    #expect(candidates[0].samplePath == a.path)
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
    #expect(try store.load().first?.recipeID == RecipeSuggester.projectFamilyID)
}

@Test func discoveryCandidatesMapToProjectRecipeFamily() {
    let base = FileManager.default.temporaryDirectory
        .appendingPathComponent("pp-sug-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: base) }
    let home = base.appendingPathComponent("home", isDirectory: true)
    let project = home.appendingPathComponent("develop/app", isDirectory: true)

    let candidates = RecipeSuggester.discoveryCandidates(
        discovered: [
            DevProjectCandidate(
                path: project.path,
                marker: "project",
                regenerableBytes: 300 << 20
            ),
        ],
        homeDirectory: home.path
    )
    #expect(candidates.count == 1)
    #expect(candidates[0].source == .discovery)
    #expect(candidates[0].recipeID == RecipeSuggester.projectFamilyID)
    #expect(candidates[0].suggestedCategory == .project)
    #expect(candidates[0].totalGrowthBytes == 300 << 20)
    #expect(candidates[0].samplePath == project.path)
    #expect(candidates[0].pattern == "~/develop/app")
}

@Test func activityCandidatesMapToProjectRecipeFamily() {
    let base = FileManager.default.temporaryDirectory
        .appendingPathComponent("pp-sug-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: base) }
    let home = base.appendingPathComponent("home", isDirectory: true)
    let root = home.appendingPathComponent("work/site", isDirectory: true)
    let when = Date(timeIntervalSince1970: 1_000_000)

    let candidates = RecipeSuggester.activityCandidates(
        activities: [
            DevActivity(projectRoot: root.path, artifact: "dist", lastActivityAt: when),
        ],
        homeDirectory: home.path
    )
    #expect(candidates.count == 1)
    #expect(candidates[0].source == .activity)
    #expect(candidates[0].recipeID == RecipeSuggester.projectFamilyID)
    #expect(candidates[0].samplePath == root.path)
    #expect(candidates[0].lastSeenAt == when)
}

@Test func normalizeGroupsSiblingsUnderParentAndKeepsHomeLevelSeparate() throws {
    let base = FileManager.default.temporaryDirectory
        .appendingPathComponent("pp-sug-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: base) }
    let home = base.appendingPathComponent("home", isDirectory: true)
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    let a = home.appendingPathComponent("develop/a", isDirectory: true)
    let b = home.appendingPathComponent("develop/b", isDirectory: true)
    let c = home.appendingPathComponent("c", isDirectory: true)

    let candidates = RecipeSuggester.normalize(
        [
            sample(a.path, total: 100 << 20),
            sample(b.path, total: 200 << 20),
            sample(c.path, total: 50 << 20),
        ],
        homeDirectory: home.path
    )
    // develop/a + develop/b → 合并为父目录一条；家目录下的 c 保持单独
    #expect(candidates.count == 2)
    let grouped = candidates.first { $0.samplePath == home.appendingPathComponent("develop").path }
    #expect(grouped != nil)
    #expect(grouped?.childNames == ["a", "b"])
    #expect(grouped?.totalGrowthBytes == 300 << 20)
    #expect(candidates.contains { $0.samplePath == c.path })
}

@Test func normalizeMergesSamePathFromMultipleSources() throws {
    let base = FileManager.default.temporaryDirectory
        .appendingPathComponent("pp-sug-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: base) }
    let home = base.appendingPathComponent("home", isDirectory: true)
    let root = home.appendingPathComponent("develop/app", isDirectory: true)

    let candidates = RecipeSuggester.normalize(
        [
            sample(root.path, total: 400 << 20),
            sample(root.path, total: 100 << 20),
        ],
        homeDirectory: home.path
    )
    #expect(candidates.count == 1)
    #expect(candidates[0].totalGrowthBytes == 500 << 20)
    #expect(candidates[0].evidenceCount == 2)
}

@Test func normalizeDropsChildCandidateWhenParentSuggested() throws {
    let base = FileManager.default.temporaryDirectory
        .appendingPathComponent("pp-sug-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: base) }
    let home = base.appendingPathComponent("home", isDirectory: true)
    let develop = home.appendingPathComponent("develop", isDirectory: true)
    let child = develop.appendingPathComponent("app", isDirectory: true)

    let candidates = RecipeSuggester.normalize(
        [
            sample(develop.path, total: 400 << 20),
            sample(child.path, total: 300 << 20),
        ],
        homeDirectory: home.path
    )
    // 父目录建议覆盖子目录建议 → 只保留父目录
    #expect(candidates.count == 1)
    #expect(candidates[0].samplePath == develop.path)
}
