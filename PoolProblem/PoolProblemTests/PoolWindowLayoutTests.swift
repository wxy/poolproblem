import Testing
import Foundation
import CoreGraphics
@testable import PoolProblem

private let total = Int64(1_000_000_000_000)  // 1TB

@MainActor
@Test func layoutPutsSurfaceAtCenterAndWaterlineAtQuarter() {
    let layout = PoolWindowLayout(
        totalBytes: total,
        availableBytes: 200_000_000_000,
        waterlineBytes: 30_000_000_000,
        cleanableTotalBytes: 50_000_000_000,
        nonCleanableBytes: 100_000_000_000,
        trashBytes: 10_000_000_000,
        height: 560
    )
    // 中线：26 + 534/2 = 293
    #expect(abs(layout.surfaceY - 293) < 0.5)
    // 水线：26 + 0.24×534 ≈ 154
    #expect(abs(layout.waterlineY - (26 + 0.24 * 534)) < 0.5)
}

@MainActor
@Test func layoutAllowsWindowToExtendBeyondTotalAndZero() {
    let layout = PoolWindowLayout(
        totalBytes: total,
        availableBytes: 800_000_000_000,
        waterlineBytes: 30_000_000_000,
        cleanableTotalBytes: 50_000_000_000,
        nonCleanableBytes: 100_000_000_000,
        trashBytes: 10_000_000_000,
        height: 560
    )
    // 可用空间很大时：窗口上界超过 total（上方可用空间显示不全）
    #expect(layout.windowTopBytes > Double(total))
    // 窗口下界低于 0（下方不可清理项显示不全）
    #expect(layout.windowBottomBytes < 0)
    // 水面与水线仍在目标位置
    #expect(abs(layout.surfaceY - 293) < 0.5)
    #expect(abs(layout.waterlineY - (26 + 0.24 * 534)) < 0.5)
}

@MainActor
@Test func layoutFloorsSpanWhenGapIsTiny() {
    let layout = PoolWindowLayout(
        totalBytes: total,
        availableBytes: 30_000_000_000,
        waterlineBytes: 30_000_000_000,
        cleanableTotalBytes: 5_000_000_000,
        nonCleanableBytes: 10_000_000_000,
        trashBytes: 0,
        height: 560,
        minimumSpanBytes: 10_000_000_000
    )
    // gap = 0 时回落到下限（max(10GB, 图层合计 15GB)）
    #expect(layout.spanBytes == 15_000_000_000)
    #expect(layout.surfaceY >= 26)
}

@MainActor
@Test func layoutMappingIsMonotonicAndClamped() {
    let layout = PoolWindowLayout(
        totalBytes: total,
        availableBytes: 200_000_000_000,
        waterlineBytes: 30_000_000_000,
        cleanableTotalBytes: 50_000_000_000,
        nonCleanableBytes: 100_000_000_000,
        trashBytes: 10_000_000_000,
        height: 560
    )
    let higher = layout.y(forBytes: 500_000_000_000)  // 已用更多 → 更靠上
    let lower = layout.y(forBytes: 100_000_000_000)
    #expect(higher < lower)
    #expect(higher >= 26 && lower <= 560)
    #expect(layout.y(forBytes: 10_000_000_000_000) >= 26)  // 窗口外 → 钳制
    #expect(layout.y(forBytes: 0) <= 560)
}

@MainActor
@Test func layoutKeepsWaterlineVisibleWhenBelowTarget() {
    let layout = PoolWindowLayout(
        totalBytes: total,
        availableBytes: 10_000_000_000,
        waterlineBytes: 30_000_000_000,
        cleanableTotalBytes: 5_000_000_000,
        nonCleanableBytes: 10_000_000_000,
        trashBytes: 0,
        height: 560
    )
    // 低于目标水位：水线略低于水面，但仍在窗口内
    #expect(layout.waterlineY > layout.surfaceY)
    #expect(layout.waterlineY <= 560)
}
