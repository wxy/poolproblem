import Foundation

/// 与水位线成比例的自动清理阈值（GB 级别，含下限）。
///
/// 第一性原理：预警带、单批清理量、库存提前触发量都应随目标水位缩放——
/// 水位线 100GB 时 5GB 的预警带和 3GB 的批次没有意义。
/// 默认 30GB 时与历史常量一致（5GB / 3GB / 8GB 附近）。
public struct CleanThresholds: Equatable, Sendable {
    /// 水位线以上的预警带：进入该区间开始主动清理。
    public let proactiveTriggerBytes: Int64
    /// 单轮主动清理的目标释放量。
    public let batchBytes: Int64
    /// 可清理库存达到该值且远离水位时提前清理。
    public let earlyTriggerBytes: Int64

    public init(waterlineGB: Double) {
        let waterline = Int64(waterlineGB * 1_000_000_000)
        proactiveTriggerBytes = max(3_000_000_000, waterline / 6)
        batchBytes = max(2_000_000_000, waterline / 10)
        earlyTriggerBytes = max(5_000_000_000, waterline / 4)
    }
}
