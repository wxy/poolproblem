import Foundation

/// 开发目录识别结果类型。
public enum DevProjectKind: String, Sendable, Equatable {
    case project
}

/// 开发目录启发式：浅查（仅首级）项目标记，不做全量遍历。
/// 用于增长洞察中发现未覆盖增长后，判断是否值得提示用户"加入开发目录监控"。
public enum DevDirectoryDetector {
    /// 文件型标记（存在任一即命中）
    public static let fileMarkers = [
        "Package.swift", "package.json", "Cargo.toml", "go.mod",
        "pyproject.toml", "pom.xml", "build.gradle", "composer.json",
    ]
    /// 目录型标记
    public static let directoryMarkers = [".git", "node_modules"]

    public static func detect(path: String) -> DevProjectKind? {
        guard POSIXDirectoryWalker.isDirectory(path: path) else { return nil }
        for marker in fileMarkers where POSIXDirectoryWalker.itemExists(path: join(path, marker)) {
            return .project
        }
        for marker in directoryMarkers where POSIXDirectoryWalker.itemExists(path: join(path, marker)) {
            return .project
        }
        // 允许开发目录本身直接含可再生产物（散落项目）
        let children = POSIXDirectoryWalker.childNames(path: path) ?? []
        for child in children where child == "dist" || child == "build"
            || child == ".build" || child == ".dist" {
            return .project
        }
        return nil
    }

    private static func join(_ parent: String, _ child: String) -> String {
        parent.hasSuffix("/") ? parent + child : parent + "/" + child
    }
}
