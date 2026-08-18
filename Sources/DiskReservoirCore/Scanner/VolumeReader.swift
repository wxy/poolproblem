import Foundation
import Darwin

/// 卷容量读取器。
///
/// 口径说明（可靠性优先）：
/// - 首选 `URL.resourceValues`：`availableBytes` 使用
///   `.volumeAvailableCapacityForImportantUsage`——不含 APFS 可清除（purgeable）空间，
///   与水线守护"宁可低估、不可虚高"的语义一致；
/// - 兜底 `statvfs`：当 resourceValues 拿不到（网络卷、个别外置卷、系统异常）时，
///   用 POSIX 读取 `f_bavail`（普通用户可用块，不含保留块），APFS 上与
///   important-usage 口径基本一致（都排除 purgeable 物理块）；
/// - 两者都失败时返回 `0/0`，由调用方按"未知容量"处理，不要当作真实水位。
public enum VolumeReader {
    public static func read(fileURL: URL) -> VolumeInfo {
        let keys: Set<URLResourceKey> = [
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey,
        ]
        if let values = try? fileURL.resourceValues(forKeys: keys),
           let total = values.volumeTotalCapacity,
           let available = values.volumeAvailableCapacityForImportantUsage,
           total > 0 {
            return VolumeInfo(
                totalBytes: Int64(total),
                availableBytes: Int64(available),
                timestamp: Date()
            )
        }
        return statvfsRead(fileURL: fileURL)
            ?? VolumeInfo(totalBytes: 0, availableBytes: 0, timestamp: Date())
    }

    /// statvfs 兜底路径（供测试直接调用）。
    /// - `f_frsize`：基础块大小，字节换算必须用它（`f_bsize` 是 I/O 偏好块大小）；
    /// - `f_bavail`：普通用户实际可用块（不含文件系统保留块），而非 `f_bfree`。
    static func statvfsRead(fileURL: URL) -> VolumeInfo? {
        var stat = statvfs()
        guard statvfs(fileURL.path, &stat) == 0 else { return nil }
        let blockSize = UInt64(max(stat.f_frsize, 1))
        let total = UInt64(stat.f_blocks) * blockSize
        let available = UInt64(stat.f_bavail) * blockSize
        return VolumeInfo(
            totalBytes: Int64(total),
            availableBytes: Int64(available),
            timestamp: Date()
        )
    }
}
