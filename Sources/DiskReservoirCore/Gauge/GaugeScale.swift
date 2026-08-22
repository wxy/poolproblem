import Foundation

/// E 字型标尺的缩放控制：由“E 的像素高度上下限”反解步长。
///
/// 第一性原理：E 是整个图的缩放旋钮，必须有上下限——太小看不清、太大装不下内容。
/// E 像素高度 = step × 可用像素高 ÷ 跨度；候选步长（2/5/10/20/50/100GB）中取
/// E 高度落在 [minEPixels, maxEPixels] 内的第一个（候选几何递增，必有解），
/// 兜底取 E 最接近目标值的候选。
public enum GaugeScale {
    public static let minEPixels: Double = 30
    public static let maxEPixels: Double = 64
    public static let targetEPixels: Double = 44
    /// 几何递增候选；真实磁盘跨度通常远小于最大值，大候选仅为保证
    /// “E 高度永不小于 minEPixels”这个不变量在极端跨度下也成立。
    public static let stepCandidatesGB: [Double] = [2, 5, 10, 20, 50, 100, 200, 500]

    public static func stepGB(spanBytes: Double, usableHeight: Double) -> Double {
        let h = max(usableHeight, 1)
        let denominator = max(spanBytes, 1)
        for candidate in stepCandidatesGB {
            let e = candidate * 1_000_000_000 * h / denominator
            if e >= minEPixels && e <= maxEPixels {
                return candidate
            }
        }
        return stepCandidatesGB.min { lhs, rhs in
            abs(lhs * 1_000_000_000 * h / denominator - targetEPixels)
                < abs(rhs * 1_000_000_000 * h / denominator - targetEPixels)
        } ?? 10
    }
}
