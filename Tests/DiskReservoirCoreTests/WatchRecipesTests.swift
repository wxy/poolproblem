import Testing
import Foundation
@testable import DiskReservoirCore

@Test func watchRecipesCarryWatchOnlySemantics() {
    let recipes = RecipeRegistry.builtIn().filter { recipe in
        ["ios-device-backups", "docker-desktop-data", "vm-data", "local-ai-models"]
            .contains(recipe.id)
    }
    #expect(recipes.count == 4)
    for recipe in recipes {
        #expect(recipe.cleanability == .watchOnly, "\(recipe.id)")
        #expect(recipe.disposition == .none, "\(recipe.id)")
        #expect(recipe.category == .asset, "\(recipe.id)")
        #expect(recipe.group == .assets, "\(recipe.id)")
        // 双保险：watchOnly 配方绝不允许自动永久删除授权。
        #expect(!recipe.allowsAutomaticPermanentDeletion, "\(recipe.id)")
    }
}

@Test func watchRecipePathsResolveUnderFakeHome() {
    let paths = StoragePaths(baseURL: nil, homeDirectory: "/Users/tester")
    let backups = RecipeRegistry.builtIn().first { $0.id == "ios-device-backups" }!
    #expect(backups.resolvePaths(paths) == ["/Users/tester/Library/Application Support/MobileSync/Backup"])

    let models = RecipeRegistry.builtIn().first { $0.id == "local-ai-models" }!
    #expect(Set(models.resolvePaths(paths)) == [
        "/Users/tester/.ollama/models",
        "/Users/tester/.lmstudio/models",
    ])
}

@Test func vmDataRecipeDiscoversOrbstackContainers() throws {
    let home = FileManager.default.temporaryDirectory
        .appendingPathComponent("pp-watch-home-\(UUID().uuidString)", isDirectory: true)
    let groupContainers = home.appendingPathComponent("Library/Group Containers", isDirectory: true)
    try FileManager.default.createDirectory(
        at: groupContainers.appendingPathComponent("group.A1B2.dev.orbstack"),
        withIntermediateDirectories: true
    )
    try FileManager.default.createDirectory(
        at: groupContainers.appendingPathComponent("group.unrelated"),
        withIntermediateDirectories: true
    )
    try FileManager.default.createDirectory(
        at: home.appendingPathComponent(".lima"), withIntermediateDirectories: true
    )
    defer { try? FileManager.default.removeItem(at: home) }

    let recipe = RecipeRegistry.builtIn().first { $0.id == "vm-data" }!
    let resolved = recipe.resolvePaths(StoragePaths(baseURL: nil, homeDirectory: home.path))
    #expect(resolved.contains(groupContainers.appendingPathComponent("group.A1B2.dev.orbstack").path))
    #expect(!resolved.contains(groupContainers.appendingPathComponent("group.unrelated").path))
    #expect(resolved.contains(home.appendingPathComponent(".lima").path))
}

@Test func watchRecipePathsAreNeverSuggested() {
    // 建议器硬排除：watchOnly 配方已注册覆盖其路径，表面增长不再产生候选。
    let suggester = RecipeSuggester()
    let entries = [
        GrowthEntry(
            observedAt: Date(),
            elapsedDays: 1,
            name: "Ollama 本地模型",
            path: "/Users/tester/.ollama/models",
            pattern: "~/.ollama/models",
            kind: .surface,
            deltaBytes: 2_000_000_000,
            rateBytesPerDay: 2_000_000_000
        )
    ]
    let candidates = suggester.suggest(
        entries: entries,
        existingRecipes: RecipeRegistry.builtIn(),
        homeDirectory: "/Users/tester"
    )
    #expect(candidates.isEmpty)
}
