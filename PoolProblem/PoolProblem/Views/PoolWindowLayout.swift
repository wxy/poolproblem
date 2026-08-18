import Foundation
import CoreGraphics
import DiskReservoirCore

/// 水池可视窗口布局算法（`PoolTankView` 与预渲染标尺 `GaugeImageRenderer` 共用同一套坐标）：
///
/// 双锚点模型：
/// - 水面固定在水池垂直中线（`surfaceFraction = 0.5`）；
/// - 水线固定在标尺上方约 1/4 处（`waterlineFraction = 0.24`），保证红区有相当空间、
///   进水管有足够下伸空间；
/// - 通过这两个锚点反解窗口的字节上下界 `windowTop/windowBottom`，窗口可以伸出
///   `total`/`0` 之外——即"上方可用空间与下方不可清理项可能无法完全显示"。
struct PoolWindowLayout {
    let totalBytes: Int64
    let availableBytes: Int64
    let waterlineBytes: Int64
    let cleanableTotalBytes: Int64
    let nonCleanableBytes: Int64
    let trashBytes: Int64
    let height: CGFloat
    let topInset: CGFloat
    let surfaceFraction: Double
    let waterlineFraction: Double
    let minimumSpanBytes: Int64

    init(
        totalBytes: Int64,
        availableBytes: Int64,
        waterlineBytes: Int64,
        cleanableTotalBytes: Int64 = 0,
        nonCleanableBytes: Int64 = 0,
        trashBytes: Int64 = 0,
        height: CGFloat = 560,
        topInset: CGFloat = 26,
        surfaceFraction: Double = 0.50,
        waterlineFraction: Double = 0.24,
        minimumSpanBytes: Int64 = 10_000_000_000
    ) {
        self.totalBytes = totalBytes
        self.availableBytes = availableBytes
        self.waterlineBytes = waterlineBytes
        self.cleanableTotalBytes = cleanableTotalBytes
        self.nonCleanableBytes = nonCleanableBytes
        self.trashBytes = trashBytes
        self.height = height
        self.topInset = topInset
        self.surfaceFraction = surfaceFraction
        self.waterlineFraction = waterlineFraction
        self.minimumSpanBytes = minimumSpanBytes
    }

    var usableHeight: CGFloat { max(1, height - topInset) }

    var usedBytes: Double { Double(max(0, totalBytes - availableBytes)) }

    /// 目标水线比例：正常（可用 > 水线）在上方 1/4；低于目标水位时水线略低于水面，
    /// 保证水线标记仍然可见。
    private var effectiveWaterlineFraction: Double {
        availableBytes > waterlineBytes
            ? waterlineFraction
            : surfaceFraction + 0.06
    }

    /// 窗口字节跨度：由"水面 − 水线"的字节距离按比例反解，带最小跨度下限
    /// （避免磁盘恰好压在水线时无限放大）。
    var spanBytes: Double {
        let gap = Double(availableBytes) - Double(waterlineBytes)
        let fractionGap = surfaceFraction - effectiveWaterlineFraction
        let derived = gap / fractionGap
        let floor = Double(max(
            minimumSpanBytes,
            cleanableTotalBytes + nonCleanableBytes + trashBytes
        ))
        return max(derived, floor)
    }

    var windowTopBytes: Double {
        usedBytes + surfaceFraction * spanBytes
    }

    var windowBottomBytes: Double {
        windowTopBytes - spanBytes
    }

    var surfaceY: CGFloat { y(forBytes: usedBytes) }

    var waterlineY: CGFloat {
        y(forBytes: Double(max(0, totalBytes - waterlineBytes)))
    }

    /// 线性映射：`value` 为已用字节数（越大越靠上）。
    func y(forBytes value: Double) -> CGFloat {
        let fraction = (windowTopBytes - value) / spanBytes
        return topInset + CGFloat(min(max(fraction, 0), 1)) * usableHeight
    }
}

extension PoolWindowLayout {
    /// 从扫描数据构建完整布局（内部完成图层拆分）。
    static func make(
        totalBytes: Int64,
        availableBytes: Int64,
        waterlineBytes: Int64,
        items: [ScanItem],
        estimatedRecipeIDs: Set<String>,
        excludedItemIDs: Set<String> = [],
        height: CGFloat = 560
    ) -> (layout: PoolWindowLayout, model: PoolLayerModel) {
        let model = PoolLayers.make(
            items: items,
            totalBytes: totalBytes,
            availableBytes: availableBytes,
            estimatedRecipeIDs: estimatedRecipeIDs,
            excludedItemIDs: excludedItemIDs
        )
        let cleanableTotal = model.layers.reduce(Int64(0)) { $0 + $1.bytes }
        let layout = PoolWindowLayout(
            totalBytes: totalBytes,
            availableBytes: availableBytes,
            waterlineBytes: waterlineBytes,
            cleanableTotalBytes: cleanableTotal,
            nonCleanableBytes: model.nonCleanableBytes,
            trashBytes: model.trashBytes,
            height: height
        )
        return (layout, model)
    }
}
