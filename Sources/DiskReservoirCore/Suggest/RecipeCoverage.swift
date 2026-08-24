import Foundation

/// 配方覆盖判定：判断一个路径是否已被某个配方"监控"（路径本身或其祖先被覆盖）。
public enum RecipeCoverage {
    /// 所有配方覆盖路径的脱敏模式（去重）。
    public static func coveredPatterns(recipes: [Recipe], homeDirectory: String) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for recipe in recipes {
            for path in recipe.resolvePaths(StoragePaths(baseURL: nil, homeDirectory: homeDirectory)) {
                let pattern = PathPatternizer.patternize(path, homeDirectory: homeDirectory)
                if seen.insert(pattern).inserted {
                    result.append(pattern)
                }
            }
        }
        return result
    }

    /// 路径是否被覆盖：
    /// 1) 与某个覆盖模式相等，或位于其子树内；
    /// 2) 某覆盖模式是它的“直接子级”（父级聚合记录如 ~/Library/Developer/Xcode，
    ///    其子目录已由各配方管理 → 父级聚合视为已覆盖，不再显示为未覆盖增长）。
    public static func isCovered(
        path: String,
        coveredPatterns: [String],
        homeDirectory: String
    ) -> Bool {
        let pattern = PathPatternizer.patternize(path, homeDirectory: homeDirectory)
        return coveredPatterns.contains { root in
            root == pattern || pattern.hasPrefix(root + "/")
        } || coveredPatterns.contains { root in
            // 覆盖根是当前路径的直接子级：root == "<pattern>/<一级名>"
            root.hasPrefix(pattern + "/")
                && !root.dropFirst(pattern.count + 1).contains("/")
        }
    }
}
