import Foundation
import Darwin

public struct ChildGrowthObservation: Equatable, Sendable {
    public let deltaBytes: Int64
    public let elapsedDays: Double
    public let observedAt: Date
}

public struct DirectoryIdentity: Equatable, Sendable {
    public let deviceID: UInt64
    public let inode: UInt64
}

public struct ChildDirectoryInfo: Equatable, Identifiable, Sendable {
    public let name: String
    public let path: String
    public let identity: DirectoryIdentity
    public let bytes: Int64
    public let growth: ChildGrowthObservation?
    public let isProtected: Bool
    public let lastModified: Date?

    public var id: String { path }
}

/// DerivedData 的共享目录影响多个项目；它们仍需用户逐项确认后才能清理。
public enum DerivedDataChildPolicy {
    public static let minimumIdleSeconds: TimeInterval = 60
    private static let sharedCacheNames: Set<String> = [
        "CompilationCache.noindex", "ModuleCache.noindex",
        "SDKExplicitPrecompiledModules", "SDKStatCaches.noindex",
        "SymbolCache.noindex", "SourcePackages",
    ]

    public static func isSharedCache(name: String) -> Bool {
        sharedCacheNames.contains(name)
    }
}

/// 当前文件树与历史增长记录的交集。历史增量只作为一次观测展示，不推算每天速率。
public struct ChildDirectoryExplorer: Sendable {
    public init() {}

    public func list(
        parentPath: String,
        growthEntries: [GrowthEntry],
        protectedChildNames: Set<String>,
        minimumBytes: Int64 = 10_000_000,
        now: Date = Date()
    ) -> [ChildDirectoryInfo] {
        let parent = URL(fileURLWithPath: parentPath, isDirectory: true)
        guard !ChildDirectoryAccess.isSymbolicLink(parentPath),
              let children = try? FileManager.default.contentsOfDirectory(
                at: parent,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]
              ) else { return [] }
        let cutoff = now.addingTimeInterval(-7 * 86_400)
        let canonicalParent = parent.resolvingSymlinksInPath().path
        let latestGrowth = Dictionary(grouping: growthEntries.filter {
            URL(fileURLWithPath: $0.path).resolvingSymlinksInPath().path.hasPrefix(canonicalParent + "/")
                && $0.observedAt >= cutoff && $0.observedAt <= now
        }, by: { URL(fileURLWithPath: $0.path).resolvingSymlinksInPath().path })
            .compactMapValues { $0.max(by: { $0.observedAt < $1.observedAt }) }

        return children.compactMap { child -> ChildDirectoryInfo? in
            guard !ChildDirectoryAccess.isSymbolicLink(child.path),
                  ((try? child.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory) == true,
                  let identity = ChildDirectoryAccess.identity(path: child.path),
                  let measured = POSIXDirectoryWalker.walk(
                    url: child, itemID: "child-directory", includeRecords: false,
                    includeDirectoryDates: true
                  ), measured.allocatedBytes >= minimumBytes else { return nil }
            let historical = latestGrowth[child.resolvingSymlinksInPath().path]
            let growth: ChildGrowthObservation?
            if let historical,
               historical.elapsedDays > 0,
               historical.deltaBytes > 0,
               historical.deltaBytes <= measured.allocatedBytes {
                growth = ChildGrowthObservation(
                    deltaBytes: historical.deltaBytes,
                    elapsedDays: historical.elapsedDays,
                    observedAt: historical.observedAt
                )
            } else {
                growth = nil
            }
            return ChildDirectoryInfo(
                name: child.lastPathComponent,
                path: child.path,
                identity: identity,
                bytes: measured.allocatedBytes,
                growth: growth,
                isProtected: protectedChildNames.contains(child.lastPathComponent),
                lastModified: max(
                    measured.newest ?? .distantPast,
                    POSIXDirectoryWalker.modificationDate(path: child.path) ?? .distantPast
                )
            )
        }.sorted { lhs, rhs in
            if lhs.isProtected != rhs.isProtected { return !lhs.isProtected }
            let left = Double(lhs.bytes) + Double(lhs.growth?.deltaBytes ?? 0)
            let right = Double(rhs.bytes) + Double(rhs.growth?.deltaBytes ?? 0)
            if left != right { return left > right }
            return lhs.path < rhs.path
        }
    }
}

/// 在真正移动到废纸篓前再次校验目标，避免过期 UI 路径或符号链接越界。
public enum ChildDirectoryAccess {
    public static func canClean(
        childPath: String,
        parentPath: String,
        authorizedParents: Set<String>,
        protectedNames: Set<String>,
        expectedIdentity: DirectoryIdentity? = nil,
        minimumIdleSeconds: TimeInterval = 0,
        now: Date = Date()
    ) -> Bool {
        let parent = URL(fileURLWithPath: parentPath, isDirectory: true)
        let child = URL(fileURLWithPath: childPath, isDirectory: true)
        guard authorizedParents.contains(parent.path),
              parent.path == parentPath,
              child.path == childPath,
              child.deletingLastPathComponent().path == parent.path,
              !protectedNames.contains(child.lastPathComponent),
              !isSymbolicLink(parent.path),
              !isSymbolicLink(child.path),
              let currentIdentity = identity(path: child.path),
              expectedIdentity.map({ $0 == currentIdentity }) ?? true else { return false }
        guard minimumIdleSeconds > 0 else { return true }
        guard let walk = POSIXDirectoryWalker.walk(
            url: child, itemID: "child-idle-check", includeRecords: false,
            includeDirectoryDates: true
        ), walk.isComplete,
           let rootModified = POSIXDirectoryWalker.modificationDate(path: child.path) else {
            return false
        }
        let newest = max(walk.newest ?? .distantPast, rootModified)
        return newest <= now.addingTimeInterval(-minimumIdleSeconds)
    }

    static func isSymbolicLink(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFLNK
    }

    public static func identity(path: String) -> DirectoryIdentity? {
        var info = stat()
        guard lstat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR else {
            return nil
        }
        return DirectoryIdentity(deviceID: UInt64(truncatingIfNeeded: info.st_dev), inode: UInt64(info.st_ino))
    }
}
