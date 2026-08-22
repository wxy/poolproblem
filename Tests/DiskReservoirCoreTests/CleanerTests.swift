import Testing
import Foundation
@testable import DiskReservoirCore

private struct MockDeleter: FileDeleting {
    func delete(url: URL, disposition: CleanDisposition) throws -> Int64 { 1024 }
}

private final class ThrowingFirstDeleter: FileDeleting, @unchecked Sendable {
    var calls = 0
    func delete(url: URL, disposition: CleanDisposition) throws -> Int64 {
        calls += 1
        if calls == 1 { throw CocoaError(.fileWriteNoPermission) }
        return 1024
    }
}

private final class RecordingDeleter: FileDeleting, @unchecked Sendable {
    let lock = NSLock()
    var urls: [URL] = []
    var freed = 1024

    func delete(url: URL, disposition: CleanDisposition) throws -> Int64 {
        lock.lock()
        urls.append(url)
        lock.unlock()
        return Int64(freed)
    }
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

@Test func cleanerDeletesEveryPathOfAggregateItem() throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("pp-cleanagg-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let paths = StoragePaths(baseURL: dir)
    let logStore = CleanLogStore(paths: paths)
    let now = Date(timeIntervalSince1970: 1_000_000)
    let item = ScanItem(
        id: "project-node-modules:aggregate",
        recipeID: "project-node-modules",
        name: "Project node_modules",
        path: "/tmp/A/node_modules",
        paths: ["/tmp/A/node_modules", "/tmp/B/node_modules"],
        category: .project,
        safety: .safeWhileRunning,
        disposition: .trash,
        sizeBytes: 10_000,
        allocatedBytes: 10_000,
        reclaimableBytes: 10_000,
        fileCount: 2,
        lastModified: now.addingTimeInterval(-40 * 86_400)
    )
    let scan = ScanResult(
        volume: VolumeInfo(totalBytes: 100_000, availableBytes: 20_000, timestamp: now),
        items: [item],
        records: [],
        volumeURL: URL(fileURLWithPath: "/")
    )
    let deleter = RecordingDeleter()
    let cleaner = Cleaner(
        evaluator: RuleEvaluator(config: .default, now: { now }),
        deleter: deleter,
        inspector: AlwaysFalseProcessInspector(),
        logStore: logStore,
        now: { now }
    )
    let outcome = try cleaner.run(scan: scan, config: .default, waterlineBytes: 30_000, forceClean: true)
    #expect(outcome.freedBytes == 2048)
    #expect(Set(deleter.urls.map(\.path)) == Set(["/tmp/A/node_modules", "/tmp/B/node_modules"]))
    let entry = try logStore.entries().first
    #expect(entry?.originalPaths == ["/tmp/A/node_modules", "/tmp/B/node_modules"])
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

@Test func cleanerPrefersPermanentDeletesForRealFreedSpace() throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("pp-clean-perm-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let paths = StoragePaths(baseURL: dir)
    let logStore = CleanLogStore(paths: paths)
    let now = Date(timeIntervalSince1970: 1_000_000)
    func item(_ id: String, bytes: Int64, disposition: CleanDisposition) -> ScanItem {
        ScanItem(
            id: id, recipeID: "library-caches", name: id, path: "/tmp/\(id)",
            category: .common, safety: .safeWhileRunning, disposition: disposition,
            sizeBytes: bytes, allocatedBytes: bytes, reclaimableBytes: bytes,
            fileCount: 1, lastModified: now.addingTimeInterval(-40 * 86_400)
        )
    }
    let scan = ScanResult(
        volume: VolumeInfo(totalBytes: 100_000_000, availableBytes: 10_000_000, timestamp: now),
        items: [
            // 大项走废纸篓（实际不释放空间），小项永久删除（立即释放）
            item("big-trash", bytes: 2_000_000_000, disposition: .trash),
            item("small-perm", bytes: 600_000_000, disposition: .deletePermanently),
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
    #expect(capture.will == ["small-perm", "big-trash"])
    #expect(capture.cleaned == ["small-perm", "big-trash"])
}

@Test func cleanerSkipsManualItemsEvenWhenForced() throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("pp-clean-manual-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let paths = StoragePaths(baseURL: dir)
    let logStore = CleanLogStore(paths: paths)
    let now = Date(timeIntervalSince1970: 1_000_000)
    let item = ScanItem(
        id: "simulator-runtimes:/Library/Developer/CoreSimulator/Volumes/iOS_23F77",
        recipeID: "simulator-runtimes", name: "模拟器运行时镜像", path: "/Library/Developer/CoreSimulator/Volumes/iOS_23F77",
        category: .simulator, safety: .userConfirm, disposition: .trash,
        sizeBytes: 1_000_000_000, allocatedBytes: 1_000_000_000, reclaimableBytes: 1_000_000_000,
        fileCount: 1, lastModified: now.addingTimeInterval(-40 * 86_400)
    )
    let scan = ScanResult(
        volume: VolumeInfo(totalBytes: 100_000_000, availableBytes: 10_000_000, timestamp: now),
        items: [item],
        records: [],
        volumeURL: URL(fileURLWithPath: "/")
    )
    let cleaner = Cleaner(
        evaluator: RuleEvaluator(config: .default, now: { now }),
        deleter: MockDeleter(),
        inspector: AlwaysFalseProcessInspector(),
        logStore: logStore,
        availableBytesReader: { _ in 20_000_000 },
        now: { now }
    )
    let outcome = try cleaner.run(
        scan: scan,
        config: .default,
        waterlineBytes: 30_000_000,
        forceClean: true
    )
    #expect(outcome.entries.isEmpty)
}

@Test func cleanerIgnoresAgeInEmergencyButKeepsDisposition() throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("pp-clean-ignoreage-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let paths = StoragePaths(baseURL: dir)
    let logStore = CleanLogStore(paths: paths)
    let now = Date(timeIntervalSince1970: 1_000_000)
    let item = ScanItem(
        id: "fresh", recipeID: "npm-cache", name: "npm", path: "/tmp/fresh",
        category: .packageManager, safety: .safeWhileRunning, disposition: .deletePermanently,
        sizeBytes: 1_000_000_000, allocatedBytes: 1_000_000_000, reclaimableBytes: 1_000_000_000,
        fileCount: 1, lastModified: now  // 刚修改过：正常情况下会被年龄保护跳过
    )
    let scan = ScanResult(
        volume: VolumeInfo(totalBytes: 100_000_000, availableBytes: 10_000_000, timestamp: now),
        items: [item],
        records: [],
        volumeURL: URL(fileURLWithPath: "/")
    )
    let capture = CaptureBox()
    let cleaner = Cleaner(
        evaluator: RuleEvaluator(config: .default, now: { now }),
        deleter: MockDeleter(),
        inspector: AlwaysFalseProcessInspector(),
        logStore: logStore,
        availableBytesReader: { _ in 20_000_000 },
        now: { now }
    )
    let outcome = try cleaner.run(
        scan: scan,
        config: .default,
        waterlineBytes: 30_000_000,
        ignoreAge: true,
        onItemWillDelete: { capture.will.append($0) },
        onItemCleaned: { itemID, disposition in capture.cleaned.append(itemID) }
    )
    #expect(capture.will == ["fresh"])
    #expect(outcome.entries.first?.disposition == .deletePermanently)
}

@Test func cleanerContinuesAfterSingleItemFailure() throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("pp-clean-continue-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let paths = StoragePaths(baseURL: dir)
    let logStore = CleanLogStore(paths: paths)
    let now = Date(timeIntervalSince1970: 1_000_000)
    func item(_ id: String) -> ScanItem {
        ScanItem(
            id: id, recipeID: "npm-cache", name: id, path: "/tmp/\(id)",
            category: .packageManager, safety: .safeWhileRunning, disposition: .deletePermanently,
            sizeBytes: 1_000_000_000, allocatedBytes: 1_000_000_000, reclaimableBytes: 1_000_000_000,
            fileCount: 1, lastModified: now.addingTimeInterval(-40 * 86_400)
        )
    }
    let scan = ScanResult(
        volume: VolumeInfo(totalBytes: 100_000_000, availableBytes: 10_000_000, timestamp: now),
        items: [item("first"), item("second")],
        records: [],
        volumeURL: URL(fileURLWithPath: "/")
    )
    let deleter = ThrowingFirstDeleter()
    let cleaner = Cleaner(
        evaluator: RuleEvaluator(config: .default, now: { now }),
        deleter: deleter,
        inspector: AlwaysFalseProcessInspector(),
        logStore: logStore,
        availableBytesReader: { _ in 20_000_000 },
        now: { now }
    )
    let outcome = try cleaner.run(scan: scan, config: .default, waterlineBytes: 30_000_000)
    #expect(outcome.entries.count == 1)
    #expect(outcome.entries[0].itemIDs == ["second"])
}

@Test func cleanabilityGuardDowngradesPermanentDeleteToTrash() {
    #expect(Cleaner.guardedDisposition(for: .deletePermanently, cleanability: .trashOnly) == .trash)
    #expect(Cleaner.guardedDisposition(for: .deletePermanently, cleanability: .regenerable) == .deletePermanently)
}

@Test func cleanabilityGuardBlocksDisplayOnly() {
    #expect(Cleaner.guardedDisposition(for: .trash, cleanability: .displayOnly) == nil)
    #expect(Cleaner.guardedDisposition(for: .deletePermanently, cleanability: .displayOnly) == nil)
}
