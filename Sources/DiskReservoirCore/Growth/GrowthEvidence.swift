import Foundation

/// 增长证据门槛（docs/superpowers/plans/2026-09-24-mole-informed-improvements.md §0.1）。
///
/// 决定「一条增长记录是否值得向用户提出建议（纳入监视或纳入清理配方）」：
/// 缓慢增长与增长幅度很小的目标不产生建议——建议噪声本身就是成本。
/// 阈值复用设计文档的增长警报体系：绝对 2GB / 相对 50%（台账条目无基线，
/// 相对项不适用）/ 跳变 1GB。证据来自 GrowthLedger 既有记录，零额外扫描。
public enum GrowthEvidence: Sendable {
    /// 持续型：30 天口径的绝对增长阈值。
    public static let sustainedAbsoluteBytes: Int64 = 2 << 30
    /// 跳变型：单次观测增量的绝对阈值。
    public static let jumpAbsoluteBytes: Int64 = 1 << 30
    /// 跳变型的观测窗口上限（天）。
    public static let jumpWindowDays: Double = 7

    /// 一条增长记录是否达到建议门槛：
    /// - 持续型：累计增量 ≥ 2GB；
    /// - 跳变型：短窗口（≤ 7 天）内单次增量 ≥ 1GB。
    public static func passes(deltaBytes: Int64, elapsedDays: Double) -> Bool {
        deltaBytes >= sustainedAbsoluteBytes
            || (deltaBytes >= jumpAbsoluteBytes && elapsedDays <= jumpWindowDays)
    }
}
