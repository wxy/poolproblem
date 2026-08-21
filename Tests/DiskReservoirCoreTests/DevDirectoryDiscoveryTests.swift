import Testing
import Foundation
@testable import DiskReservoirCore

@Test func discoveryFindsProjectsWithRegenerableContent() throws {
    let home = FileManager.default.temporaryDirectory
        .appendingPathComponent("pp-disc-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: home) }
    // 项目 A：package.json + 大 node_modules → 命中
    let projA = home.appendingPathComponent("ProjA", isDirectory: true)
    let nm = projA.appendingPathComponent("node_modules", isDirectory: true)
    try FileManager.default.createDirectory(at: nm, withIntermediateDirectories: true)
    try Data().write(to: projA.appendingPathComponent("package.json"))
    try Data(repeating: 0x41, count: 500_000).write(to: nm.appendingPathComponent("big.bin"))
    // 项目 B：有 package.json 但无可重建内容 → 跳过
    let projB = home.appendingPathComponent("ProjB", isDirectory: true)
    try FileManager.default.createDirectory(at: projB, withIntermediateDirectories: true)
    try Data().write(to: projB.appendingPathComponent("package.json"))

    let found = DevDirectoryDiscovery.discover(homeDirectory: home.path, minimumRegenerableBytes: 100_000)
    #expect(found.map(\.path).contains(projA.path))
    #expect(!found.map(\.path).contains(projB.path))
    #expect((found.first { $0.path == projA.path }?.regenerableBytes ?? 0) >= 500_000)
}

@Test func discoveryFindsProjectsInConventionRoot() throws {
    let home = FileManager.default.temporaryDirectory
        .appendingPathComponent("pp-disc2-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: home) }
    let code = home.appendingPathComponent("Code", isDirectory: true)
    let proj = code.appendingPathComponent("X", isDirectory: true)
    try FileManager.default.createDirectory(at: proj.appendingPathComponent("dist"), withIntermediateDirectories: true)
    try Data().write(to: proj.appendingPathComponent("package.json"))
    try Data(repeating: 0x42, count: 300_000).write(to: proj.appendingPathComponent("dist/out.bin"))

    let found = DevDirectoryDiscovery.discover(homeDirectory: home.path, minimumRegenerableBytes: 100_000)
    #expect(found.map(\.path).contains(proj.path))
}

@Test func discoveryFindsNestedProjectsUnderDevContainer() throws {
    let home = FileManager.default.temporaryDirectory
        .appendingPathComponent("pp-disc3-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: home) }
    // 模拟 ~/develop 容器：本身无标记，项目在其子目录
    let dev = home.appendingPathComponent("develop", isDirectory: true)
    let proj = dev.appendingPathComponent("MyApp", isDirectory: true)
    try FileManager.default.createDirectory(at: proj.appendingPathComponent("node_modules"), withIntermediateDirectories: true)
    try Data().write(to: proj.appendingPathComponent("package.json"))
    try Data(repeating: 0x43, count: 400_000).write(to: proj.appendingPathComponent("node_modules/x.bin"))

    let found = DevDirectoryDiscovery.discover(homeDirectory: home.path, minimumRegenerableBytes: 100_000)
    #expect(found.map(\.path).contains(proj.path))
}

@Test func excludedPathPolicySkipsTrashLibraryAndHiddenDirs() {
    let home = "/Users/alice"
    #expect(DevDirectoryDiscovery.isExcludedPath("\(home)/.Trash/proj", homeDirectory: home))
    #expect(DevDirectoryDiscovery.isExcludedPath("\(home)/Library/Caches/foo/build", homeDirectory: home))
    #expect(DevDirectoryDiscovery.isExcludedPath("\(home)/.cache/npm/node_modules", homeDirectory: home))
    #expect(!DevDirectoryDiscovery.isExcludedPath("\(home)/develop/proj", homeDirectory: home))
    #expect(!DevDirectoryDiscovery.isExcludedPath("\(home)/Documents/proj/node_modules", homeDirectory: home))
}
