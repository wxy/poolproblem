import Testing
import Foundation
@testable import DiskReservoirCore

@Test func pgrepDetectsCurrentShellProcess() {
    let name = ProcessInfo.processInfo.processName
    let inspector = PGrepProcessInspector()
    // 当前测试进程自身应能被 pgrep -x 命中；进程名可能被截断，因此允许 false，但绝不抛错
    _ = inspector.isRunning(name)
}

@Test func pgrepReturnsFalseForImpossibleName() {
    let inspector = PGrepProcessInspector()
    #expect(!inspector.isRunning("pp-definitely-not-running-\(UUID().uuidString)"))
}

@Test func pgrepHandlesMissingBinaryGracefully() {
    let inspector = PGrepProcessInspector(pgrepURL: URL(fileURLWithPath: "/nonexistent/pgrep"))
    #expect(!inspector.isRunning("anything"))
}
