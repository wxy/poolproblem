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
