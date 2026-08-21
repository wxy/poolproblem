import Foundation

/// 增长洞察展示前的归并：同一目录/配方项的多条增长记录合并为一条。
///
/// 规则：
/// - 归并键优先用真实路径；路径为空（如 unknownSpace 桶）回退到 itemID。
/// - 同一键下完全相同的增量视为同一事件的重复记录，只保留一条，
///   避免“新出现项”因配方路径抖动被反复记录而双计。
/// - 其余不同增量累加为该目录的总增长。
public enum GrowthInsightMerger {
    public static func merge(_ entries: [GrowthEntry]) -> [GrowthEntry] {
        var order: [String] = []
        var byKey: [String: [GrowthEntry]] = [:]
        for entry in entries {
            let key = entry.path.isEmpty
                ? (entry.itemID ?? entry.pattern)
                : entry.path
            if byKey[key] == nil {
                order.append(key)
            }
            byKey[key, default: []].append(entry)
        }

        var result: [GrowthEntry] = []
        for key in order {
            guard let group = byKey[key] else { continue }
            var seenDeltas: Set<Int64> = []
            var unique: [GrowthEntry] = []
            for entry in group {
                if seenDeltas.contains(entry.deltaBytes) { continue }
                seenDeltas.insert(entry.deltaBytes)
                unique.append(entry)
            }
            guard let latest = unique.max(by: { $0.observedAt < $1.observedAt }) else { continue }
            let totalDelta = unique.reduce(Int64(0)) { $0 + $1.deltaBytes }
            let totalRate = unique.reduce(0.0) { $0 + $1.rateBytesPerDay }
            let totalElapsed = unique.reduce(0.0) { $0 + $1.elapsedDays }
            result.append(GrowthEntry(
                id: latest.id,
                observedAt: latest.observedAt,
                elapsedDays: totalElapsed,
                itemID: latest.itemID,
                recipeID: latest.recipeID,
                name: latest.name,
                path: latest.path,
                pattern: latest.pattern,
                kind: latest.kind,
                deltaBytes: totalDelta,
                rateBytesPerDay: totalRate
            ))
        }
        return result
    }
}
