import Testing
import Foundation
@testable import DiskReservoirCore

@Test func growthEvidenceSustainedThreshold() {
    // 持续型：30 天口径累计 ≥ 2GB
    #expect(GrowthEvidence.passes(deltaBytes: 2 << 30, elapsedDays: 30))
    #expect(GrowthEvidence.passes(deltaBytes: 3 << 30, elapsedDays: 45))
    #expect(!GrowthEvidence.passes(deltaBytes: (2 << 30) - 1, elapsedDays: 40))
}

@Test func growthEvidenceJumpThreshold() {
    // 跳变型：7 天窗口内单次 ≥ 1GB
    #expect(GrowthEvidence.passes(deltaBytes: 1 << 30, elapsedDays: 1))
    #expect(GrowthEvidence.passes(deltaBytes: 1 << 30, elapsedDays: 7))
    // 超出跳变窗口后必须满足持续型阈值
    #expect(!GrowthEvidence.passes(deltaBytes: 1 << 30, elapsedDays: 8))
    #expect(!GrowthEvidence.passes(deltaBytes: (1 << 30) - 1, elapsedDays: 1))
}

@Test func growthEvidenceRejectsSmallSlowGrowth() {
    // 缓慢/小幅增长不产生建议：这正是「不关注清单」的量化边界
    #expect(!GrowthEvidence.passes(deltaBytes: 500 << 20, elapsedDays: 1))
    #expect(!GrowthEvidence.passes(deltaBytes: 100 << 20, elapsedDays: 30))
    #expect(!GrowthEvidence.passes(deltaBytes: 0, elapsedDays: 1))
}
