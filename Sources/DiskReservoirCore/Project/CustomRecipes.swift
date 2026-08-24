import Foundation

/// 用户从增长洞察“采纳建议”创建的自定义配方规格（可持久化到 Config）。
/// 一个配方对应一种增长类型，可能覆盖多个目录/位置；这里用一条路径模式表示。
public struct CustomRecipeSpec: Codable, Equatable, Sendable {
    public let id: String
    public let name: String
    /// 脱敏路径模式（如 ~/Library/Caches/foo）。
    public let pattern: String
    public let category: Category
    public let safety: SafetyLevel
    public let cleanability: Cleanability
    public let disposition: CleanDisposition
    public let defaultAgeDays: Int
    public let minimumSizeMB: Double

    public init(
        id: String,
        name: String,
        pattern: String,
        category: Category,
        safety: SafetyLevel,
        cleanability: Cleanability,
        disposition: CleanDisposition,
        defaultAgeDays: Int = 30,
        minimumSizeMB: Double = 100
    ) {
        self.id = id
        self.name = name
        self.pattern = pattern
        self.category = category
        self.safety = safety
        self.cleanability = cleanability
        self.disposition = disposition
        self.defaultAgeDays = defaultAgeDays
        self.minimumSizeMB = minimumSizeMB
    }
}

/// 把持久化的自定义配方规格还原为运行时 Recipe。
public enum CustomRecipes {
    public static func make(
        specs: [CustomRecipeSpec],
        homeDirectory: String
    ) -> [Recipe] {
        specs.map { spec in
            Recipe(
                id: spec.id,
                name: spec.name,
                category: spec.category,
                safety: spec.safety,
                disposition: spec.disposition,
                cleanability: spec.cleanability,
                defaultAgeDays: spec.defaultAgeDays,
                minimumSizeMB: spec.minimumSizeMB,
                processName: nil,
                resolvePaths: { _ in
                    let path = spec.pattern.hasPrefix("~/")
                        ? homeDirectory + String(spec.pattern.dropFirst(1))
                        : spec.pattern
                    return FileManager.default.fileExists(atPath: path) ? [path] : []
                }
            )
        }
    }
}
