import Testing
import Foundation
@testable import DiskReservoirCore

@Test func surfaceScannerMeasuresFirstLevelChildren() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("pp-surface-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let big = root.appendingPathComponent("Big")
    try FileManager.default.createDirectory(at: big, withIntermediateDirectories: true)
    try Data(repeating: 0x41, count: 300_000).write(to: big.appendingPathComponent("f.bin"))
    let dirs = SurfaceScanner().scan(roots: [root.path], minimumSizeBytes: 100_000)
    // /var 与 /private/var 是同一目录的符号链接，路径字符串可能不同，按末段与大小断言。
    #expect(dirs.contains {
        URL(fileURLWithPath: $0.path).lastPathComponent == "Big" && $0.sizeBytes >= 300_000
    }, "dirs=\(dirs)")
    #expect(dirs.allSatisfy { $0.fileCount >= 0 })
}

@Test func surfaceScannerSkipsSmallChildren() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("pp-surface-small-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let small = root.appendingPathComponent("Small")
    try FileManager.default.createDirectory(at: small, withIntermediateDirectories: true)
    try Data(repeating: 0x41, count: 10).write(to: small.appendingPathComponent("f.bin"))
    let dirs = SurfaceScanner().scan(roots: [root.path], minimumSizeBytes: 100_000)
    #expect(dirs.isEmpty)
}

@Test func surfaceScannerDefaultRootsAreHomeScoped() {
    let roots = SurfaceScanner.defaultRoots(homeDirectory: "/Users/alice")
    #expect(roots.contains("/Users/alice/Library/Caches"))
    #expect(roots.contains("/Users/alice/.cache"))
    #expect(roots.contains("/Users/alice/Library/Containers"))
}

@Test func surfaceScannerMeasuresExplicitPaths() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("pp-surf-measure-\(UUID().uuidString)", isDirectory: true)
    let dir = root.appendingPathComponent("D", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try Data(repeating: 0x41, count: 77_000).write(to: dir.appendingPathComponent("f.bin"))
    let dirs = SurfaceScanner().measure(paths: [dir.path])
    #expect(dirs.first.map { URL(fileURLWithPath: $0.path).lastPathComponent } == "D")
    #expect((dirs.first?.sizeBytes ?? 0) >= 77_000)
}
