import Testing
import Foundation
@testable import DiskReservoirCore

private func item(
    _ id: String, safety: SafetyLevel, disposition: CleanDisposition,
    size: Int64 = 1_000_000_000, modified: Date? = Date()
) -> ScanItem {
    ScanItem(
        id: id, recipeID: "r", name: "N", path: "/tmp/\(id)",
        category: .xcode, safety: safety, disposition: disposition,
        sizeBytes: size, allocatedBytes: size, reclaimableBytes: size,
        fileCount: 1, lastModified: modified
    )
}

@Test func userConfirmAlwaysRequiresConfirmation() {
    let evaluator = RuleEvaluator(config: .default)
    let result = evaluator.evaluate(
        item: item("u", safety: .userConfirm, disposition: .trash),
        isProcessRunning: { _ in false }
    )
    guard case .notify = result.action else {
        Issue.record("expected notify")
        return
    }
}

@Test func projectItemSkipsWhenParentRecentlyActive() {
    let projectItem = ScanItem(
        id: "p1", recipeID: "project-node-modules", name: "NM", path: "/Users/alice/dev/A/node_modules",
        category: .project, safety: .userConfirm, disposition: .trash,
        sizeBytes: 1_000, allocatedBytes: 1_000, reclaimableBytes: 1_000,
        fileCount: 1, lastModified: Date().addingTimeInterval(-90 * 86_400)
    )
    let evaluator = RuleEvaluator(
        config: .default,
        recentlyActiveProjectRoots: ["/Users/alice/dev/A"]
    )
    let result = evaluator.evaluate(item: projectItem, isProcessRunning: { _ in false })
    guard case .skip = result.action else {
        Issue.record("expected skip for active project, got \(result.action)")
        return
    }
}

@Test func requiresQuitWithRunningProcessNotifies() {
    let evaluator = RuleEvaluator(config: .default)
    let result = evaluator.evaluate(
        item: item("q", safety: .requiresQuit, disposition: .deletePermanently),
        isProcessRunning: { _ in true }
    )
    guard case .notify = result.action else {
        Issue.record("expected notify")
        return
    }
}

@Test func recentlyModifiedIsSkipped() {
    let evaluator = RuleEvaluator(config: .default, now: { Date(timeIntervalSince1970: 1_000_000) })
    let result = evaluator.evaluate(
        item: item(
            "m", safety: .safeWhileRunning, disposition: .deletePermanently,
            modified: Date(timeIntervalSince1970: 999_000)
        ),
        isProcessRunning: { _ in false }
    )
    guard case .skip = result.action else {
        Issue.record("expected skip")
        return
    }
}

@Test func oldEnoughItemIsDeleted() {
    let evaluator = RuleEvaluator(config: .default, now: { Date(timeIntervalSince1970: 1_000_000) })
    let result = evaluator.evaluate(
        item: item(
            "o", safety: .safeWhileRunning, disposition: .deletePermanently,
            modified: Date(timeIntervalSince1970: 1_000_000 - 10 * 86_400)
        ),
        isProcessRunning: { _ in false }
    )
    #expect(result.action == .delete)
}

@Test func whitelistSkips() {
    var config = Config.default
    config.whitelistPaths = ["/tmp/keep"]
    let evaluator = RuleEvaluator(config: config)
    let item = ScanItem(
        id: "keep", recipeID: "r", name: "N", path: "/tmp/keep",
        category: .common, safety: .safeWhileRunning, disposition: .deletePermanently,
        sizeBytes: 1, allocatedBytes: 1, reclaimableBytes: 1,
        fileCount: 1, lastModified: Date(timeIntervalSince1970: 1)
    )
    let result = evaluator.evaluate(item: item, isProcessRunning: { _ in false })
    guard case .skip = result.action else {
        Issue.record("expected skip")
        return
    }
}

@Test func forceCleansSafeWhileRunningToTrash() {
    let evaluator = RuleEvaluator(config: .default, now: { Date(timeIntervalSince1970: 1_000_000) })
    let result = evaluator.evaluate(
        item: item(
            "f", safety: .safeWhileRunning, disposition: .deletePermanently,
            modified: Date(timeIntervalSince1970: 1_000_000 - 10 * 86_400)
        ),
        isProcessRunning: { _ in false },
        force: true
    )
    #expect(result.action == .trash)
}

