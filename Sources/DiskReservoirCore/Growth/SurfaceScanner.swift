import Foundation

/// 轻量"表面扫描"：只统计常用产废根目录的一级子目录大小，
/// 用于发现配方未覆盖的未知增长源。
public struct SurfaceScanner: Sendable {
    public init() {}

    public static func defaultRoots(homeDirectory: String) -> [String] {
        // 不做存在性过滤：scan 对不存在的根自然跳过（contentsOfDirectory 失败 → continue），
        // 保留完整候选列表便于测试与未来配置。
        [
            "\(homeDirectory)/Library/Caches",
            "\(homeDirectory)/Library/Logs",
            "\(homeDirectory)/Library/Developer",
            "\(homeDirectory)/Library/Application Support",
            "\(homeDirectory)/Library/Containers",
            "\(homeDirectory)/.cache",
        ]
    }

    /// 扫描每个根的一级子项（目录或文件），返回超过 `minimumSizeBytes` 的条目（按大小降序）。
    public func scan(roots: [String], minimumSizeBytes: Int64 = 50 << 20) -> [SurfaceDirectory] {
        var result: [SurfaceDirectory] = []
        for root in roots {
            let rootURL = URL(fileURLWithPath: root, isDirectory: true)
            guard let children = try? FileManager.default.contentsOfDirectory(
                at: rootURL,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ) else { continue }
            for child in children {
                guard let walk = POSIXDirectoryWalker.walk(
                    url: child,
                    itemID: child.path,
                    includeRecords: false
                ) else { continue }
                guard walk.sizeBytes >= minimumSizeBytes else { continue }
                result.append(SurfaceDirectory(
                    path: child.path,
                    sizeBytes: walk.sizeBytes,
                    fileCount: walk.fileCount,
                    lastModified: walk.newest
                ))
            }
        }
        return result.sorted { $0.sizeBytes > $1.sizeBytes }
    }

    /// 测量显式路径（增量用）：返回每个路径的 SurfaceDirectory，不设大小下限。
    public func measure(paths: [String], minimumSizeBytes: Int64 = 0) -> [SurfaceDirectory] {
        var result: [SurfaceDirectory] = []
        for path in paths {
            guard let walk = POSIXDirectoryWalker.walk(
                url: URL(fileURLWithPath: path),
                itemID: path,
                includeRecords: false
            ) else { continue }
            guard walk.sizeBytes >= minimumSizeBytes else { continue }
            result.append(SurfaceDirectory(
                path: path,
                sizeBytes: walk.sizeBytes,
                fileCount: walk.fileCount,
                lastModified: walk.newest
            ))
        }
        return result
    }
}
