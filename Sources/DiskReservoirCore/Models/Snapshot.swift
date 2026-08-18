import Foundation

/// 快照来源：全量扫描 or 增量重扫合成。
public enum SnapshotSource: String, Codable, Sendable {
    case full
    case incremental
}

public struct Snapshot: Codable, Equatable, Sendable {
    public let volume: VolumeInfo
    public let items: [ScanItem]
    public let source: SnapshotSource

    public init(volume: VolumeInfo, items: [ScanItem], source: SnapshotSource = .full) {
        self.volume = volume
        self.items = items
        self.source = source
    }

    private enum CodingKeys: String, CodingKey {
        case volume, items, source
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        volume = try c.decode(VolumeInfo.self, forKey: .volume)
        items = try c.decode([ScanItem].self, forKey: .items)
        // 兼容旧快照文件（无 source 字段）
        source = try c.decodeIfPresent(SnapshotSource.self, forKey: .source) ?? .full
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(volume, forKey: .volume)
        try c.encode(items, forKey: .items)
        try c.encode(source, forKey: .source)
    }
}
