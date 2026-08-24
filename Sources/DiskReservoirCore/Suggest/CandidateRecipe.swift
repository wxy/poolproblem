import Foundation

/// 用户对候选配方的决定。
public enum CandidateStatus: String, Codable, Sendable {
    case pending
    case accepted
    case dismissed
}

/// 一个“加入现有配方作用域”的候选目录：由增长台账中符合现有配方类型
/// （如项目目录配方族）的未覆盖增长聚合而来。采纳后把目录加入对应配方的
/// 管理范围（项目目录 → Config.devRoots），而不是创建新的配方。
public struct CandidateRecipe: Codable, Equatable, Identifiable, Sendable {
    /// 以脱敏路径模式作为稳定标识。
    public let id: String
    public let pattern: String
    public var status: CandidateStatus
    public let totalGrowthBytes: Int64
    public let peakRateBytesPerDay: Double
    public let evidenceCount: Int
    public let firstSeenAt: Date
    public let lastSeenAt: Date
    /// 目标现有配方的稳定标识（如项目目录配方族 "project-recipes"）。
    public let recipeID: String
    /// 目标现有配方的展示名（Core 提供英文回退，UI 可按 recipeID 本地化）。
    public let recipeName: String
    public let suggestedSafety: SafetyLevel
    public let suggestedCleanability: Cleanability
    public let suggestedCategory: Category
    /// 采纳后纳入配方的处置方式（来自目标配方的既有规则）。
    public let suggestedDisposition: CleanDisposition
    /// 候选来源：增长 / 主动发现 / 近期写活动。
    public let source: RecipeCandidateSource
    /// 归并到父目录建议时列出的子项目名（单个候选为空）。
    public let childNames: [String]
    /// 采纳后加入配方作用域的目录（真实路径；项目目录候选即项目根）。
    public let samplePath: String

    public init(
        id: String,
        pattern: String,
        status: CandidateStatus = .pending,
        totalGrowthBytes: Int64,
        peakRateBytesPerDay: Double,
        evidenceCount: Int,
        firstSeenAt: Date,
        lastSeenAt: Date,
        recipeID: String,
        recipeName: String,
        suggestedSafety: SafetyLevel,
        suggestedCleanability: Cleanability,
        suggestedCategory: Category,
        suggestedDisposition: CleanDisposition = .trash,
        source: RecipeCandidateSource = .growth,
        childNames: [String] = [],
        samplePath: String
    ) {
        self.id = id
        self.pattern = pattern
        self.status = status
        self.totalGrowthBytes = totalGrowthBytes
        self.peakRateBytesPerDay = peakRateBytesPerDay
        self.evidenceCount = evidenceCount
        self.firstSeenAt = firstSeenAt
        self.lastSeenAt = lastSeenAt
        self.recipeID = recipeID
        self.recipeName = recipeName
        self.suggestedSafety = suggestedSafety
        self.suggestedCleanability = suggestedCleanability
        self.suggestedCategory = suggestedCategory
        self.suggestedDisposition = suggestedDisposition
        self.source = source
        self.childNames = childNames
        self.samplePath = samplePath
    }

    private enum CodingKeys: String, CodingKey {
        case id, pattern, status, totalGrowthBytes, peakRateBytesPerDay, evidenceCount,
             firstSeenAt, lastSeenAt, recipeID, recipeName, suggestedSafety, suggestedCleanability,
             suggestedCategory, suggestedDisposition, source, childNames, samplePath
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        pattern = try c.decode(String.self, forKey: .pattern)
        status = try c.decode(CandidateStatus.self, forKey: .status)
        totalGrowthBytes = try c.decode(Int64.self, forKey: .totalGrowthBytes)
        peakRateBytesPerDay = try c.decode(Double.self, forKey: .peakRateBytesPerDay)
        evidenceCount = try c.decode(Int.self, forKey: .evidenceCount)
        firstSeenAt = try c.decode(Date.self, forKey: .firstSeenAt)
        lastSeenAt = try c.decode(Date.self, forKey: .lastSeenAt)
        recipeID = try c.decodeIfPresent(String.self, forKey: .recipeID) ?? "project-recipes"
        recipeName = try c.decodeIfPresent(String.self, forKey: .recipeName)
            ?? "node_modules / Project build output"
        suggestedSafety = try c.decode(SafetyLevel.self, forKey: .suggestedSafety)
        suggestedCleanability = try c.decode(Cleanability.self, forKey: .suggestedCleanability)
        suggestedCategory = try c.decode(Category.self, forKey: .suggestedCategory)
        suggestedDisposition = try c.decodeIfPresent(CleanDisposition.self, forKey: .suggestedDisposition) ?? .trash
        source = try c.decodeIfPresent(RecipeCandidateSource.self, forKey: .source) ?? .growth
        childNames = try c.decodeIfPresent([String].self, forKey: .childNames) ?? []
        samplePath = try c.decode(String.self, forKey: .samplePath)
    }
}
