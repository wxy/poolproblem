import Foundation

public struct Snapshot: Codable, Equatable, Sendable {
    public let volume: VolumeInfo
    public let items: [ScanItem]

    public init(volume: VolumeInfo, items: [ScanItem]) {
        self.volume = volume
        self.items = items
    }
}
