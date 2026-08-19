import Foundation

/// 一次 FSEvents 写活动：项目根 + 命中的可再生产物名 + 时间。
public struct DevActivity: Sendable, Equatable {
    public let projectRoot: String
    public let artifact: String
    public let lastActivityAt: Date

    public init(projectRoot: String, artifact: String, lastActivityAt: Date) {
        self.projectRoot = projectRoot
        self.artifact = artifact
        self.lastActivityAt = lastActivityAt
    }
}

/// FSEvents 写活动识别：监听家目录事件，命中可再生产物名（node_modules/.git/dist/build 等）
/// 时记录"项目根 + 最近活动时间"。
/// 用途：① 发现无标记/新项目；② 清理保护（最近有写活动 = 正在使用，跳过）。
/// 线程安全（NSLock），可从 FSEvents 回调队列与主线程并发访问。
public final class DevActivityTracker: @unchecked Sendable {
    public static let artifactNames = [
        "node_modules", ".git", "dist", "build", ".build", ".dist",
        "package.json", "Package.swift", "Cargo.toml", "go.mod",
        "pyproject.toml", "pom.xml", "build.gradle",
    ]

    private let lock = NSLock()
    private var byRoot: [String: DevActivity] = [:]

    public init() {}

    @discardableResult
    public func record(eventPaths: [String], at date: Date = Date()) -> [DevActivity] {
        lock.lock()
        defer { lock.unlock() }
        var changed: [DevActivity] = []
        for path in eventPaths {
            guard let root = projectRoot(for: path) else { continue }
            let activity = DevActivity(
                projectRoot: root,
                artifact: lastArtifactComponent(path),
                lastActivityAt: date
            )
            if let old = byRoot[root] {
                if old.lastActivityAt < date {
                    byRoot[root] = activity
                }
            } else {
                byRoot[root] = activity
            }
            if let stored = byRoot[root] {
                changed.append(stored)
            }
        }
        return changed
    }

    public func activeProjects(since: TimeInterval) -> [DevActivity] {
        let cutoff = Date().addingTimeInterval(-since)
        lock.lock()
        defer { lock.unlock() }
        return byRoot.values
            .filter { $0.lastActivityAt >= cutoff }
            .sorted { $0.lastActivityAt > $1.lastActivityAt }
    }

    /// 事件路径链上最深的可再生产物名 → 项目根 = 其父目录。
    private func projectRoot(for path: String) -> String? {
        var current = URL(fileURLWithPath: path)
        while current.path != "/" {
            if Self.artifactNames.contains(current.lastPathComponent) {
                return current.deletingLastPathComponent().path
            }
            current = current.deletingLastPathComponent()
        }
        return nil
    }

    private func lastArtifactComponent(_ path: String) -> String {
        let components = path.split(separator: "/").map(String.init)
        return components.last { Self.artifactNames.contains($0) } ?? ""
    }
}
