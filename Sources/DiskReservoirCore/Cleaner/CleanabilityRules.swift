import Foundation

/// 可清理判定的共享规则：聚合扫描与 RuleEvaluator 使用同一套年龄标准。
public enum CleanabilityRules {
    /// 是否达到可清理年龄：最后使用时间早于年龄阈值，且最近 24 小时没有修改。
    public static func isOldEnough(
        lastModified: Date?,
        ageLimitDays: Int,
        now: Date
    ) -> Bool {
        guard let lastModified else { return false }
        let age = now.timeIntervalSince(lastModified)
        return age > Double(ageLimitDays) * 86_400 && age > 86_400
    }
}
