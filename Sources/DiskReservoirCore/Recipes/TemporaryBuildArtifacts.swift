import Foundation

/// High-confidence, app-generated build/test outputs stored directly under
/// `/private/tmp`. The allowlist is deliberately narrow: this recipe must never
/// turn the system temporary directory into a generic deletion target.
public enum TemporaryBuildArtifacts {
    public static let recipeID = "temporary-build-artifacts"
    public static let minimumIdleHours: Double = 24

    /// A manual cleanup is deferred while a process capable of producing these
    /// directories is running. This complements (rather than replaces) the
    /// per-directory newest-write check.
    public static let guardProcessNames = [
        "xcodebuild", "XCBBuildService", "swift", "swiftc", "clang",
    ]

    private static let allowedPrefixes = [
        "aipulse-", "ai-pulse-", "AIPulse",
        "poolproblem-", "PoolProblem",
    ]

    /// Returns only direct, physical child directories whose names identify
    /// build/test output produced by our workflows. Symlinks are rejected by
    /// `isDirectory` (`lstat`) so the recipe cannot escape `/private/tmp`.
    public static func discover(root: String = "/private/tmp") -> [String] {
        guard let names = POSIXDirectoryWalker.childNames(path: root) else { return [] }
        return names
            .filter(isAllowedName)
            .map { join(root, $0) }
            .filter { POSIXDirectoryWalker.isDirectory(path: $0) }
            .sorted()
    }

    /// Revalidates the path immediately before deletion. A directory is
    /// eligible only if it is still a recognized direct child and no file in
    /// its tree has been written during the protection window.
    public static func isEligibleForCleanup(
        path: String,
        root: String = "/private/tmp",
        now: Date = Date(),
        minimumIdleHours: Double = minimumIdleHours
    ) -> Bool {
        let normalizedRoot = URL(fileURLWithPath: root).standardizedFileURL.path
        let normalizedPath = URL(fileURLWithPath: path).standardizedFileURL.path
        let parent = URL(fileURLWithPath: normalizedPath).deletingLastPathComponent().path
        guard parent == normalizedRoot,
              isAllowedName(URL(fileURLWithPath: normalizedPath).lastPathComponent),
              POSIXDirectoryWalker.isDirectory(path: normalizedPath),
              let walk = POSIXDirectoryWalker.walk(
                url: URL(fileURLWithPath: normalizedPath, isDirectory: true),
                itemID: recipeID,
                includeRecords: false
              ) else {
            return false
        }
        // A newly-created build directory can contain copied files that retain
        // old mtimes. Treat the directory's own mtime as activity too, otherwise
        // fresh output could look stale immediately after it is generated.
        let directoryModified = POSIXDirectoryWalker.modificationDate(path: normalizedPath)
        let lastModified: Date
        switch (walk.newest, directoryModified) {
        case let (contents?, directory?): lastModified = max(contents, directory)
        case let (contents?, nil): lastModified = contents
        case let (nil, directory?): lastModified = directory
        case (nil, nil): lastModified = now
        }
        return now.timeIntervalSince(lastModified) >= minimumIdleHours * 3_600
    }

    public static func isAllowedName(_ name: String) -> Bool {
        allowedPrefixes.contains { name.hasPrefix($0) }
    }

    private static func join(_ parent: String, _ child: String) -> String {
        parent.hasSuffix("/") ? parent + child : parent + "/" + child
    }
}
