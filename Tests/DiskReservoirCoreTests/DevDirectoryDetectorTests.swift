import Testing
import Foundation
@testable import DiskReservoirCore

@Test func detectsProjectByManifestOrGit() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("pp-dev-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let swift = root.appendingPathComponent("SwiftProj")
    try FileManager.default.createDirectory(at: swift, withIntermediateDirectories: true)
    try Data().write(to: swift.appendingPathComponent("Package.swift"))
    #expect(DevDirectoryDetector.detect(path: swift.path) == .project)

    let node = root.appendingPathComponent("NodeProj")
    try FileManager.default.createDirectory(at: node, withIntermediateDirectories: true)
    try Data().write(to: node.appendingPathComponent("package.json"))
    #expect(DevDirectoryDetector.detect(path: node.path) == .project)

    let git = root.appendingPathComponent("GitOnly")
    try FileManager.default.createDirectory(at: git.appendingPathComponent(".git"), withIntermediateDirectories: true)
    #expect(DevDirectoryDetector.detect(path: git.path) == .project)

    let plain = root.appendingPathComponent("Plain")
    try FileManager.default.createDirectory(at: plain, withIntermediateDirectories: true)
    #expect(DevDirectoryDetector.detect(path: plain.path) == nil)
}

@Test func detectsProjectByRegenerableDir() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("pp-dev2-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let p = root.appendingPathComponent("WithNM")
    try FileManager.default.createDirectory(at: p.appendingPathComponent("node_modules"), withIntermediateDirectories: true)
    #expect(DevDirectoryDetector.detect(path: p.path) == .project)
}

@Test func detectsProjectByTopLevelBuildOutput() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("pp-dev3-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let p = root.appendingPathComponent("Scattered")
    try FileManager.default.createDirectory(at: p.appendingPathComponent("dist"), withIntermediateDirectories: true)
    #expect(DevDirectoryDetector.detect(path: p.path) == .project)
}
