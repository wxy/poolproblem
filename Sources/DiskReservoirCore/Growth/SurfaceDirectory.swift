import Foundation

/// 表面扫描结果：某个根目录的一级子目录（目录或文件）的大小快照。
public struct SurfaceDirectory: Codable, Equatable, Identifiable, Sendable {
    public let path: String
    public let sizeBytes: Int64
    public let fileCount: Int
    public let lastModified: Date?

    public var id: String { path }

    public init(path: String, sizeBytes: Int64, fileCount: Int, lastModified: Date?) {
        self.path = path
        self.sizeBytes = sizeBytes
        self.fileCount = fileCount
        self.lastModified = lastModified
    }
}
