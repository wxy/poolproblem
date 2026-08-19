import Testing
import Foundation
import CoreGraphics
@testable import PoolProblem

private let total = Int64(1_000_000_000_000)  // 1TB

@MainActor
@Test func layoutZoomsIntoUsedRegionWhenDiskIsNearlyFull() {
    let layout = PoolWindowLayout(
        totalBytes: 250_000_000_000,
        availableBytes: 38_000_000_000,
        waterlineBytes: 30_000_000_000,
        cleanableTotalBytes: 9_000_000_000,
        nonCleanableBytes: 168_000_000_000,
        manualBytes: 28_000_000_000,
        trashBytes: 7_000_000_000,
        height: 560
    )
    // 中线：26 + 534/2 = 293
    #expect(abs(layout.surfaceY - 293) < 0.5)
    // 水线至少保留红区可读空间（≥ 26 + 0.15×534）
    #expect(layout.waterlineY >= 26 + 0.15 * 534)
    #expect(layout.waterlineY < layout.surfaceY)
    // 水位尺比例放大：窗口不再被迫包含全部已用空间（used = 212GB），
    // 而是只保证可清理+手动+废纸篓+沉底窥视可见（≈2×98GB）
    #expect(layout.spanBytes < 212_000_000_000)
    #expect(layout.spanBytes <= 2 * (9_000_000_000 + 28_000_000_000 + 7_000_000_000 + 10_000_000_000))
    // 深部沉淀被切出窗口：windowBottom > 0
    #expect(layout.windowBottomBytes > 0)
    // 指标卡片所在底部带仍保留 bottomReserveHeight（150pt）的可视高度
    let bandBytes = 168_000_000_000 + 28_000_000_000 + 7_000_000_000
    let bandHeight = layout.y(forBytes: 0) - layout.y(forBytes: Double(bandBytes))
    #expect(bandHeight >= 145)
}

@MainActor
@Test func layoutZoomsInWhenBottomBandsAreSmall() {
    let layout = PoolWindowLayout(
        totalBytes: total,
        availableBytes: 800_000_000_000,
        waterlineBytes: 30_000_000_000,
        cleanableTotalBytes: 70_000_000_000,
        nonCleanableBytes: 100_000_000_000,
        manualBytes: 20_000_000_000,
        trashBytes: 10_000_000_000,
        height: 560
    )
    // 磁盘大部分空闲：卡片预留把跨度压回合理范围，水面保持居中；
    // 底部带完全可见时高度不被压到卡片之下
    #expect(layout.spanBytes >= 160_000_000_000)
    #expect(abs(layout.surfaceY - 293) < 0.5)
    #expect(layout.waterlineY < layout.surfaceY)
    let bandBytes = 100_000_000_000 + 20_000_000_000 + 10_000_000_000
    let bandHeight = layout.y(forBytes: 0) - layout.y(forBytes: Double(bandBytes))
    #expect(bandHeight >= 145)
}

@MainActor
@Test func layoutFloorsSpanWhenGapIsTiny() {
    let layout = PoolWindowLayout(
        totalBytes: total,
        availableBytes: 30_000_000_000,
        waterlineBytes: 30_000_000_000,
        cleanableTotalBytes: 5_000_000_000,
        nonCleanableBytes: 965_000_000_000,
        trashBytes: 0,
        height: 560,
        minimumSpanBytes: 10_000_000_000
    )
    // gap = 0 时由底部可见预算兜底（5 + 0 + 0 + 10GB 沉底窥视）× 2
    #expect(layout.spanBytes == 30_000_000_000)
    #expect(layout.surfaceY >= 26)
}

@MainActor
@Test func layoutMappingIsMonotonicAndClamped() {
    let layout = PoolWindowLayout(
        totalBytes: total,
        availableBytes: 800_000_000_000,
        waterlineBytes: 30_000_000_000,
        cleanableTotalBytes: 70_000_000_000,
        nonCleanableBytes: 100_000_000_000,
        manualBytes: 20_000_000_000,
        trashBytes: 10_000_000_000,
        height: 560
    )
    // 用窗口内的两个值验证单调性
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
        nonCleanableBytes: 985_000_000_000,
        trashBytes: 0,
        height: 560
    )
    // 低于目标水位：水线略低于水面，但仍在窗口内
    #expect(layout.waterlineY > layout.surfaceY)
    #expect(layout.waterlineY <= 560)
}
