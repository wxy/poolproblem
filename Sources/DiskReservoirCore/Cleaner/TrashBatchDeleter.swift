import Foundation

/// 把同一次渐进式清理的多个子项集中放进废纸篓里的一个命名文件夹，
/// 避免静默清理把废纸篓拆成一堆难以辨认的小碎片。
///
/// 例如：`~/.Trash/PoolProblem Cleanup 2026-08-14 18.36.12/`。
public final class TrashBatchDeleter: FileDeleting, @unchecked Sendable {
    private let trashRoot: URL
    private let batchName: String
    private let lock = NSLock()
    private var groupURL: URL?

    /// 本应用创建的回收站批次的名称前缀。
    public static let batchNamePrefix = "PoolProblem Cleanup "

    public init(trashRoot: URL? = nil, batchName: String? = nil) {
        self.trashRoot = trashRoot
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".Trash", isDirectory: true)
        self.batchName = batchName ?? Self.defaultBatchName()
    }

    public func delete(url: URL, disposition: CleanDisposition) throws -> Int64 {
        try deleteReturningResult(url: url, disposition: disposition).freedBytes
    }

    public func deleteReturningResult(url: URL, disposition: CleanDisposition) throws -> FileDeletionResult {
        guard disposition == .trash else {
            return try FileManagerFileDeleter().deleteReturningResult(url: url, disposition: disposition)
        }

        lock.lock()
        defer { lock.unlock() }

        let group = try groupDirectory()
        let allocated = Self.allocatedBytes(of: url)
        var destination = group.appendingPathComponent(url.lastPathComponent)
        if FileManager.default.fileExists(atPath: destination.path) {
            destination = group.appendingPathComponent("\(url.lastPathComponent)-\(UUID().uuidString)")
        }
        try FileManager.default.moveItem(at: url, to: destination)
        return FileDeletionResult(freedBytes: allocated, resultingURL: destination)
    }

    /// 删除本应用创建的回收站批次目录（名称以 `batchNamePrefix` 开头）。
    /// 只清自己产生的批次，不碰用户手动放入的任何内容。
    /// 返回删除的批次数量。
    @discardableResult
    public static func emptyOwnBatches(trashRoot: URL? = nil) throws -> Int {
        let root = trashRoot
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".Trash", isDirectory: true)
        let fm = FileManager.default
        let children = try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        var removed = 0
        for child in children where child.lastPathComponent.hasPrefix(batchNamePrefix) {
            try fm.removeItem(at: child)
            removed += 1
        }
        return removed
    }

    /// 删除单个本应用批次目录（名称必须以批次前缀开头，防止误删用户内容）。
    public static func emptyBatch(named name: String, trashRoot: URL? = nil) throws {
        guard name.hasPrefix(batchNamePrefix) else { return }
        let root = trashRoot
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".Trash", isDirectory: true)
        let url = root.appendingPathComponent(name, isDirectory: true)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }

    private func groupDirectory() throws -> URL {
        if let groupURL { return groupURL }
        try FileManager.default.createDirectory(at: trashRoot, withIntermediateDirectories: true)
        var group = trashRoot.appendingPathComponent(batchName, isDirectory: true)
        if FileManager.default.fileExists(atPath: group.path) {
            group = trashRoot.appendingPathComponent(
                "\(batchName)-\(UUID().uuidString.prefix(4))",
                isDirectory: true
            )
        }
        try FileManager.default.createDirectory(at: group, withIntermediateDirectories: false)
        groupURL = group
        return group
    }

    private static func allocatedBytes(of url: URL) -> Int64 {
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
           isDirectory.boolValue {
            return POSIXDirectoryWalker.walk(
                url: url,
                itemID: "trash-batch",
                includeRecords: false
            )?.allocatedBytes ?? 0
        }
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .totalFileAllocatedSizeKey])
        return Int64(values?.totalFileAllocatedSize ?? values?.fileSize ?? 0)
    }

    private static func defaultBatchName() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return "PoolProblem Cleanup \(formatter.string(from: Date()))"
    }
}
