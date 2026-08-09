import Foundation

public struct FileRecord: Sendable {
    public let itemID: String
    public let url: URL
    public let allocatedBytes: Int64
    public let deviceID: Int32
    public let inode: UInt64
    public let lastModified: Date

    public init(
        itemID: String,
        url: URL,
        allocatedBytes: Int64,
        deviceID: Int32,
        inode: UInt64,
        lastModified: Date
    ) {
        self.itemID = itemID
        self.url = url
        self.allocatedBytes = allocatedBytes
        self.deviceID = deviceID
        self.inode = inode
        self.lastModified = lastModified
    }
}
