import Foundation
@testable import DiskReservoirCore

enum Fixtures {
    static func makeTree(root: URL, files: [(relativePath: String, bytes: Int)]) throws {
        for file in files {
            let url = root.appendingPathComponent(file.relativePath)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = Data(repeating: 0xAB, count: file.bytes)
            try data.write(to: url)
        }
    }

    static func recipe(id: String, path: String, category: DiskReservoirCore.Category = .common) -> Recipe {
        Recipe(
            id: id, name: "Fixture \(id)", category: category,
            safety: .safeWhileRunning, disposition: .deletePermanently,
            defaultAgeDays: 30, minimumSizeMB: 0, processName: nil,
            resolvePaths: { _ in [path] }
        )
    }
}
