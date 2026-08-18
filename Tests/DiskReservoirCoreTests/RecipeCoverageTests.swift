import Testing
import Foundation
@testable import DiskReservoirCore

private func recipe(_ id: String, _ paths: [String]) -> Recipe {
    Recipe(
        id: id, name: id, category: .common, safety: .safeWhileRunning,
        disposition: .deletePermanently, cleanability: .regenerable,
        defaultAgeDays: 7, minimumSizeMB: 0, processName: nil,
        resolvePaths: { _ in paths }
    )
}

@Test func coverageMatchesSelfAndDescendants() {
    let home = "/Users/alice"
    let covered = RecipeCoverage.coveredPatterns(
        recipes: [recipe("r", ["/Users/alice/Library/Caches"])],
        homeDirectory: home
    )
    #expect(RecipeCoverage.isCovered(
        path: "/Users/alice/Library/Caches",
        coveredPatterns: covered,
        homeDirectory: home
    ))
    #expect(RecipeCoverage.isCovered(
        path: "/Users/alice/Library/Caches/com.foo/sub",
        coveredPatterns: covered,
        homeDirectory: home
    ))
    #expect(!RecipeCoverage.isCovered(
        path: "/Users/alice/Library/Application Support/Other",
        coveredPatterns: covered,
        homeDirectory: home
    ))
    #expect(!RecipeCoverage.isCovered(
        path: "/Users/bob/Library/Caches/x",
        coveredPatterns: covered,
        homeDirectory: home
    ))
}

@Test func coverageDeduplicatesPatterns() {
    let covered = RecipeCoverage.coveredPatterns(
        recipes: [
            recipe("a", ["/Users/alice/Library/Caches"]),
            recipe("b", ["/Users/alice/Library/Caches"]),
        ],
        homeDirectory: "/Users/alice"
    )
    #expect(covered.count == 1)
}
