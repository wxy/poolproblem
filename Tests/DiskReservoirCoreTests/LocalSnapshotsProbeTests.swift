import Testing
import Foundation
@testable import DiskReservoirCore

@Test func probeParseExtractsTimeMachineLines() {
    let output = """
    snapshot dates:
    com.apple.TimeMachine.2026-09-20-120000.local
    com.apple.TimeMachine.2026-09-21-121500.local

    """
    let parsed = TMUtilSnapshotsProbe.parse(output)
    #expect(parsed.count == 2)
    #expect(parsed[0] == "com.apple.TimeMachine.2026-09-20-120000.local")
}

@Test func probeParseReturnsEmptyForNoSnapshots() {
    #expect(TMUtilSnapshotsProbe.parse("").isEmpty)
    #expect(TMUtilSnapshotsProbe.parse("No snapshots for volume /").isEmpty)
}

@Test func probeReturnsNilWhenTMUtilUnavailable() {
    // 未知 ≠ 零快照：tmutil 缺失必须返回 nil，调用方不得当作「无快照」。
    let probe = TMUtilSnapshotsProbe(tmutilURL: URL(fileURLWithPath: "/nonexistent/tmutil"))
    #expect(probe.listLocalSnapshots(volumePath: "/") == nil)
}

private struct FakeProbe: LocalSnapshotsProbing {
    let result: [String]?

    func listLocalSnapshots(volumePath: String) -> [String]? { result }
}

@Test func probeProtocolDistinguishesUnknownFromEmpty() {
    // 语义锁定：nil（未知）与 []（确实没有快照）是两种不同的探测结果。
    #expect(FakeProbe(result: nil).listLocalSnapshots(volumePath: "/") == nil)
    #expect(FakeProbe(result: []).listLocalSnapshots(volumePath: "/") == [])
}
