import Testing
@testable import DiskReservoirCore

@Test func thresholdsScaleWithDefaultWaterline() {
    let t = CleanThresholds(waterlineGB: 30)
    #expect(t.proactiveTriggerBytes == 5_000_000_000)
    #expect(t.batchBytes == 3_000_000_000)
    #expect(t.earlyTriggerBytes == 7_500_000_000)
}

@Test func thresholdsScaleUpWithLargerWaterline() {
    let t = CleanThresholds(waterlineGB: 100)
    #expect(t.proactiveTriggerBytes == 16_666_666_666)
    #expect(t.batchBytes == 10_000_000_000)
    #expect(t.earlyTriggerBytes == 25_000_000_000)
}

@Test func thresholdsHaveFloorsForSmallWaterline() {
    let t = CleanThresholds(waterlineGB: 10)
    #expect(t.proactiveTriggerBytes == 3_000_000_000)
    #expect(t.batchBytes == 2_000_000_000)
    #expect(t.earlyTriggerBytes == 5_000_000_000)
}
