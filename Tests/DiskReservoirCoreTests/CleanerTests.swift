import Testing
import Foundation
@testable import DiskReservoirCore

private struct MockDeleter: FileDeleting {
    func delete(url: URL, disposition: CleanDisposition) throws -> Int64 { 1024 }
}

private struct AlwaysTrueProcessInspector: ProcessInspecting {
    func isRunning(_ processName: String) -> Bool { true }
}

final class ReaderBox: @unchecked Sendable {
    var calls = 0
}

final class CaptureBox: @unchecked Sendable {
    var will: [String] = []
    var cleaned: [String] = []
}

@Test func cleanerStopsAtWaterline() throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("pp-clean-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let paths = StoragePaths(baseURL: dir)
    let logStore = CleanLogStore(paths: paths)
    let now = Date(timeIntervalSince1970: 1_000_000)
    let item = ScanItem(
        id: "old", recipeID: "xctestdevices", name: "XCTest", path: "/tmp/old",
        category: .xcode, safety: .safeWhileRunning, disposition: .deletePermanently,
        sizeBytes: 5_000_000_000, allocatedBytes: 5_000_000_000, reclaimableBytes: 5_000_000_000,
        fileCount: 1, lastModified: now.addingTimeInterval(-10 * 86_400)
    )
    let scan = ScanResult(
        volume: VolumeInfo(totalBytes: 100_000_000_000, availableBytes: 20_000_000_000, timestamp: now),
        items: [item],
        records: [],
        volumeURL: URL(fileURLWithPath: "/")
    )
    let box = ReaderBox()
    let cleaner = Cleaner(
        evaluator: RuleEvaluator(config: .default, now: { now }),
        deleter: MockDeleter(),
        inspector: AlwaysFalseProcessInspector(),
        logStore: logStore,
        availableBytesReader: { _ in
            box.calls += 1
            return box.calls == 1 ? 60 : 100
        },
        now: { now }
    )
    let outcome = try cleaner.run(scan: scan, config: .default, waterlineBytes: 30_000_000_000)
    // 可释放 5GB，缺口 10GB → 清理后仍低于水线
    #expect(outcome.freedBytes == 1024)
    #expect(outcome.actualFreedBytes == 40)
    #expect(outcome.stillBelowWaterline == true)
    #expect(try logStore.entries().count == 1)
}

@Test func cleanerDoesNothingAboveWaterline() throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("pp-clean2-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let paths = StoragePaths(baseURL: dir)
    let logStore = CleanLogStore(paths: paths)
    let scan = ScanResult(
        volume: VolumeInfo(totalBytes: 100, availableBytes: 90, timestamp: Date()),
        items: [],
        records: [],
        volumeURL: URL(fileURLWithPath: "/")
    )
    let cleaner = Cleaner(
        evaluator: RuleEvaluator(config: .default),
        deleter: MockDeleter(),
        inspector: AlwaysTrueProcessInspector(),
        logStore: logStore
    )
    let outcome = try cleaner.run(scan: scan, config: .default, waterlineBytes: 30)
    #expect(outcome.entries.isEmpty)
    #expect(outcome.freedBytes == 0)
    #expect(outcome.stillBelowWaterline == false)
}

@Test func cleanerSkipsRequiresQuitWhenRunning() throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("pp-clean3-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let paths = StoragePaths(baseURL: dir)
    let logStore = CleanLogStore(paths: paths)
    let now = Date(timeIntervalSince1970: 1_000_000)
    let item = ScanItem(
        id: "sim", recipeID: "core-simulator-devices", name: "Sim", path: "/tmp/sim",
        category: .simulator, safety: .requiresQuit, disposition: .trash,
        sizeBytes: 100, allocatedBytes: 100, reclaimableBytes: 100,
        fileCount: 1, lastModified: now.addingTimeInterval(-40 * 86_400)
    )
    let scan = ScanResult(
        volume: VolumeInfo(totalBytes: 100_000, availableBytes: 10_000, timestamp: now),
        items: [item],
        records: [],
        volumeURL: URL(fileURLWithPath: "/")
    )
    let box = ReaderBox()
    let cleaner = Cleaner(
        evaluator: RuleEvaluator(config: .default, now: { now }),
        deleter: MockDeleter(),
        inspector: AlwaysTrueProcessInspector(),
        logStore: logStore,
        availableBytesReader: { _ in
            box.calls += 1
            return box.calls == 1 ? 100 : 100
        },
        now: { now }
    )
    let outcome = try cleaner.run(scan: scan, config: .default, waterlineBytes: 30_000)
    #expect(outcome.entries.isEmpty)
    #expect(outcome.stillBelowWaterline == true)
}

