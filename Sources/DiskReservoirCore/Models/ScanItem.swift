import Foundation

public struct ScanItem: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let recipeID: String
    public let name: String
    public let path: String
    /// 聚合配方（项目目录聚类）覆盖的全部路径；普通配方为 `[path]`。
    public let paths: [String]
    public let category: Category
    public let safety: SafetyLevel
    public let disposition: CleanDisposition
    public let sizeBytes: Int64
    public let allocatedBytes: Int64
    public let reclaimableBytes: Int64
    public let fileCount: Int
    public let lastModified: Date?
    public let cleanability: Cleanability

    public init(
        id: String,
        recipeID: String,
        name: String,
        path: String,
        paths: [String]? = nil,
        category: Category,
        safety: SafetyLevel,
        disposition: CleanDisposition,
        sizeBytes: Int64,
        allocatedBytes: Int64,
        reclaimableBytes: Int64,
        fileCount: Int,
        lastModified: Date?,
        cleanability: Cleanability = .regenerable
    ) {
        self.id = id
        self.recipeID = recipeID
        self.name = name
        self.path = path
        self.paths = paths ?? [path]
        self.category = category
        self.safety = safety
        self.disposition = disposition
        self.sizeBytes = sizeBytes
        self.allocatedBytes = allocatedBytes
        self.reclaimableBytes = reclaimableBytes
        self.fileCount = fileCount
        self.lastModified = lastModified
        self.cleanability = cleanability
    }

    private enum CodingKeys: String, CodingKey {
        case id, recipeID, name, path, paths, category, safety, disposition,
             sizeBytes, allocatedBytes, reclaimableBytes, fileCount,
             lastModified, cleanability
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        recipeID = try c.decode(String.self, forKey: .recipeID)
        name = try c.decode(String.self, forKey: .name)
        path = try c.decode(String.self, forKey: .path)
        paths = try c.decodeIfPresent([String].self, forKey: .paths) ?? [path]
        category = try c.decode(Category.self, forKey: .category)
        safety = try c.decode(SafetyLevel.self, forKey: .safety)
        disposition = try c.decode(CleanDisposition.self, forKey: .disposition)
        sizeBytes = try c.decode(Int64.self, forKey: .sizeBytes)
        allocatedBytes = try c.decode(Int64.self, forKey: .allocatedBytes)
        reclaimableBytes = try c.decode(Int64.self, forKey: .reclaimableBytes)
        fileCount = try c.decode(Int.self, forKey: .fileCount)
        lastModified = try c.decodeIfPresent(Date.self, forKey: .lastModified)
        cleanability = try c.decodeIfPresent(Cleanability.self, forKey: .cleanability) ?? .regenerable
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(recipeID, forKey: .recipeID)
        try c.encode(name, forKey: .name)
        try c.encode(path, forKey: .path)
        try c.encode(paths, forKey: .paths)
        try c.encode(category, forKey: .category)
        try c.encode(safety, forKey: .safety)
        try c.encode(disposition, forKey: .disposition)
        try c.encode(sizeBytes, forKey: .sizeBytes)
        try c.encode(allocatedBytes, forKey: .allocatedBytes)
        try c.encode(reclaimableBytes, forKey: .reclaimableBytes)
        try c.encode(fileCount, forKey: .fileCount)
        try c.encodeIfPresent(lastModified, forKey: .lastModified)
        try c.encode(cleanability, forKey: .cleanability)
    }
}
