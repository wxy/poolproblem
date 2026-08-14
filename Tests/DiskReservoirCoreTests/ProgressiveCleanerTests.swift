import Testing
import Foundation
@testable import DiskReservoirCore

private struct RecorderDeleter: FileDeleting {
    let deleted: @Sendable (URL) -> Void

    func delete(url: URL, disposition: CleanDisposition) throws -> Int64 {
        deleted(url)
        try FileManager.default.removeItem(at: url)
        return 128
    }
}

@Test func progressiveCleanerTrimsOldestChildrenWhenThresholdExceeded() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("pp-progressive-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    for index in 0..<12 {
        let child = root.appendingPathComponent("child-\(index)", isDirectory: true)
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        try Data(repeating: 0xAB, count: 32).write(to: child.appendingPathComponent("data.bin"))
        let age = TimeInterval(2 * 86_400 + index * 60)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-age)],
            ofItemAtPath: child.path
        )
    }

    let logDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("pp-progressive-logs-\(UUID().uuidString)", isDirectory: true)
    let paths = StoragePaths(baseURL: logDir)
    let logStore = CleanLogStore(paths: paths)
    let policy = ProgressiveCleanupPolicy(
        recipeID: "xctestdevices",
        parentPath: root.path,
        maxChildren: 10,
        maxItemsPerRun: 3,
        minimumAgeSeconds: 86_400,
        disposition: .deletePermanently
    )
    let outcome = try ProgressiveCleaner(
        deleter: FileManagerFileDeleter(),
        logStore: logStore
    ).run(policy: policy)

    #expect(outcome.trimmedCount == 3)
    #expect(outcome.remainingCount == 9)
    #expect(outcome.entries.count == 3)
    #expect(outcome.entries.allSatisfy { $0.source == .auto })
    #expect(outcome.entries.allSatisfy { $0.itemNames.count == 1 })
    #expect(Set(outcome.entries.flatMap(\.itemNames)) == Set(["child-9", "child-10", "child-11"]))
    #expect(try logStore.entries().count == 3)
}

@Test func progressiveCleanerDoesNothingBelowThreshold() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("pp-progressive-idle-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    for index in 0..<5 {
        let child = root.appendingPathComponent("child-\(index)", isDirectory: true)
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-3 * 86_400)],
            ofItemAtPath: child.path
        )
    }

    let paths = StoragePaths(baseURL: root.appendingPathComponent("logs", isDirectory: true))
    let outcome = try ProgressiveCleaner(
        deleter: FileManagerFileDeleter(),
        logStore: CleanLogStore(paths: paths)
    ).run(policy: ProgressiveCleanupPolicy(
        recipeID: "xctestdevices",
        parentPath: root.path,
        maxChildren: 10,
        maxItemsPerRun: 3,
        minimumAgeSeconds: 86_400,
        disposition: .deletePermanently
    ))

    #expect(outcome == .empty)
}

@Test func progressiveCleanerSkipsChildrenModifiedRecently() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("pp-progressive-recent-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    for index in 0..<12 {
        let child = root.appendingPathComponent("child-\(index)", isDirectory: true)
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
    }

    let paths = StoragePaths(baseURL: root.appendingPathComponent("logs", isDirectory: true))
    let outcome = try ProgressiveCleaner(
        deleter: FileManagerFileDeleter(),
        logStore: CleanLogStore(paths: paths)
    ).run(policy: ProgressiveCleanupPolicy(
        recipeID: "xctestdevices",
        parentPath: root.path,
        maxChildren: 10,
        maxItemsPerRun: 3,
        minimumAgeSeconds: 86_400,
        disposition: .deletePermanently
    ))

    #expect(outcome.entries.isEmpty)
    #expect(outcome.remainingCount == 0)
}

@Test func progressiveCleanerPreviewDoesNotDelete() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("pp-progressive-preview-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    for index in 0..<12 {
        let child = root.appendingPathComponent("child-\(index)", isDirectory: true)
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        try Data(repeating: 0xAB, count: 32).write(to: child.appendingPathComponent("data.bin"))
        let age = TimeInterval(2 * 86_400 + index * 60)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-age)],
            ofItemAtPath: child.path
        )
    }

    let paths = StoragePaths(baseURL: root.appendingPathComponent("logs", isDirectory: true))
    let cleaner = ProgressiveCleaner(
        deleter: FileManagerFileDeleter(),
        logStore: CleanLogStore(paths: paths)
    )
    let policy = ProgressiveCleanupPolicy(
        recipeID: "xctestdevices",
        parentPath: root.path,
        maxChildren: 10,
        maxItemsPerRun: 3,
        minimumAgeSeconds: 86_400,
        disposition: .deletePermanently
    )
    let preview = try cleaner.preview(policy: policy)

    #expect(preview.trimmedCount == 3)
    #expect(Set(preview.entries.flatMap(\.itemNames)) == Set(["child-9", "child-10", "child-11"]))
    #expect((try? FileManager.default.contentsOfDirectory(atPath: root.path))?.count == 12)
    #expect(try CleanLogStore(paths: paths).entries().isEmpty)
}
