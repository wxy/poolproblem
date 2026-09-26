import Foundation
import Testing
@testable import DiskReservoirCore

@Test func temporaryBuildGuardIgnoresUnrelatedGitQueries() {
    #expect(!TemporaryBuildArtifacts.guardProcessNames.contains("git"))
    #expect(TemporaryBuildArtifacts.guardProcessNames.contains("xcodebuild"))
    #expect(TemporaryBuildArtifacts.guardProcessNames.contains("swiftc"))
}

@Test func temporaryBuildDiscoveryUsesNarrowAllowlistAndRejectsSymlinks() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("pp-temp-artifacts-\(UUID().uuidString)", isDirectory: true)
    let outside = FileManager.default.temporaryDirectory
        .appendingPathComponent("pp-temp-outside-\(UUID().uuidString)", isDirectory: true)
    defer {
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.removeItem(at: outside)
    }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)

    let accepted = ["aipulse-ios-dd", "ai-pulse-cache", "AIPulseWatchFinal", "PoolProblemDerived-test"]
    for name in accepted {
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent(name),
            withIntermediateDirectories: true
        )
    }
    try FileManager.default.createDirectory(
        at: root.appendingPathComponent("unrelated-user-data"),
        withIntermediateDirectories: true
    )
    try FileManager.default.createSymbolicLink(
        at: root.appendingPathComponent("aipulse-linked"),
        withDestinationURL: outside
    )

    let found = Set(TemporaryBuildArtifacts.discover(root: root.path).map {
        URL(fileURLWithPath: $0).lastPathComponent
    })
    #expect(found == Set(accepted))
}

@Test func temporaryBuildCleanupRequiresWholeTreeToBeIdle() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("pp-temp-idle-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let artifact = root.appendingPathComponent("aipulse-old-build", isDirectory: true)
    try FileManager.default.createDirectory(at: artifact, withIntermediateDirectories: true)
    let output = artifact.appendingPathComponent("output.bin")
    try Data([0x01]).write(to: output)

    let now = Date()
    let old = now.addingTimeInterval(-48 * 3_600)
    try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: output.path)

    // Copied outputs can preserve an old timestamp inside a directory that was
    // just created. The recent directory itself must keep the tree protected.
    try FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: artifact.path)
    #expect(!TemporaryBuildArtifacts.isEligibleForCleanup(
        path: artifact.path,
        root: root.path,
        now: now
    ))

    try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: artifact.path)
    #expect(TemporaryBuildArtifacts.isEligibleForCleanup(
        path: artifact.path,
        root: root.path,
        now: now
    ))

    try FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: output.path)
    #expect(!TemporaryBuildArtifacts.isEligibleForCleanup(
        path: artifact.path,
        root: root.path,
        now: now
    ))
    #expect(!TemporaryBuildArtifacts.isEligibleForCleanup(
        path: root.appendingPathComponent("unrelated-user-data").path,
        root: root.path,
        now: now
    ))
}
