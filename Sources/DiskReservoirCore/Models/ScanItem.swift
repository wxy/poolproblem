import Foundation

public struct ScanItem: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let recipeID: String
    public let name: String
    public let path: String
    public let category: Category
    public let safety: SafetyLevel
    public let disposition: CleanDisposition
    public let sizeBytes: Int64
    public let allocatedBytes: Int64
    public let reclaimableBytes: Int64
    public let fileCount: Int
    public let lastModified: Date?

    public init(
        id: String,
        recipeID: String,
        name: String,
        path: String,
        category: Category,
        safety: SafetyLevel,
        disposition: CleanDisposition,
        sizeBytes: Int64,
        allocatedBytes: Int64,
        reclaimableBytes: Int64,
        fileCount: Int,
        lastModified: Date?
    ) {
        self.id = id
        self.recipeID = recipeID
        self.name = name
        self.path = path
        self.category = category
        self.safety = safety
        self.disposition = disposition
        self.sizeBytes = sizeBytes
        self.allocatedBytes = allocatedBytes
        self.reclaimableBytes = reclaimableBytes
        self.fileCount = fileCount
        self.lastModified = lastModified
    }
}
