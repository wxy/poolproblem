import Foundation

/// 主动发现到的开发项目候选：无需增长触发，按"项目标记 + 可重建内容大小"判定。
public struct DevProjectCandidate: Sendable, Equatable {
    public let path: String
    public let marker: String
    public let regenerableBytes: Int64

    public init(path: String, marker: String, regenerableBytes: Int64) {
        self.path = path
        self.marker = marker
        self.regenerableBytes = regenerableBytes
    }
}

/// 开发目录主动发现：
/// 枚举家目录首级与常见开发根（Developer/Projects/Code/src/dev/work/repos/Sites）的首级子目录，
/// 用 `DevDirectoryDetector` 浅查标记，汇总其中 node_modules/dist/build/.build/.dist 的可重建大小，
/// 超过阈值的作为候选返回（按可重建大小降序）。
public enum DevDirectoryDiscovery {
    public static let regenerableDirNames = ["node_modules", "dist", "build", ".build", ".dist"]
    public static let conventionRoots = [
        "Developer", "Projects", "Code", "src", "dev", "work", "repos", "Sites", "develop",
    ]
    /// 家目录下不做二级枚举的系统目录（避免扫 Library 等巨大目录）。
    public static let systemRootExclusions = [
        "Library", "Applications", "Movies", "Music", "Pictures",
        "Public", "Desktop", ".Trash", ".localized",
    ]

    /// 不应纳入开发目录监测的路径：废纸篓、系统库/缓存（Library）、
    /// 家目录下的隐藏目录（.Trash/.cache/.npm 等）以及系统根目录。
    public static func isExcludedPath(_ path: String, homeDirectory: String) -> Bool {
        let home = URL(fileURLWithPath: homeDirectory, isDirectory: true)
        let excludedRoots = [
            home.appendingPathComponent(".Trash").path,
            home.appendingPathComponent("Library").path,
            "/System",
            "/private",
            "/Applications",
        ]
        if excludedRoots.contains(where: { $0 == path || path.hasPrefix($0 + "/") }) {
            return true
        }
        // 家目录下第一级为隐藏目录的路径整体排除
        let prefix = homeDirectory.hasSuffix("/") ? homeDirectory : homeDirectory + "/"
        if path.hasPrefix(prefix) {
            let rest = String(path.dropFirst(prefix.count))
            if let first = rest.split(separator: "/").first,
               first.hasPrefix(".") {
                return true
            }
        }
        return false
    }

    public static func discover(
        homeDirectory: String,
        minimumRegenerableBytes: Int64 = 200 << 20
    ) -> [DevProjectCandidate] {
        let home = URL(fileURLWithPath: homeDirectory, isDirectory: true)
        var seen = Set<String>()
        var candidates: [DevProjectCandidate] = []

        func examine(_ path: String) {
            guard seen.insert(path).inserted else { return }
            guard !isExcludedPath(path, homeDirectory: homeDirectory) else { return }
            guard let kind = DevDirectoryDetector.detect(path: path) else { return }
            let regenerable = regenerableBytes(in: path)
            guard regenerable >= minimumRegenerableBytes else { return }
            candidates.append(DevProjectCandidate(
                path: path,
                marker: kind.rawValue,
                regenerableBytes: regenerable
            ))
        }

        // 一级：家目录直接子目录；二级：非系统目录下再下一层（覆盖 ~/develop/*、~/Documents/* 等）
        if let homeChildren = try? FileManager.default.contentsOfDirectory(atPath: homeDirectory) {
            for child in homeChildren where !child.hasPrefix(".") {
                let childPath = home.appendingPathComponent(child).path
                examine(childPath)
                if !systemRootExclusions.contains(child),
                   let grandchildren = try? FileManager.default.contentsOfDirectory(atPath: childPath) {
                    for grandchild in grandchildren {
                        examine(home.appendingPathComponent(child).appendingPathComponent(grandchild).path)
                    }
                }
            }
        }
        // 惯例开发根的首级子目录（可能与上面重复，seen 去重）
        for root in conventionRoots {
            let rootPath = home.appendingPathComponent(root).path
            guard let children = try? FileManager.default.contentsOfDirectory(atPath: root) else { continue }
            for child in children {
                examine(rootPath + "/" + child)
            }
        }
        return candidates.sorted { $0.regenerableBytes > $1.regenerableBytes }
    }

    private static func regenerableBytes(in project: String) -> Int64 {
        var total: Int64 = 0
        for name in regenerableDirNames {
            let dir = URL(fileURLWithPath: project).appendingPathComponent(name).path
            guard let walk = POSIXDirectoryWalker.walk(
                url: URL(fileURLWithPath: dir),
                itemID: dir,
                includeRecords: false
            ) else { continue }
            total += walk.sizeBytes
        }
        return total
    }
}
