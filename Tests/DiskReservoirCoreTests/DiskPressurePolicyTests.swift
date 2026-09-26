import Foundation
import Testing
@testable import DiskReservoirCore

@Test func diskPressurePolicySeparatesCheapMonitoringAnalysisAndEmergency() {
    let policy = DiskPressurePolicy(targetBytes: 30_000_000_000)
    #expect(policy.state(availableBytes: 45_000_000_000) == .healthy)
    #expect(policy.state(availableBytes: 35_000_000_000) == .warning)
    #expect(policy.state(availableBytes: 29_999_999_999) == .critical)
    #expect(policy.recoveryTargetBytes > policy.targetBytes)
}

@Test func diskPressureAnalysisIsEdgeTriggeredRateLimitedAndDropSensitive() {
    let policy = DiskPressurePolicy(targetBytes: 30_000_000_000)
    let now = Date()

    #expect(policy.shouldAnalyze(
        state: .warning,
        previousState: .healthy,
        now: now,
        lastAnalysisAt: now,
        availableBytes: 35_000_000_000,
        lastAnalyzedAvailableBytes: 35_000_000_000
    ))
    #expect(!policy.shouldAnalyze(
        state: .warning,
        previousState: .warning,
        now: now,
        lastAnalysisAt: now.addingTimeInterval(-10 * 60),
        availableBytes: 34_500_000_000,
        lastAnalyzedAvailableBytes: 35_000_000_000
    ))
    #expect(policy.shouldAnalyze(
        state: .warning,
        previousState: .warning,
        now: now,
        lastAnalysisAt: now.addingTimeInterval(-10 * 60),
        availableBytes: 33_900_000_000,
        lastAnalyzedAvailableBytes: 35_000_000_000
    ))
    #expect(policy.shouldAnalyze(
        state: .critical,
        previousState: .critical,
        now: now,
        lastAnalysisAt: now.addingTimeInterval(-11 * 60),
        availableBytes: 29_000_000_000,
        lastAnalyzedAvailableBytes: 29_100_000_000
    ))
    #expect(!policy.shouldAnalyze(
        state: .healthy,
        previousState: .warning,
        now: now,
        lastAnalysisAt: .distantPast,
        availableBytes: 50_000_000_000,
        lastAnalyzedAvailableBytes: nil
    ))
}
