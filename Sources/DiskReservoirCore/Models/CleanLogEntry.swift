import Foundation

public struct CleanLogEntry: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let timestamp: Date
    public let itemIDs: [String]
    public let freedBytes: Int64
    public let disposition: CleanDisposition

    public init(
        id: UUID,
        timestamp: Date,
        itemIDs: [String],
        freedBytes: Int64,
        disposition: CleanDisposition
    ) {
        self.id = id
        self.timestamp = timestamp
        self.itemIDs = itemIDs
        self.freedBytes = freedBytes
        self.disposition = disposition
    }
}
