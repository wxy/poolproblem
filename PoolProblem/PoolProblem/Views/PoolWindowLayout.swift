import Foundation
import CoreGraphics
import DiskReservoirCore

/// 水池可视窗口布局算法（`PoolTankView` 与预渲染标尺 `GaugeImageRenderer` 共用同一套坐标）：
///
/// 双锚点模型：
/// - 水面默认保持在垂直中线附近（`preferredSurfaceFraction = 0.5`），但这不是硬约束：
///   当可用空间较大、中线会迫使水线上方红区被窗口顶切掉时，水面自动下移
///   （最大 `maxSurfaceFraction`），保证水线上方至少 3 个 E 完整可见；
/// - 水线固定在标尺上方约 1/4 处（`waterlineFraction = 0.24`），保证红区有相当空间、
///   进水管有足够下伸空间；
/// - 通过这两个锚点反解窗口的字节上下界 `windowTop/windowBottom`，窗口可以伸出
///   `total`/`0` 之外——即"上方可用空间与下方不可清理项可能无法完全显示"。
///
/// 水位尺比例（字节/像素）的放大规则：
/// - 底部可见预算：可清理 + 手动 + 废纸篓 必须完整可见，不可清理项只保留
///   `sedimentPeekBytes` 的沉底窥视（深部沉淀直接切出窗口下缘）。
/// 指标卡片不参与刻度约束：它不要求一定在水面以下，跨度过大时自然随带移动。
struct PoolWindowLayout {
    let totalBytes: Int64
    let availableBytes: Int64
    let waterlineBytes: Int64
    let cleanableTotalBytes: Int64
    let nonCleanableBytes: Int64
    let manualBytes: Int64
    let trashBytes: Int64
    let height: CGFloat
    let topInset: CGFloat
    let preferredSurfaceFraction: Double
    let maxSurfaceFraction: Double
    let waterlineFraction: Double
    /// 不可清理项保留的“沉底窥视”字节量；更深部分允许被窗口下缘切掉。
    let sedimentPeekBytes: Int64
    let minimumSpanBytes: Int64

    init(
        totalBytes: Int64,
        availableBytes: Int64,
        waterlineBytes: Int64,
        cleanableTotalBytes: Int64 = 0,
        nonCleanableBytes: Int64 = 0,
        manualBytes: Int64 = 0,
        trashBytes: Int64 = 0,
        height: CGFloat = 560,
        topInset: CGFloat = 26,
        surfaceFraction: Double = 0.50,
        maxSurfaceFraction: Double = 0.85,
        waterlineFraction: Double = 0.24,
        sedimentPeekBytes: Int64 = 10_000_000_000,
        minimumSpanBytes: Int64 = 10_000_000_000
    ) {
        self.totalBytes = totalBytes
        self.availableBytes = availableBytes
        self.waterlineBytes = waterlineBytes
        self.cleanableTotalBytes = cleanableTotalBytes
        self.nonCleanableBytes = nonCleanableBytes
        self.manualBytes = manualBytes
        self.trashBytes = trashBytes
        self.height = height
        self.topInset = topInset
        self.preferredSurfaceFraction = surfaceFraction
        self.maxSurfaceFraction = maxSurfaceFraction
        self.waterlineFraction = waterlineFraction
        self.sedimentPeekBytes = sedimentPeekBytes
        self.minimumSpanBytes = minimumSpanBytes
    }

    var usableHeight: CGFloat { max(1, height - topInset) }

    var usedBytes: Double { Double(max(0, totalBytes - availableBytes)) }

    /// 水面比例：默认中线；可用空间大时下移以保证红区（≥3 个 E）完整可见。
    var surfaceFraction: Double {
        guard availableBytes > waterlineBytes else { return preferredSurfaceFraction }
        let needed = Double(availableBytes) * waterlineFraction / Double(max(waterlineBytes, 1))
        return min(max(preferredSurfaceFraction, needed), maxSurfaceFraction)
    }

    /// 目标水线比例：正常（可用 > 水线）在上方 1/4；低于目标水位时水线略低于水面，
    /// 保证水线标记仍然可见。
    private var effectiveWaterlineFraction: Double {
        availableBytes > waterlineBytes
            ? waterlineFraction
            : surfaceFraction + 0.06
    }

    /// 窗口字节跨度：由"水面 − 水线"的字节距离按比例反解，带最小跨度下限；
    /// 红区（水线到满盘）至少 3 个 E 完整可见，再按底部可见性预算兜底。
    var spanBytes: Double {
        let usable = usableHeight
        let gap = Double(availableBytes) - Double(waterlineBytes)
        let sf = surfaceFraction
        let fractionGap = sf - effectiveWaterlineFraction
        let derived = gap / max(fractionGap, 0.001)
        // 红区至少 3 个 E：span ≤ 水线字节 × 可用像素高 ÷ (3 × 最小 E 像素)
        let maxSpanForRed = Double(waterlineBytes) * usable / (3 * GaugeScale.minEPixels)
        // 底部可见预算：可清理 + 手动 + 废纸篓 完整可见，
        // 不可清理只保留沉底窥视（水面以下可见字节 = (1 - surfaceFraction) × span）
        let visibleBottom = Double(cleanableTotalBytes + manualBytes + trashBytes + sedimentPeekBytes)
        let bottomFloor = visibleBottom / max(1 - sf, 0.001)
        // 红区优先：跨度不得超过红区上限（冲突时宁可底部带被切，也要保住 3 个 E）
        return max(
            Double(minimumSpanBytes),
            min(max(derived, bottomFloor), max(maxSpanForRed, Double(minimumSpanBytes)))
        )
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
            manualBytes: model.manualBytes,
            trashBytes: model.trashBytes,
            height: height
        )
        return (layout, model)
    }
}
