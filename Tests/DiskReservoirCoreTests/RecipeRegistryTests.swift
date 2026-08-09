import Testing
@testable import DiskReservoirCore

@Test func builtInRecipesCoverCoreCategories() {
    let recipes = RecipeRegistry.builtIn()
    let ids = Set(recipes.map(\.id))
    #expect(ids.contains("xctestdevices"))
    #expect(ids.contains("deriveddata"))
    #expect(ids.contains("npm-cache"))
    #expect(ids.contains("uv-cache"))
    #expect(recipes.allSatisfy { !$0.id.isEmpty && !$0.name.isEmpty })
}

@Test func xctestdevicesRecipeResolvesToLibraryDeveloper() {
    let recipe = RecipeRegistry.builtIn().first { $0.id == "xctestdevices" }!
    let paths = StoragePaths(homeDirectory: "/Users/tester")
    let resolved = recipe.resolvePaths(paths)
    #expect(resolved == ["/Users/tester/Library/Developer/XCTestDevices"])
}

@Test func everyRecipeHasDistinctID() {
    let ids = RecipeRegistry.builtIn().map(\.id)
    #expect(Set(ids).count == ids.count)
}
