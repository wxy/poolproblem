import Foundation

/// 增长洞察展示前按路径选取最新一次观测事件。
///
/// 不同观测窗口的增量、速率和时长不能分别相加后描述为一次变化。
public enum GrowthInsightMerger {
    public static func merge(_ entries: [GrowthEntry]) -> [GrowthEntry] {
        var latestByKey: [String: GrowthEntry] = [:]
        for entry in entries {
            let key = entry.path.isEmpty
                ? (entry.itemID ?? entry.pattern)
                : entry.path
            if let previous = latestByKey[key], previous.observedAt > entry.observedAt {
                continue
            }
            latestByKey[key] = entry
        }
        return latestByKey.values.sorted { $0.observedAt > $1.observedAt }
    }
}
