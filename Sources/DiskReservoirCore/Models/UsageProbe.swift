import Foundation

/// 配方“最后使用时间”的判定来源。
public enum UsageProbe: Equatable, Sendable {
    /// 目录内最新文件的 mtime 即最后使用时间（默认，适用于写型缓存）。
    case directoryNewestModified
    /// 通过设备 `device.plist` 的 `lastBootedAt` 反查运行时镜像/缓存的最后使用时间；
    /// 扫描时会把父路径的一级子目录展开为独立条目。
    case simulatorRuntimeLastBooted
}
