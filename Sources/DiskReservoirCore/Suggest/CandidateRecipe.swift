import Foundation

/// 用户对候选配方的决定。
public enum CandidateStatus: String, Codable, Sendable {
    case pending
    case accepted
    case dismissed
}

/// 一个候选配方：由增长台账中的同类路径模式聚合而来。
public struct CandidateRecipe: Codable, Equatable, Identifiable, Sendable {
    /// 以脱敏模式作为稳定标识。
    public let id: String
    public let pattern: String
    public var status: CandidateStatus
    public let totalGrowthBytes: Int64
    public let peakRateBytesPerDay: Double
    public let evidenceCount: Int
    public let firstSeenAt: Date
    public let lastSeenAt: Date
    public let suggestedSafety: SafetyLevel
    public let suggestedCleanability: Cleanability
    public let suggestedCategory: Category
    /// 采纳后配方的处置方式：可再生缓存类进回收站，用户数据类仅监控。
    public let suggestedDisposition: CleanDisposition
    /// 一个真实路径样本，供用户查看（不参与展示聚合）。
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
        suggestedSafety: SafetyLevel,
        suggestedCleanability: Cleanability,
        suggestedCategory: Category,
        suggestedDisposition: CleanDisposition = .trash,
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
        self.suggestedSafety = suggestedSafety
        self.suggestedCleanability = suggestedCleanability
        self.suggestedCategory = suggestedCategory
        self.suggestedDisposition = suggestedDisposition
        self.samplePath = samplePath
    }

    private enum CodingKeys: String, CodingKey {
        case id, pattern, status, totalGrowthBytes, peakRateBytesPerDay, evidenceCount,
             firstSeenAt, lastSeenAt, suggestedSafety, suggestedCleanability,
             suggestedCategory, suggestedDisposition, samplePath
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
        suggestedSafety = try c.decode(SafetyLevel.self, forKey: .suggestedSafety)
        suggestedCleanability = try c.decode(Cleanability.self, forKey: .suggestedCleanability)
        suggestedCategory = try c.decode(Category.self, forKey: .suggestedCategory)
        suggestedDisposition = try c.decodeIfPresent(CleanDisposition.self, forKey: .suggestedDisposition) ?? .trash
        samplePath = try c.decode(String.self, forKey: .samplePath)
    }
}