@Test func forceSkipsKeptItem() {
    var config = Config.default
    config.keptItemIDs = ["keep"]
    let evaluator = RuleEvaluator(config: config)
    let kept = ScanItem(
        id: "keep", recipeID: "r", name: "N", path: "/tmp/keep",
        category: .common, safety: .safeWhileRunning, disposition: .deletePermanently,
        sizeBytes: 1, allocatedBytes: 1, reclaimableBytes: 1,
        fileCount: 1, lastModified: Date(timeIntervalSince1970: 1)
    )
    let result = evaluator.evaluate(item: kept, isProcessRunning: { _ in false }, force: true)
    guard case .skip = result.action else {
        Issue.record("expected skip")
        return
    }
}

@Test func forceCleansRequiresQuitWhenProcessNotRunning() {
    let evaluator = RuleEvaluator(config: .default)
    let result = evaluator.evaluate(
        item: item("q", safety: .requiresQuit, disposition: .trash),
        isProcessRunning: { _ in false },
        force: true
    )
    #expect(result.action == .trash)
}

@Test func forceNotifiesRequiresQuitWhenProcessRunning() {
    let evaluator = RuleEvaluator(config: .default)
    let result = evaluator.evaluate(
        item: item("q", safety: .requiresQuit, disposition: .trash),
        isProcessRunning: { _ in true },
        force: true
    )
    guard case .notify = result.action else {
        Issue.record("expected notify")
        return
    }
}

@Test func forceRespectsDispositionNone() {
    let evaluator = RuleEvaluator(config: .default)
    let result = evaluator.evaluate(
        item: item("n", safety: .safeWhileRunning, disposition: .none),
        isProcessRunning: { _ in false },
        force: true
    )
    guard case .skip = result.action else {
        Issue.record("expected skip")
        return
    }
}

@Test func displayOnlyItemIsNeverCleaned() {
    let evaluator = RuleEvaluator(config: .default, now: { Date(timeIntervalSince1970: 1_000_000) })
    let item = ScanItem(
        id: "d", recipeID: "r", name: "N", path: "/tmp/d",
        category: .common, safety: .safeWhileRunning, disposition: .deletePermanently,
        sizeBytes: 1, allocatedBytes: 1, reclaimableBytes: 1,
        fileCount: 1, lastModified: Date(timeIntervalSince1970: 1),
        cleanability: .displayOnly
    )
    let auto = evaluator.evaluate(item: item, isProcessRunning: { _ in false })
    guard case .skip = auto.action else {
        Issue.record("expected skip in auto mode")
        return
    }
    let forced = evaluator.evaluate(item: item, isProcessRunning: { _ in false }, force: true)
    guard case .skip = forced.action else {
        Issue.record("expected skip even when forced")
        return
    }
}

@Test func trashOnlyItemNotifiesInAutoMode() {
    let evaluator = RuleEvaluator(config: .default, now: { Date(timeIntervalSince1970: 1_000_000) })
    let item = ScanItem(
        id: "t", recipeID: "r", name: "N", path: "/tmp/t",
        category: .common, safety: .safeWhileRunning, disposition: .trash,
        sizeBytes: 1, allocatedBytes: 1, reclaimableBytes: 1,
        fileCount: 1, lastModified: Date(timeIntervalSince1970: 1),
        cleanability: .trashOnly
    )
    let result = evaluator.evaluate(item: item, isProcessRunning: { _ in false })
    guard case .notify = result.action else {
        Issue.record("expected notify in auto mode")
        return
    }
}

@Test func trashOnlyItemGoesToTrashWhenForced() {
    let evaluator = RuleEvaluator(config: .default, now: { Date(timeIntervalSince1970: 1_000_000) })
    let item = ScanItem(
        id: "t2", recipeID: "r", name: "N", path: "/tmp/t2",
        category: .common, safety: .safeWhileRunning, disposition: .deletePermanently,
        sizeBytes: 1, allocatedBytes: 1, reclaimableBytes: 1,
        fileCount: 1, lastModified: Date(timeIntervalSince1970: 1),
        cleanability: .trashOnly
    )
    let result = evaluator.evaluate(item: item, isProcessRunning: { _ in false }, force: true)
    #expect(result.action == .trash)
}
