import Foundation

public enum CleanSource: String, Codable, Sendable {
    case manual
    case auto
}

public struct CleanLogEntry: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let timestamp: Date
    public let itemIDs: [String]
    public let itemNames: [String]
    public let originalPaths: [String]
    public let trashPaths: [String]
    public let batchID: UUID?
    public let freedBytes: Int64
    public let disposition: CleanDisposition
    public let source: CleanSource

    enum CodingKeys: String, CodingKey {
        case id, timestamp, itemIDs, itemNames, originalPaths, trashPaths, batchID, freedBytes, disposition, source
    }

    public init(
        id: UUID,
        timestamp: Date,
        itemIDs: [String],
        itemNames: [String] = [],
        originalPaths: [String] = [],
        trashPaths: [String] = [],
        batchID: UUID? = nil,
        freedBytes: Int64,
        disposition: CleanDisposition,
        source: CleanSource = .manual
    ) {
        self.id = id
        self.timestamp = timestamp
        self.itemIDs = itemIDs
        self.itemNames = itemNames
        self.originalPaths = originalPaths
        self.trashPaths = trashPaths
        self.batchID = batchID
        self.freedBytes = freedBytes
        self.disposition = disposition
        self.source = source
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        timestamp = try container.decode(Date.self, forKey: .timestamp)
        itemIDs = try container.decode([String].self, forKey: .itemIDs)
        itemNames = try container.decodeIfPresent([String].self, forKey: .itemNames) ?? []
        originalPaths = try container.decodeIfPresent([String].self, forKey: .originalPaths) ?? []
        trashPaths = try container.decodeIfPresent([String].self, forKey: .trashPaths) ?? []
        batchID = try container.decodeIfPresent(UUID.self, forKey: .batchID)
        freedBytes = try container.decode(Int64.self, forKey: .freedBytes)
        disposition = try container.decode(CleanDisposition.self, forKey: .disposition)
        source = try container.decodeIfPresent(CleanSource.self, forKey: .source) ?? .manual
    }
}
