public struct Config: Codable, Equatable, Sendable {
    // 兼容性设计空间：若未来需要支持旧版本配置，请为新增字段实现 decodeIfPresent，
    // 并引入配置 schemaVersion（参考 DiskReservoirCore.schemaVersion）。
    public var waterlineGB: Double
    public var rules: [CleanRule]
    public var whitelistPaths: [String]
    public var cloneRatios: [String: Double]
    public var keptItemIDs: Set<String>
    /// 用户确认的开发目录（增长洞察中确认加入监控）。
    public var devRoots: [String]
    /// 用户忽略的开发目录（避免重复提示）。
    public var declinedDevRoots: [String]
    /// 渐进清理全局保护名单：这些一级子目录即使又大又旧也永远不会被自动删除。
    public var protectedCacheChildren: [String]
    /// 最小清理规模（MB）：低于此规模的清理目标不参与自动清理（收益不抵固定开销）。
    public var minimumCleanItemMB: Double
    /// 自动清理后是否清空本应用创建的回收站批次（默认关；只删本应用批次，不碰用户内容）。
    public var autoEmptyOwnTrashBatches: Bool

    public static let defaultProtectedCacheChildren = ["org.swift.swiftpm", "node-gyp"]

    public static let `default` = Config(
        waterlineGB: 30,
        rules: [],
        whitelistPaths: [],
        cloneRatios: [:],
        keptItemIDs: [],
        devRoots: [],
        declinedDevRoots: [],
        protectedCacheChildren: Config.defaultProtectedCacheChildren,
        minimumCleanItemMB: 500,
        autoEmptyOwnTrashBatches: false
    )

    public init(
        waterlineGB: Double,
        rules: [CleanRule],
        whitelistPaths: [String],
        cloneRatios: [String: Double] = [:],
        keptItemIDs: Set<String> = [],
        devRoots: [String] = [],
        declinedDevRoots: [String] = [],
        protectedCacheChildren: [String] = Config.defaultProtectedCacheChildren,
        minimumCleanItemMB: Double = 500,
        autoEmptyOwnTrashBatches: Bool = false
    ) {
        self.waterlineGB = waterlineGB
        self.rules = rules
        self.whitelistPaths = whitelistPaths
        self.cloneRatios = cloneRatios
        self.keptItemIDs = keptItemIDs
        self.devRoots = devRoots
        self.declinedDevRoots = declinedDevRoots
        self.protectedCacheChildren = protectedCacheChildren
        self.minimumCleanItemMB = minimumCleanItemMB
        self.autoEmptyOwnTrashBatches = autoEmptyOwnTrashBatches
    }

    private enum CodingKeys: String, CodingKey {
        case waterlineGB, rules, whitelistPaths, cloneRatios,
             keptItemIDs, devRoots, declinedDevRoots, protectedCacheChildren,
             minimumCleanItemMB, autoEmptyOwnTrashBatches
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        waterlineGB = try c.decode(Double.self, forKey: .waterlineGB)
        rules = try c.decodeIfPresent([CleanRule].self, forKey: .rules) ?? []
        whitelistPaths = try c.decodeIfPresent([String].self, forKey: .whitelistPaths) ?? []
        cloneRatios = try c.decodeIfPresent([String: Double].self, forKey: .cloneRatios) ?? [:]
        keptItemIDs = try c.decodeIfPresent(Set<String>.self, forKey: .keptItemIDs) ?? []
        devRoots = try c.decodeIfPresent([String].self, forKey: .devRoots) ?? []
        declinedDevRoots = try c.decodeIfPresent([String].self, forKey: .declinedDevRoots) ?? []
        protectedCacheChildren = try c.decodeIfPresent([String].self, forKey: .protectedCacheChildren)
            ?? Config.defaultProtectedCacheChildren
        minimumCleanItemMB = try c.decodeIfPresent(Double.self, forKey: .minimumCleanItemMB) ?? 500
        autoEmptyOwnTrashBatches = try c.decodeIfPresent(Bool.self, forKey: .autoEmptyOwnTrashBatches) ?? false
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(waterlineGB, forKey: .waterlineGB)
        try c.encode(rules, forKey: .rules)
        try c.encode(whitelistPaths, forKey: .whitelistPaths)
        try c.encode(cloneRatios, forKey: .cloneRatios)
        try c.encode(keptItemIDs, forKey: .keptItemIDs)
        try c.encode(devRoots, forKey: .devRoots)
        try c.encode(declinedDevRoots, forKey: .declinedDevRoots)
        try c.encode(protectedCacheChildren, forKey: .protectedCacheChildren)
        try c.encode(minimumCleanItemMB, forKey: .minimumCleanItemMB)
        try c.encode(autoEmptyOwnTrashBatches, forKey: .autoEmptyOwnTrashBatches)
    }
}
