import Testing
import Foundation
import CoreGraphics
@testable import PoolProblem

private let total = Int64(1_000_000_000_000)  // 1TB

@MainActor
@Test func layoutKeepsSurfaceCenteredWithBottomReserve() {
    let layout = PoolWindowLayout(
        totalBytes: total,
        availableBytes: 200_000_000_000,
        waterlineBytes: 30_000_000_000,
        cleanableTotalBytes: 50_000_000_000,
        nonCleanableBytes: 100_000_000_000,
        manualBytes: 20_000_000_000,
        trashBytes: 10_000_000_000,
        height: 560
    )
    // 中线：26 + 534/2 = 293
    #expect(abs(layout.surfaceY - 293) < 0.5)
    // 水线至少保留红区可读空间（≥ 26 + 0.15×534）
    #expect(layout.waterlineY >= 26 + 0.15 * 534)
    #expect(layout.waterlineY < layout.surfaceY)
    // 底部三段（不可清理+手动+废纸篓）至少占用 bottomReserveHeight（150pt）
    let bottomBytes = 100_000_000_000 + 20_000_000_000 + 10_000_000_000
    let bandHeight = layout.y(forBytes: 0) - layout.y(forBytes: Double(bottomBytes))
    #expect(bandHeight >= 145)
}

@MainActor
@Test func layoutZoomsInWhenBottomBandsAreSmall() {
    let layout = PoolWindowLayout(
        totalBytes: total,
        availableBytes: 800_000_000_000,
        waterlineBytes: 30_000_000_000,
        cleanableTotalBytes: 50_000_000_000,
        nonCleanableBytes: 100_000_000_000,
        trashBytes: 10_000_000_000,
        height: 560
    )
    // 底部三段预留把跨度缩小（水位尺比例放大）：
    // 窗口仍包含全部图层（span ≥ 图层合计），水面保持居中
    #expect(layout.spanBytes >= 160_000_000_000)
    #expect(abs(layout.surfaceY - 293) < 0.5)
    #expect(layout.waterlineY < layout.surfaceY)
    #expect(layout.windowBottomBytes >= 0)
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
    // 窗口被底部预留收窄后，用窗口内的两个值验证单调性
    let windowTop = layout.windowTopBytes
    let windowBottom = layout.windowBottomBytes
    let mid = (windowTop + windowBottom) / 2
    let lower = layout.y(forBytes: windowBottom + (windowTop - windowBottom) * 0.2)
    let higher = layout.y(forBytes: mid)
    #expect(higher < lower)
    #expect(higher >= 26 && lower <= 560)
    #expect(layout.y(forBytes: 10_000_000_000_000) >= 26)  // 窗口外 → 钳制
    #expect(layout.y(forBytes: -1) <= 560)
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
