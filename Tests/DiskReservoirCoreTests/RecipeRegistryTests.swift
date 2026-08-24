import Testing
import Foundation
@testable import DiskReservoirCore

@Test func builtInRecipesCoverCoreCategories() {
    let recipes = RecipeRegistry.builtIn()
    let ids = Set(recipes.map(\.id))
    #expect(ids.contains("xctestdevices"))
    #expect(ids.contains("deriveddata"))
    // 包管理器缓存已合并为独立配方族（PackageManagerRecipes），不在内置列表
    #expect(!ids.contains("npm-cache"))
    #expect(!ids.contains("uv-cache"))
    #expect(ids.contains("library-caches"))
    #expect(recipes.allSatisfy { !$0.id.isEmpty && !$0.name.isEmpty })
}

@Test func xctestdevicesRecipeResolvesToLibraryDeveloper() {
    let recipe = RecipeRegistry.builtIn().first { $0.id == "xctestdevices" }!
    let paths = StoragePaths(baseURL: nil, homeDirectory: "/Users/tester")
    let resolved = recipe.resolvePaths(paths)
    #expect(resolved == ["/Users/tester/Library/Developer/XCTestDevices"])
}

@Test func trashRecipeCoversLocalAndICloudTrash() {
    let recipe = RecipeRegistry.builtIn().first { $0.id == "trash" }!
    let paths = StoragePaths(baseURL: nil, homeDirectory: "/Users/tester")
    let resolved = recipe.resolvePaths(paths)
    #expect(resolved.contains("/Users/tester/.Trash"))
    #expect(resolved.contains("/Users/tester/Library/Mobile Documents/.Trash"))
}

@Test func everyRecipeHasDistinctID() {
    let ids = RecipeRegistry.builtIn().map(\.id)
    #expect(Set(ids).count == ids.count)
}

@Test func newRecipesAreRegistered() {
    let ids = Set(RecipeRegistry.builtIn().map(\.id))
    #expect(ids.contains("xcode-preview-cache"))
    #expect(ids.contains("xcode-devicesupport"))
    #expect(ids.contains("simulator-runtimes"))
    #expect(ids.contains("simulator-dyld-cache"))
}

@Test func devicesupportResolvesOnlyOldVersions() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("pp-device-support-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let support = root.appendingPathComponent("Library/Developer/Xcode/iOS DeviceSupport", isDirectory: true)
    let old = support.appendingPathComponent("iPhone12,8 26.5.2 (23F84)", isDirectory: true)
    let current = support.appendingPathComponent("iPhone12,8 26.6 (23U67)", isDirectory: true)
    try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: current, withIntermediateDirectories: true)
    try FileManager.default.setAttributes(
        [.modificationDate: Date().addingTimeInterval(-90 * 86_400)],
        ofItemAtPath: old.path
    )
    try FileManager.default.setAttributes(
        [.modificationDate: Date()],
        ofItemAtPath: current.path
    )

    let recipe = RecipeRegistry.builtIn().first { $0.id == "xcode-devicesupport" }!
    let paths = StoragePaths(baseURL: nil, homeDirectory: root.path)
    let resolved = recipe.resolvePaths(paths)
    #expect(resolved.count == 1)
    #expect(resolved.first?.hasSuffix("iPhone12,8 26.5.2 (23F84)") == true)
}

@Test func recipesCarryCleanabilityAndProtection() {
    let recipes = Dictionary(uniqueKeysWithValues: RecipeRegistry.builtIn().map { ($0.id, $0) })
    #expect(recipes["trash"]?.cleanability == .displayOnly)
    #expect(recipes["core-simulator-devices"]?.cleanability == .trashOnly)
    #expect(recipes["deriveddata"]?.disposition == .trash)
    #expect(recipes["library-caches"]?.protectedChildren == [
        "org.swift.swiftpm", "node-gyp", "Homebrew", "CocoaPods",
    ])
    #expect(recipes["library-caches"]?.cleanByChildOnly == true)
    #expect(recipes["simulator-runtimes"]?.usageProbe == .simulatorRuntimeLastBooted)
    #expect(recipes["simulator-dyld-cache"]?.usageProbe == .simulatorRuntimeLastBooted)
}

@Test func packageManagerRecipesMergeDefaultsAndExtras() {
    let recipe = PackageManagerRecipes.make(
        extraRoots: ["/Users/tester/.cache/yarn"],
        homeDirectory: "/Users/tester"
    )
    #expect(recipe.id == PackageManagerRecipes.familyID)
    #expect(recipe.aggregatesPaths)
    #expect(recipe.disposition == .deletePermanently)
    #expect(recipe.category == .packageManager)
    let resolved = recipe.resolvePaths(StoragePaths(baseURL: nil, homeDirectory: "/Users/tester"))
    #expect(resolved.contains("/Users/tester/.npm"))
    #expect(resolved.contains("/Users/tester/Library/pnpm"))
    #expect(resolved.contains("/Users/tester/.cache/uv"))
    #expect(resolved.contains("/Users/tester/Library/Caches/CocoaPods"))
    #expect(resolved.contains("/Users/tester/Library/Caches/Homebrew"))
    #expect(resolved.contains("/Users/tester/.cache/yarn"))
    #expect(Set(resolved).count == resolved.count)
}

@Test func previewCacheRecipeResolvesToUserData() {
    let recipe = RecipeRegistry.builtIn().first { $0.id == "xcode-preview-cache" }!
    let paths = StoragePaths(baseURL: nil, homeDirectory: "/Users/tester")
    #expect(recipe.resolvePaths(paths) == ["/Users/tester/Library/Developer/Xcode/UserData/Previews"])
}