@Test func cleanerReportsWillDeleteAndCleaned() throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("pp-clean4-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let paths = StoragePaths(baseURL: dir)
    let logStore = CleanLogStore(paths: paths)
    let now = Date(timeIntervalSince1970: 1_000_000)
    let item = ScanItem(
        id: "cb", recipeID: "xctestdevices", name: "XCTest", path: "/tmp/cb",
        category: .xcode, safety: .safeWhileRunning, disposition: .deletePermanently,
        sizeBytes: 1000, allocatedBytes: 1000, reclaimableBytes: 1000,
        fileCount: 1, lastModified: now.addingTimeInterval(-10 * 86_400)
    )
    let scan = ScanResult(
        volume: VolumeInfo(totalBytes: 100_000, availableBytes: 10_000, timestamp: now),
        items: [item], records: [], volumeURL: URL(fileURLWithPath: "/")
    )
    let box = ReaderBox()
    let cleaner = Cleaner(
        evaluator: RuleEvaluator(config: .default, now: { now }),
        deleter: MockDeleter(),
        inspector: AlwaysFalseProcessInspector(),
        logStore: logStore,
        availableBytesReader: { _ in
            box.calls += 1
            return box.calls == 1 ? 100 : 200
        },
        now: { now }
    )
    let capture = CaptureBox()
    _ = try cleaner.run(
        scan: scan,
        config: .default,
        waterlineBytes: 30_000,
        onItemWillDelete: { capture.will.append($0) },
        onItemCleaned: { itemID, _ in capture.cleaned.append(itemID) }
    )
    #expect(capture.will == ["cb"])
    #expect(capture.cleaned == ["cb"])
}

@Test func cleanerProcessesLargerItemsFirst() throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("pp-clean5-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let paths = StoragePaths(baseURL: dir)
    let logStore = CleanLogStore(paths: paths)
    let now = Date(timeIntervalSince1970: 1_000_000)
    func item(_ id: String, bytes: Int64, path: String) -> ScanItem {
        ScanItem(
            id: id, recipeID: "library-caches", name: id, path: path,
            category: .common, safety: .safeWhileRunning, disposition: .deletePermanently,
            sizeBytes: bytes, allocatedBytes: bytes, reclaimableBytes: bytes,
            fileCount: 1, lastModified: now.addingTimeInterval(-40 * 86_400)
        )
    }
    let scan = ScanResult(
        volume: VolumeInfo(totalBytes: 100_000_000, availableBytes: 10_000_000, timestamp: now),
        items: [
            item("big", bytes: 5_000_000, path: "/tmp/big"),
            item("small", bytes: 500_000, path: "/tmp/small"),
        ],
        records: [],
        volumeURL: URL(fileURLWithPath: "/")
    )
    let box = ReaderBox()
    let cleaner = Cleaner(
        evaluator: RuleEvaluator(config: .default, now: { now }),
        deleter: MockDeleter(),
        inspector: AlwaysFalseProcessInspector(),
        logStore: logStore,
        availableBytesReader: { _ in
            box.calls += 1
            return box.calls == 1 ? 20_000_000 : 60_000_000
        },
        now: { now }
    )
    let capture = CaptureBox()
    _ = try cleaner.run(
        scan: scan,
        config: .default,
        waterlineBytes: 30_000_000,
        onItemWillDelete: { capture.will.append($0) },
        onItemCleaned: { itemID, _ in capture.cleaned.append(itemID) }
    )
    #expect(capture.will == ["big", "small"])
    #expect(capture.cleaned == ["big", "small"])
}

@Test func cleanabilityGuardDowngradesPermanentDeleteToTrash() {
    #expect(Cleaner.guardedDisposition(for: .deletePermanently, cleanability: .trashOnly) == .trash)
    #expect(Cleaner.guardedDisposition(for: .deletePermanently, cleanability: .regenerable) == .deletePermanently)
}

@Test func cleanabilityGuardBlocksDisplayOnly() {
    #expect(Cleaner.guardedDisposition(for: .trash, cleanability: .displayOnly) == nil)
    #expect(Cleaner.guardedDisposition(for: .deletePermanently, cleanability: .displayOnly) == nil)
}
