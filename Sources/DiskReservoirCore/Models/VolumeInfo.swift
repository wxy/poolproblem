import Foundation

public struct VolumeInfo: Codable, Equatable, Sendable {
    public let totalBytes: Int64
    public let availableBytes: Int64
    public let timestamp: Date

    public init(totalBytes: Int64, availableBytes: Int64, timestamp: Date) {
        self.totalBytes = totalBytes
        self.availableBytes = availableBytes
        self.timestamp = timestamp
    }
}
