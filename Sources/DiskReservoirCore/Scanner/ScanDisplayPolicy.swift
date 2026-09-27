/// 只影响界面上的配方列表，不删除扫描数据，也不改变自动清理候选。
public enum ScanDisplayPolicy {
    public static func visibleItems(_ items: [ScanItem], recipes: [Recipe]) -> [ScanItem] {
        let minimumByID = Dictionary(uniqueKeysWithValues: recipes.map { ($0.id, $0.minimumSizeMB) })
        return items.filter { item in
            if item.recipeID == "trash" || item.recipeID == "own-trash-batches" { return true }
            let minimumMB = minimumByID[item.recipeID] ?? 0
            return Double(item.allocatedBytes) >= max(0, minimumMB) * 1_000_000
        }
    }
}
