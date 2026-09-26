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
    #expect(ids.contains(TemporaryBuildArtifacts.recipeID))
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
    // tvOS 平台同样按「保留最新、只列旧版」处理。
    let tvSupport = root.appendingPathComponent("Library/Developer/Xcode/tvOS DeviceSupport", isDirectory: true)
    let tvOld = tvSupport.appendingPathComponent("AppleTV5,3 25.1 (23K120)", isDirectory: true)
    let tvCurrent = tvSupport.appendingPathComponent("AppleTV5,3 25.2 (23K333)", isDirectory: true)
    try FileManager.default.createDirectory(at: tvOld, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: tvCurrent, withIntermediateDirectories: true)
    try FileManager.default.setAttributes(
        [.modificationDate: Date().addingTimeInterval(-90 * 86_400)],
        ofItemAtPath: tvOld.path
    )
    try FileManager.default.setAttributes(
        [.modificationDate: Date()],
        ofItemAtPath: tvCurrent.path
    )

    let recipe = RecipeRegistry.builtIn().first { $0.id == "xcode-devicesupport" }!
    let paths = StoragePaths(baseURL: nil, homeDirectory: root.path)
    let resolved = recipe.resolvePaths(paths)
    // iOS 与 tvOS 各保留最新 1 个（拍板决策：维持 keep-1），各解析出旧版 1 条。
    #expect(resolved.count == 2)
    #expect(resolved.contains { $0.hasSuffix("iPhone12,8 26.5.2 (23F84)") })
    #expect(resolved.contains { $0.hasSuffix("AppleTV5,3 25.1 (23K120)") })
}

@Test func coredeviceRecipeResolvesContainerCaches() {
    let recipe = RecipeRegistry.builtIn().first { $0.id == "coredevice-cache" }!
    let paths = StoragePaths(baseURL: nil, homeDirectory: "/Users/tester")
    #expect(recipe.resolvePaths(paths) == [
        "/Users/tester/Library/Containers/com.apple.CoreDevice.CoreDeviceService/Data/Library/Caches"
    ])
    // 真机服务缓存可清理但仅进回收站；不允许无人值守永久删除。
    #expect(recipe.cleanability == .regenerable)
    #expect(recipe.disposition == .trash)
    #expect(!recipe.allowsAutomaticPermanentDeletion)
}

@Test func recipesCarryCleanabilityAndProtection() {
    let recipes = Dictionary(uniqueKeysWithValues: RecipeRegistry.builtIn().map { ($0.id, $0) })
    #expect(recipes["trash"]?.cleanability == .displayOnly)
    #expect(recipes["core-simulator-devices"]?.cleanability == .trashOnly)
    #expect(recipes["deriveddata"]?.disposition == .trash)
    #expect(recipes["xcode-archives"]?.cleanability == .displayOnly)
    #expect(recipes["xcode-archives"]?.allowsAutomaticPermanentDeletion == false)
    #expect(recipes["library-caches"]?.allowsAutomaticPermanentDeletion == false)
    #expect(recipes[TemporaryBuildArtifacts.recipeID]?.allowsAutomaticPermanentDeletion == false)
    #expect(recipes[TemporaryBuildArtifacts.recipeID]?.aggregatesPaths == true)
    #expect(recipes[TemporaryBuildArtifacts.recipeID]?.minimumIdleHours == 24)
    #expect(recipes[TemporaryBuildArtifacts.recipeID]?.safety == .userConfirm)
    #expect(recipes[TemporaryBuildArtifacts.recipeID]?.disposition == .trash)
    #expect(recipes["xctestdevices"]?.allowsAutomaticPermanentDeletion == true)
    #expect(recipes["xcode-docscache"]?.allowsAutomaticPermanentDeletion == true)
    #expect(recipes["xcode-preview-cache"]?.allowsAutomaticPermanentDeletion == true)
    let protected = Set(recipes["library-caches"]?.protectedChildren ?? [])
    #expect(protected.isSuperset(of: [
        "org.swift.swiftpm", "node-gyp", "Homebrew", "CocoaPods",
        "xingyu.wang.poolproblem", "xingyu.wang.poolproblem.dev", "group.xingyu.wang.poolproblem",
    ]))
    #expect(recipes["library-caches"]?.cleanByChildOnly == true)
    #expect(recipes["simulator-runtimes"]?.usageProbe == .simulatorRuntimeLastBooted)
    #expect(recipes["simulator-dyld-cache"]?.usageProbe == .simulatorRuntimeLastBooted)
}

