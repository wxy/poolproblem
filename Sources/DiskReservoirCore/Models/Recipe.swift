public struct Recipe: Sendable {
    public let id: String
    public let name: String
    public let category: Category
    public let safety: SafetyLevel
    public let disposition: CleanDisposition
    public let cleanability: Cleanability
    public let defaultAgeDays: Int
    public let minimumSizeMB: Double
    public let processName: String?
    public let cloneProne: Bool
    /// 渐进清理保护的一级子目录名：这些子项永远不会被自动渐进删除。
    public let protectedChildren: [String]
    /// “最后使用时间”的判定来源，默认取目录内最新 mtime。
    public let usageProbe: UsageProbe
    /// 聚合路径：resolvePaths 返回的多个路径合并为一个条目（用于项目目录聚类）。
    public let aggregatesPaths: Bool
    public let resolvePaths: @Sendable (StoragePaths) -> [String]

    public init(
        id: String,
        name: String,
        category: Category,
        safety: SafetyLevel,
        disposition: CleanDisposition,
        cleanability: Cleanability,
        defaultAgeDays: Int,
        minimumSizeMB: Double,
        processName: String?,
        cloneProne: Bool = false,
        protectedChildren: [String] = [],
        usageProbe: UsageProbe = .directoryNewestModified,
        aggregatesPaths: Bool = false,
        resolvePaths: @escaping @Sendable (StoragePaths) -> [String]
    ) {
        self.id = id
        self.name = name
        self.category = category
        self.safety = safety
        self.disposition = disposition
        self.cleanability = cleanability
        self.defaultAgeDays = defaultAgeDays
        self.minimumSizeMB = minimumSizeMB
        self.processName = processName
        self.cloneProne = cloneProne
        self.protectedChildren = protectedChildren
        self.usageProbe = usageProbe
        self.aggregatesPaths = aggregatesPaths
        self.resolvePaths = resolvePaths
    }
}
