import Foundation

/// 项目目录配方族：一个配方、按项目展开成多个条目。
/// 路径集来自用户确认的开发根（`Config.devRoots`），识别到项目标记的子目录才会展开。
public enum ProjectRecipes {
    public static func make(devRoots: [String], homeDirectory: String) -> [Recipe] {
        let paths = Array(devRoots.flatMap { projectPaths(in: $0) }.reduce(into: Set<String>()) { $0.insert($1) })
        return [
            Recipe(
                id: "project-node-modules",
                name: "node_modules",
                category: .project,
                safety: .userConfirm,
                disposition: .trash,
                cleanability: .regenerable,
                defaultAgeDays: 30,
                minimumSizeMB: 100,
                processName: nil,
                usageProbe: .parentAndSelfNewestModified,
                aggregatesPaths: true,
                resolvePaths: { _ in
                    paths.filter { URL(fileURLWithPath: $0).lastPathComponent == "node_modules" }
                }
            ),
            Recipe(
                id: "project-build-output",
                name: "Project build output",
                category: .project,
                safety: .userConfirm,
                disposition: .trash,
                cleanability: .regenerable,
                defaultAgeDays: 30,
                minimumSizeMB: 100,
                processName: nil,
                aggregatesPaths: true,
                resolvePaths: { _ in
                    paths.filter { ["dist", "build", ".build", ".dist"]
                        .contains(URL(fileURLWithPath: $0).lastPathComponent) }
                }
            ),
        ]
    }

    /// 开发根（或其项目子目录）下的可再生产物路径，仅返回存在的路径。
    /// 开发根本身若被识别为项目（散落目录），也按项目展开。
    private static func projectPaths(in devRoot: String) -> [String] {
        let devRootURL = URL(fileURLWithPath: devRoot, isDirectory: true)
        var projects: [String] = []
        if DevDirectoryDetector.detect(path: devRoot) != nil {
            projects.append(devRoot)
        }
        if let children = try? FileManager.default.contentsOfDirectory(atPath: devRoot) {
            for child in children {
                let project = devRootURL.appendingPathComponent(child).path
                if DevDirectoryDetector.detect(path: project) != nil {
                    projects.append(project)
                }
            }
        }
        var result: [String] = []
        for project in projects {
            for dir in ["node_modules", "dist", "build", ".build", ".dist"] {
                let candidate = URL(fileURLWithPath: project).appendingPathComponent(dir).path
                if FileManager.default.fileExists(atPath: candidate) {
                    result.append(candidate)
                }
            }
        }
        return result
    }
}
