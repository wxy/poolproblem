public struct Config: Codable, Equatable, Sendable {
    // 兼容性设计空间：若未来需要支持旧版本配置，请为新增字段实现 decodeIfPresent，
    // 并引入配置 schemaVersion（参考 DiskReservoirCore.schemaVersion）。
    public var waterlineGB: Double
    public var rules: [CleanRule]
    public var whitelistPaths: [String]
    public var enabledRecipes: Set<String>
    public var cloneRatios: [String: Double]
    public var keptItemIDs: Set<String>
    /// 用户确认的开发目录（增长洞察中确认加入监控）。
    public var devRoots: [String]
    /// 用户忽略的开发目录（避免重复提示）。
    public var declinedDevRoots: [String]
    /// 渐进清理全局保护名单：这些一级子目录即使又大又旧也永远不会被自动删除。
    public var protectedCacheChildren: [String]

    public static let defaultProtectedCacheChildren = ["org.swift.swiftpm", "node-gyp"]

    public static let `default` = Config(
        waterlineGB: 30,
        rules: [],
        whitelistPaths: [],
        enabledRecipes: [],
        cloneRatios: [:],
        keptItemIDs: [],
        devRoots: [],
        declinedDevRoots: [],
        protectedCacheChildren: Config.defaultProtectedCacheChildren
    )

    public init(
        waterlineGB: Double,
        rules: [CleanRule],
        whitelistPaths: [String],
        enabledRecipes: Set<String>,
        cloneRatios: [String: Double] = [:],
        keptItemIDs: Set<String> = [],
        devRoots: [String] = [],
        declinedDevRoots: [String] = [],
        protectedCacheChildren: [String] = Config.defaultProtectedCacheChildren
    ) {
        self.waterlineGB = waterlineGB
        self.rules = rules
        self.whitelistPaths = whitelistPaths
        self.enabledRecipes = enabledRecipes
        self.cloneRatios = cloneRatios
        self.keptItemIDs = keptItemIDs
        self.devRoots = devRoots
        self.declinedDevRoots = declinedDevRoots
        self.protectedCacheChildren = protectedCacheChildren
    }

    private enum CodingKeys: String, CodingKey {
        case waterlineGB, rules, whitelistPaths, enabledRecipes, cloneRatios,
             keptItemIDs, devRoots, declinedDevRoots, protectedCacheChildren
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        waterlineGB = try c.decode(Double.self, forKey: .waterlineGB)
        rules = try c.decodeIfPresent([CleanRule].self, forKey: .rules) ?? []
        whitelistPaths = try c.decodeIfPresent([String].self, forKey: .whitelistPaths) ?? []
        enabledRecipes = try c.decodeIfPresent(Set<String>.self, forKey: .enabledRecipes) ?? []
        cloneRatios = try c.decodeIfPresent([String: Double].self, forKey: .cloneRatios) ?? [:]
        keptItemIDs = try c.decodeIfPresent(Set<String>.self, forKey: .keptItemIDs) ?? []
        devRoots = try c.decodeIfPresent([String].self, forKey: .devRoots) ?? []
        declinedDevRoots = try c.decodeIfPresent([String].self, forKey: .declinedDevRoots) ?? []
        protectedCacheChildren = try c.decodeIfPresent([String].self, forKey: .protectedCacheChildren)
            ?? Config.defaultProtectedCacheChildren
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(waterlineGB, forKey: .waterlineGB)
        try c.encode(rules, forKey: .rules)
        try c.encode(whitelistPaths, forKey: .whitelistPaths)
        try c.encode(enabledRecipes, forKey: .enabledRecipes)
        try c.encode(cloneRatios, forKey: .cloneRatios)
        try c.encode(keptItemIDs, forKey: .keptItemIDs)
        try c.encode(devRoots, forKey: .devRoots)
        try c.encode(declinedDevRoots, forKey: .declinedDevRoots)
        try c.encode(protectedCacheChildren, forKey: .protectedCacheChildren)
    }
}
