import Foundation
import Darwin

/// 基于 POSIX `opendir`/`readdir`/`lstat` 的目录枚举。
///
/// FileManager 在部分 macOS 版本上对 `~/.Trash` 等受 TCC 保护的目录存在已知问题：
/// 即使应用已经获得完全磁盘访问权限，枚举结果也会静默为空列表。
/// 底层 POSIX 调用会遵循同样的 TCC 授权，但可以绕过该枚举 bug，
/// 因此被用作 Scanner 的兜底实现，以及完全磁盘访问的判定依据。
public enum POSIXDirectoryWalker {
    public struct WalkResult: Sendable {
        public var sizeBytes: Int64 = 0
        public var allocatedBytes: Int64 = 0
        public var fileCount: Int = 0
        public var newest: Date?
        public var files: [FileRecord] = []

        public init() {}
    }

    /// 仅统计一级目录条目数。目录无法打开（例如缺少完全磁盘访问）时返回 `nil`。
    public static func firstLevelCount(path: String) -> Int? {
        guard let dir = opendir(path) else { return nil }
        defer { closedir(dir) }
        var count = 0
        while let entry = readdir(dir) {
            let name = entryName(entry)
            if name != "." && name != ".." { count += 1 }
        }
        return count
    }

    /// 递归统计目录（大小、占用块、文件数、最新修改时间、文件记录）。
    /// 根目录无法打开时返回 `nil`；深层子目录打开失败时跳过该子树。
    /// `includeRecords` 为 false 时跳过逐文件记录，只做汇总——
    /// 用于废纸篓这类“只展示大小、不参与清理”的目录，速度提升明显。
    public static func walk(url: URL, itemID: String, includeRecords: Bool = true) -> WalkResult? {
        guard let dir = opendir(url.path) else { return nil }
        defer { closedir(dir) }
        var result = WalkResult()
        walkLevel(dir: dir, baseURL: url, itemID: itemID, includeRecords: includeRecords, result: &result)
        return result
    }

    private static func walkLevel(
        dir: UnsafeMutablePointer<DIR>,
        baseURL: URL,
        itemID: String,
        includeRecords: Bool,
        result: inout WalkResult
    ) {
        while let entry = readdir(dir) {
            let name = entryName(entry)
            if name == "." || name == ".." { continue }
            let childURL = baseURL.appendingPathComponent(name)
            var st = stat()
            guard lstat(childURL.path, &st) == 0 else { continue }
            switch st.st_mode & S_IFMT {
            case S_IFLNK:
                // 与 FileManager 版本一致：符号链接不计入
                continue
            case S_IFDIR:
                if let sub = opendir(childURL.path) {
                    walkLevel(
                        dir: sub,
                        baseURL: childURL,
                        itemID: itemID,
                        includeRecords: includeRecords,
                        result: &result
                    )
                    closedir(sub)
                }
            case S_IFREG:
                let allocated = Int64(st.st_blocks) * 512
                let modified = Date(timeIntervalSince1970: TimeInterval(st.st_mtimespec.tv_sec))
                result.sizeBytes += Int64(st.st_size)
                result.allocatedBytes += allocated
                result.fileCount += 1
                if includeRecords {
                    result.files.append(FileRecord(
                        itemID: itemID,
                        url: childURL,
                        allocatedBytes: allocated,
                        deviceID: st.st_dev,
                        inode: st.st_ino,
                        lastModified: modified
                    ))
                }
                if modified > (result.newest ?? .distantPast) {
                    result.newest = modified
                }
            default:
                continue
            }
        }
    }

    private static func entryName(_ entry: UnsafeMutablePointer<dirent>) -> String {
        withUnsafeBytes(of: entry.pointee.d_name) { rawBuffer in
            String(cString: rawBuffer.bindMemory(to: CChar.self).baseAddress!)
        }
    }
}
