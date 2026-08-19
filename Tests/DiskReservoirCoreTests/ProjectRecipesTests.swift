import Testing
import Foundation
@testable import DiskReservoirCore

@Test func projectRecipesExpandDevRoots() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("pp-pr-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let dev = root.appendingPathComponent("dev", isDirectory: true)
    let projA = dev.appendingPathComponent("A", isDirectory: true)
    try FileManager.default.createDirectory(at: projA.appendingPathComponent("node_modules"), withIntermediateDirectories: true)
    try Data().write(to: projA.appendingPathComponent("package.json"))
    try FileManager.default.createDirectory(at: projA.appendingPathComponent("dist"), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: dev.appendingPathComponent("B", isDirectory: true), withIntermediateDirectories: true)

    let recipes = ProjectRecipes.make(devRoots: [dev.path], homeDirectory: root.path)
    let ids = recipes.map(\.id)
    #expect(ids.contains("project-node-modules"))
    #expect(ids.contains("project-build-output"))
    #expect(recipes.allSatisfy { $0.aggregatesPaths })
    let nm = recipes.first { $0.id == "project-node-modules" }
    let nmPaths = nm?.resolvePaths(StoragePaths(baseURL: nil, homeDirectory: root.path)) ?? []
    #expect(nmPaths == [projA.appendingPathComponent("node_modules").path])
    let build = recipes.first { $0.id == "project-build-output" }
    let buildPaths = build?.resolvePaths(StoragePaths(baseURL: nil, homeDirectory: root.path)) ?? []
    #expect(buildPaths.contains(projA.appendingPathComponent("dist").path))
    #expect(!buildPaths.contains(projA.appendingPathComponent("missing").path))
}

@Test func projectRecipesTreatScatteredDevRootAsProject() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("pp-pr2-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    // 开发根本身就是项目（散落目录，无统一结构）
    try FileManager.default.createDirectory(at: root.appendingPathComponent("node_modules"), withIntermediateDirectories: true)
    try Data().write(to: root.appendingPathComponent("package.json"))

    let recipes = ProjectRecipes.make(devRoots: [root.path], homeDirectory: root.path)
    let nm = recipes.first { $0.id == "project-node-modules" }
    let nmPaths = nm?.resolvePaths(StoragePaths(baseURL: nil, homeDirectory: root.path)) ?? []
    #expect(nmPaths.contains(root.appendingPathComponent("node_modules").path))
}

@Test func projectRecipesDeduplicatePaths() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("pp-pr3-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let dev = root.appendingPathComponent("dev", isDirectory: true)
    let proj = dev.appendingPathComponent("A", isDirectory: true)
    try FileManager.default.createDirectory(at: proj.appendingPathComponent("node_modules"), withIntermediateDirectories: true)
    try Data().write(to: proj.appendingPathComponent("package.json"))
    // 同一根重复配置：应去重
    let recipes = ProjectRecipes.make(devRoots: [dev.path, dev.path], homeDirectory: root.path)
    let nm = recipes.first { $0.id == "project-node-modules" }
    let nmPaths = nm?.resolvePaths(StoragePaths(baseURL: nil, homeDirectory: root.path)) ?? []
    #expect(nmPaths.count == 1)
}
