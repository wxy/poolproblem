public struct Recipe: Sendable {
    public let id: String
    public let name: String
    public let category: Category
    /// 产品/生态分组（Xcode、Node.js、包管理器缓存、系统通用）。
    public let group: RecipeGroup
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
    /// “活跃窗口”小时数：最后修改 / FSEvents 写活动距今不足该值时视为项目仍在
    /// 使用，不清理。构建产物可随时重建，窗口宜短（如 6h）；node_modules 重建需
    /// 重新下载依赖，窗口宜长（如 72h）。
    public let minimumIdleHours: Double
    /// 仅按一级子目录清理：整项绝不作为整体删除（如水线/一键清理），
    /// 只允许逐子目录渐进清理。用于 `~/Library/Caches` 这类“一个目录塞几十个缓存”的场景。
    public let cleanByChildOnly: Bool
    public let resolvePaths: @Sendable (StoragePaths) -> [String]

    public init(
        id: String,
        name: String,
        category: Category,
        group: RecipeGroup = .system,
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
        minimumIdleHours: Double = 24,
        cleanByChildOnly: Bool = false,
        resolvePaths: @escaping @Sendable (StoragePaths) -> [String]
    ) {
        self.id = id
        self.name = name
        self.category = category
        self.group = group
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
        self.minimumIdleHours = minimumIdleHours
        self.cleanByChildOnly = cleanByChildOnly
        self.resolvePaths = resolvePaths
    }
}