@Test func recipesAreGroupedByEcosystem() {
    let recipes = Dictionary(uniqueKeysWithValues: RecipeRegistry.builtIn().map { ($0.id, $0) })
    // Xcode 工具链与模拟器归入同一组
    #expect(recipes["deriveddata"]?.group == .xcode)
    #expect(recipes["xcode-devicesupport"]?.group == .xcode)
    #expect(recipes["core-simulator-devices"]?.group == .xcode)
    #expect(recipes["simulator-runtimes"]?.group == .xcode)
    #expect(recipes["simulator-dyld-cache"]?.group == .xcode)
    // 系统 / 通用
    #expect(recipes["library-caches"]?.group == .system)
    #expect(recipes["trash"]?.group == .system)

    // 包管理器缓存族
    let pkg = PackageManagerRecipes.make(extraRoots: [], homeDirectory: "/Users/tester")
    #expect(pkg.group == .packageManager)

    // Node.js 项目族
    let projects = ProjectRecipes.make(devRoots: [], homeDirectory: "/Users/tester")
    #expect(projects.allSatisfy { $0.group == .nodejs })
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
    // M-B2 扩容：Go 构建缓存 / Cargo registry 压缩包镜像 / Yarn berry / Bun
    #expect(resolved.contains("/Users/tester/.cache/go-build"))
    #expect(resolved.contains("/Users/tester/.cargo/registry/cache"))
    #expect(resolved.contains("/Users/tester/.yarn/berry/cache"))
    #expect(resolved.contains("/Users/tester/.bun/install/cache"))
    #expect(Set(resolved).count == resolved.count)
    // non-target 清单：混合态与 owner 管理的数据绝不进「可永久删除」族
    #expect(!resolved.contains("/Users/tester/.cargo/registry/src"))
    #expect(!resolved.contains("/Users/tester/go/pkg/mod"))
    #expect(!resolved.contains("/Users/tester/.gradle/caches"))
}

@Test func gradleCachesRecipeStaysManualAndRecoverable() {
    let recipe = RecipeRegistry.builtIn().first { $0.id == PackageManagerRecipes.gradleCacheID }!
    // Gradle daemon 常驻并持有缓存锁：不授予无人值守永久删除，
    // 用户确认后逐项进回收站，可恢复。
    #expect(recipe.safety == .userConfirm)
    #expect(recipe.disposition == .trash)
    #expect(recipe.cleanability == .regenerable)
    #expect(!recipe.allowsAutomaticPermanentDeletion)
    #expect(recipe.resolvePaths(StoragePaths(
        baseURL: nil,
        homeDirectory: "/Users/tester"
    )) == ["/Users/tester/.gradle/caches"])
}

@Test func userAddedPackageManagerRootsRemainManualOnly() {
    let recipe = PackageManagerRecipes.makeCustom(
        extraRoots: ["/Users/tester/.cache/yarn"]
    )
    #expect(recipe.safety == .userConfirm)
    #expect(recipe.disposition == .trash)
    #expect(recipe.cleanability == .regenerable)
    #expect(recipe.allowsAutomaticPermanentDeletion == false)
    #expect(recipe.resolvePaths(StoragePaths(
        baseURL: nil,
        homeDirectory: "/Users/tester"
    )) == ["/Users/tester/.cache/yarn"])
}

@Test func previewCacheRecipeResolvesToUserData() {
    let recipe = RecipeRegistry.builtIn().first { $0.id == "xcode-preview-cache" }!
    let paths = StoragePaths(baseURL: nil, homeDirectory: "/Users/tester")
    #expect(recipe.resolvePaths(paths) == ["/Users/tester/Library/Developer/Xcode/UserData/Previews"])
}
