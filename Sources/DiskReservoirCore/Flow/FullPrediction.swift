import Foundation

public struct FullPrediction: Sendable {
    public init() {}

    /// 最近至多 7 个快照，对 availableBytes 做时间线性拟合；
    /// 斜率 < 0（可用空间正在消耗）时返回距水线耗尽的天数；斜率 >= 0 或样本不足 2 返回 nil。
    public func daysUntilFull(snapshots: [Snapshot], waterlineBytes: Int64) -> Double? {
        let points = Array(snapshots.suffix(7))
        guard points.count >= 2 else { return nil }
        let x: [Double] = points.enumerated().map { Double($0.offset) }
        let y: [Double] = points.map { Double($0.volume.availableBytes) }
        let n = Double(x.count)
        let sumX = x.reduce(0, +)
        let sumY = y.reduce(0, +)
        let sumXY = zip(x, y).map(*).reduce(0, +)
        let sumX2 = x.map { $0 * $0 }.reduce(0, +)
        let denom = n * sumX2 - sumX * sumX
        guard abs(denom) > 1e-9 else { return nil }
        let slope = (n * sumXY - sumX * sumY) / denom
        guard slope < 0 else { return nil }
        let headroom = Double(points.last!.volume.availableBytes) - Double(waterlineBytes)
        return headroom / (-slope)
    }
}
