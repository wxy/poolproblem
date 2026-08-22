import Testing
@testable import DiskReservoirCore

private func ePixels(stepGB: Double, spanBytes: Double, height: Double = 534) -> Double {
    stepGB * 1_000_000_000 * height / spanBytes
}

@Test func gaugeStepStaysInBoundsForHugeSpan() {
    // 可用空间很大 → 跨度 654GB：旧逻辑会被“红区≥3格”卡到 10GB、E≈8px；
    // 新逻辑应选 50GB，E ≈ 40.8px ∈ [30, 64]
    let span = 654_000_000_000.0
    let step = GaugeScale.stepGB(spanBytes: span, usableHeight: 534)
    #expect(step == 50)
    #expect(ePixels(stepGB: step, spanBytes: span) >= GaugeScale.minEPixels)
    #expect(ePixels(stepGB: step, spanBytes: span) <= GaugeScale.maxEPixels)
}

@Test func gaugeStepStaysInBoundsForSmallSpan() {
    let span = 30_000_000_000.0
    let step = GaugeScale.stepGB(spanBytes: span, usableHeight: 534)
    #expect(step == 2)
    #expect(ePixels(stepGB: step, spanBytes: span) >= GaugeScale.minEPixels)
    #expect(ePixels(stepGB: step, spanBytes: span) <= GaugeScale.maxEPixels)
}

@Test func gaugeStepAlwaysYieldsReadableE() {
    for gb: Double in [20, 50, 100, 200, 500, 1000, 2000, 5000] {
        let span = gb * 1_000_000_000
        let step = GaugeScale.stepGB(spanBytes: span, usableHeight: 534)
        let e = ePixels(stepGB: step, spanBytes: span)
        #expect(e >= GaugeScale.minEPixels - 0.001)
        #expect(e <= GaugeScale.maxEPixels + 0.001)
    }
}
