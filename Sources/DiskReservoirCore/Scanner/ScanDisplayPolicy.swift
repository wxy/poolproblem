/// 只影响界面上的配方列表，不删除扫描数据，也不改变自动清理候选。
public enum ScanDisplayPolicy {
    /// Persisted scan items describe the recipe used at scan time. Present them
    /// with the stricter of that policy and the currently installed recipe.
    /// A removed recipe is never presented as cleanable from old scan data.
    public static func effectiveCleanability(_ item: ScanItem, recipes: [Recipe]) -> Cleanability {
        guard let current = recipes.first(where: { $0.id == item.recipeID }) else {
            return .displayOnly
        }
        if item.cleanability == .watchOnly || current.cleanability == .watchOnly { return .watchOnly }
        if item.cleanability == .displayOnly || current.cleanability == .displayOnly { return .displayOnly }
        if item.cleanability == .trashOnly || current.cleanability == .trashOnly { return .trashOnly }
        return .regenerable
    }

    public static func visibleItems(_ items: [ScanItem], recipes: [Recipe]) -> [ScanItem] {
        let minimumByID = Dictionary(uniqueKeysWithValues: recipes.map { ($0.id, $0.minimumSizeMB) })
        return items.filter { item in
            if item.recipeID == OwnerCommandRecipe.pnpmStorePrune.id {
                guard let current = recipes.first(where: { $0.id == item.recipeID }),
                      current.cleanability == .watchOnly,
                      current.disposition == .none,
                      current.resolvePaths(StoragePaths()).contains(item.path) else { return false }
            }
            if item.recipeID == "trash" || item.recipeID == "own-trash-batches" { return true }
            let minimumMB = minimumByID[item.recipeID] ?? 0
            return Double(item.allocatedBytes) >= max(0, minimumMB) * 1_000_000
        }
    }
}
