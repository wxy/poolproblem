public struct Config: Codable, Equatable, Sendable {
    // 兼容性设计空间：若未来需要支持旧版本配置，请为新增字段实现 decodeIfPresent，
    // 并引入配置 schemaVersion（参考 DiskReservoirCore.schemaVersion）。
    public var waterlineGB: Double
    public var rules: [CleanRule]
    public var whitelistPaths: [String]
    public var enabledRecipes: Set<String>
    public var cloneRatios: [String: Double]
    public var keptItemIDs: Set<String>

    public static let `default` = Config(
        waterlineGB: 30,
        rules: [],
        whitelistPaths: [],
        enabledRecipes: [],
        cloneRatios: [:],
        keptItemIDs: []
    )

    public init(
        waterlineGB: Double,
        rules: [CleanRule],
        whitelistPaths: [String],
        enabledRecipes: Set<String>,
        cloneRatios: [String: Double] = [:],
        keptItemIDs: Set<String> = []
    ) {
        self.waterlineGB = waterlineGB
        self.rules = rules
        self.whitelistPaths = whitelistPaths
        self.enabledRecipes = enabledRecipes
        self.cloneRatios = cloneRatios
        self.keptItemIDs = keptItemIDs
    }
}
