import Testing
import Foundation
@testable import DiskReservoirCore

@Test func permanentDeleteRemovesDirectory() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("pp-del-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try Data(repeating: 7, count: 4096).write(to: root.appendingPathComponent("f.bin"))
    let freed = try FileManagerFileDeleter().delete(url: root, disposition: .deletePermanently)
    #expect(!FileManager.default.fileExists(atPath: root.path))
    #expect(freed > 0)
}

@Test func noneDispositionDoesNothing() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("pp-del2-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let freed = try FileManagerFileDeleter().delete(url: root, disposition: .none)
    #expect(FileManager.default.fileExists(atPath: root.path))
    #expect(freed == 0)
}

@Test func missingPathThrows() {
    let missing = FileManager.default.temporaryDirectory
        .appendingPathComponent("pp-del3-\(UUID().uuidString)", isDirectory: true)
    #expect(throws: (any Error).self) {
        _ = try FileManagerFileDeleter().delete(url: missing, disposition: .deletePermanently)
    }
}
