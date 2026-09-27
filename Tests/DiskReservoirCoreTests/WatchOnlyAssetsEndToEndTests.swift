import Foundation
import Testing
@testable import DiskReservoirCore

private final class WatchOnlyDeleteProbe: FileDeleting, @unchecked Sendable {
    private let lock = NSLock()
    private var recordedPaths: [String] = []

    var paths: [String] {
        lock.lock()
        defer { lock.unlock() }
        return recordedPaths
    }

    func delete(url: URL, disposition: CleanDisposition) throws -> Int64 {
        lock.lock()
        recordedPaths.append(url.path)
        lock.unlock()
        return 1
    }
}

@Test func watchOnlyAssetsRemainVisibleAndCannotEnterCleanup() throws {
    let fixture = FileManager.default.temporaryDirectory
        .appendingPathComponent("pp-watch-e2e-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: fixture) }
    let home = fixture.appendingPathComponent("home", isDirectory: true)
    let backup = home.appendingPathComponent("Library/Application Support/MobileSync/Backup", isDirectory: true)
    let models = home.appendingPathComponent(".lmstudio/models", isDirectory: true)
    try FileManager.default.createDirectory(at: backup, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: models, withIntermediateDirectories: true)
    try Data(repeating: 0x41, count: 1_024).write(to: backup.appendingPathComponent("device.bin"))
    try Data(repeating: 0x42, count: 2_048).write(to: models.appendingPathComponent("recent-model.bin"))

    let scan = try Scanner().scan(recipes: WatchRecipes.all, homeDirectory: home.path)
    let backups = try #require(scan.items.first { $0.recipeID == "ios-device-backups" })
    let localModels = try #require(scan.items.first { $0.recipeID == "local-ai-models" })
    #expect(backups.sizeBytes >= 1_024)
    #expect(localModels.sizeBytes >= 2_048)
    #expect(localModels.path.hasSuffix("/.lmstudio/models"))
    #expect(FileManager.default.fileExists(atPath: localModels.path))
    for item in [backups, localModels] {
        #expect(item.cleanability == .watchOnly)
        #expect(item.disposition == .none)
        #expect(item.reclaimableBytes == 0)
        #expect(!item.cleanability.allowsManualCleanup)
        #expect(!item.allowsAutomaticPermanentDeletion)
    }

    let rescanned = Scanner().rescan(
        path: models.path,
        recipe: try #require(WatchRecipes.all.first { $0.id == "local-ai-models" }),
        homeDirectory: home.path
    )
    #expect(rescanned.count == 1)
    #expect(rescanned.first?.reclaimableBytes == 0)

    // Simulate an older persisted item that still carries a positive
    // reclaimable estimate: the engine must reject it even in forced mode.
    let legacyItem = backups.replacing(reclaimableBytes: backups.allocatedBytes)
    let legacyScan = ScanResult(
        volume: scan.volume,
        items: [legacyItem],
        records: [],
        volumeURL: scan.volumeURL
    )
    let deleter = WatchOnlyDeleteProbe()
    let cleaner = Cleaner(
        evaluator: RuleEvaluator(config: .default),
        deleter: deleter,
        inspector: AlwaysFalseProcessInspector(),
        logStore: CleanLogStore(paths: StoragePaths(baseURL: fixture.appendingPathComponent("data"))),
        availableBytesReader: { _ in 0 }
    )
    let outcome = try cleaner.run(
        scan: legacyScan,
        config: .default,
        waterlineBytes: scan.volume.availableBytes + 1,
        forceClean: true,
        ignoreAge: true
    )
    #expect(outcome.entries.isEmpty)
    #expect(deleter.paths.isEmpty)
    #expect(FileManager.default.fileExists(atPath: backup.appendingPathComponent("device.bin").path))
    #expect(FileManager.default.fileExists(atPath: models.appendingPathComponent("recent-model.bin").path))
}
