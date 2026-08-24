import Testing
import Foundation
@testable import DiskReservoirCore

@Test func customRecipesResolveHomePatternWhenPathExists() throws {
    let home = FileManager.default.temporaryDirectory
        .appendingPathComponent("pp-custom-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: home) }
    let dir = home.appendingPathComponent("cache-dir", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

    let specs = [
        CustomRecipeSpec(
            id: "~/cache-dir",
            name: "cache-dir",
            pattern: "~/cache-dir",
            category: .custom,
            safety: .safeWhileRunning,
            cleanability: .regenerable,
            disposition: .trash
        ),
        CustomRecipeSpec(
            id: "~/missing-dir",
            name: "missing-dir",
            pattern: "~/missing-dir",
            category: .custom,
            safety: .safeWhileRunning,
            cleanability: .regenerable,
            disposition: .trash
        ),
    ]
    let recipes = CustomRecipes.make(specs: specs, homeDirectory: home.path)
    #expect(recipes.count == 2)
    let paths = StoragePaths(baseURL: nil, homeDirectory: home.path)
    #expect(recipes[0].resolvePaths(paths) == [dir.path])
    #expect(recipes[1].resolvePaths(paths).isEmpty)
}
