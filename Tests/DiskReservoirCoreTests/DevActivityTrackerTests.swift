import Testing
import Foundation
@testable import DiskReservoirCore

@Test func activityTrackerRecordsProjectRoots() {
    let tracker = DevActivityTracker()
    let now = Date()
    let activities = tracker.record(eventPaths: [
        "/Users/alice/develop/A/node_modules/pkg/x.js",
        "/Users/alice/develop/B/.git/HEAD",
        "/Users/alice/Documents/C/package.json",
    ], at: now)
    let roots = Set(activities.map(\.projectRoot))
    #expect(roots.contains("/Users/alice/develop/A"))
    #expect(roots.contains("/Users/alice/develop/B"))
    #expect(roots.contains("/Users/alice/Documents/C"))
}

@Test func activityTrackerFiltersByWindow() {
    let tracker = DevActivityTracker()
    tracker.record(
        eventPaths: ["/Users/alice/dev/P/node_modules/a"],
        at: Date().addingTimeInterval(-48 * 3600)
    )
    tracker.record(
        eventPaths: ["/Users/alice/dev/Q/node_modules/a"],
        at: Date()
    )
    #expect(tracker.activeProjects(since: 24 * 3600).map(\.projectRoot) == ["/Users/alice/dev/Q"])
}

@Test func activityTrackerKeepsLatestTimestamp() {
    let tracker = DevActivityTracker()
    let old = Date().addingTimeInterval(-3600)
    tracker.record(eventPaths: ["/Users/alice/dev/A/node_modules/x"], at: old)
    tracker.record(eventPaths: ["/Users/alice/dev/A/node_modules/y"], at: Date())
    let active = tracker.activeProjects(since: 24 * 3600)
    #expect(active.count == 1)
    #expect(active[0].artifact == "node_modules")
}
