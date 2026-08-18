import Testing
import Foundation
@testable import DiskReservoirCore

@Test func fseventMonitorDeliversEventsForWatchedDirectory() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("pp-fsevents-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    // FSEvents 回传真实路径（/private/var/...），与 /var 符号链接路径对齐
    let watchRoot = root.resolvingSymlinksInPath().path

    let monitor = FSEventMonitor(paths: [root.path], latency: 0.2)
    let events = AsyncStream<String> { continuation in
        monitor.start { paths in
            for path in paths { continuation.yield(path) }
        }
        continuation.onTermination = { _ in monitor.stop() }
    }
    // 留出流建立时间，再写入触发事件
    try await Task.sleep(nanoseconds: 500_000_000)
    try Data(repeating: 0x41, count: 10).write(to: root.appendingPathComponent("t.bin"))
    // 5 秒内等第一个命中事件（流消费任务与超时任务竞争）
    let hit = try await withThrowingTaskGroup(of: Bool.self) { group in
        group.addTask {
            for await path in events
            where URL(fileURLWithPath: path).resolvingSymlinksInPath().path.hasPrefix(watchRoot) {
                return true
            }
            return false
        }
        group.addTask {
            try await Task.sleep(nanoseconds: 5_000_000_000)
            return false
        }
        let result = try await group.next() ?? false
        group.cancelAll()
        return result
    }
    #expect(hit)
    monitor.stop()
}
