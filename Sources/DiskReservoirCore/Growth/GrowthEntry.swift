import Foundation

/// 增长条目的来源类型。
public enum GrowthKind: String, Codable, Sendable {
    /// 已知配方项的增长
    case known
    /// 新出现的已知配方项（上次快照中不存在）
    case new
    /// 配方未覆盖的卷空间增长（total - available - 已知项之和）
    case unknownSpace
    /// 表面扫描发现的配方外一级目录增长
    case surface
}

/// 一次扫描间隔内观察到的增长。
public struct GrowthEntry: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let observedAt: Date
    public let elapsedDays: Double
    public let itemID: String?
    public let recipeID: String?
    /// 展示名：已知项用配方名；未知项用路径末段或固定名称。
    public let name: String
    /// 真实路径（未知空间桶为空字符串）。
    public let path: String
    /// 脱敏后的路径模式。
    public let pattern: String
    public let kind: GrowthKind
    public let deltaBytes: Int64
    public let rateBytesPerDay: Double

    public init(
        id: UUID = UUID(),
        observedAt: Date,
        elapsedDays: Double,
        itemID: String? = nil,
        recipeID: String? = nil,
        name: String,
        path: String,
        pattern: String,
        kind: GrowthKind,
        deltaBytes: Int64,
        rateBytesPerDay: Double
    ) {
        self.id = id
        self.observedAt = observedAt
        self.elapsedDays = elapsedDays
        self.itemID = itemID
        self.recipeID = recipeID
        self.name = name
        self.path = path
        self.pattern = pattern
        self.kind = kind
        self.deltaBytes = deltaBytes
        self.rateBytesPerDay = rateBytesPerDay
    }
}
