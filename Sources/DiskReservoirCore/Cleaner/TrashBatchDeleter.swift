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
