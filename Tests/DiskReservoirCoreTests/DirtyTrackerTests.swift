import Testing
import Foundation
@testable import DiskReservoirCore

@Test func dirtyTrackerMarksNestedEvents() {
    var tracker = DirtyTracker(trackedPaths: ["~/Library/Caches/A", "~/Library/Caches/B"])
    let newly = tracker.mark(eventPaths: ["~/Library/Caches/A/sub/x", "~/Library/Logs"])
    #expect(newly == ["~/Library/Caches/A"])
    #expect(tracker.dirty == ["~/Library/Caches/A"])
}

@Test func dirtyTrackerMatchesParentEvents() {
    var tracker = DirtyTracker(trackedPaths: ["~/Library/Caches/A"])
    // 重命名等场景：事件可能落在父目录
    _ = tracker.mark(eventPaths: ["~/Library/Caches"])
    #expect(tracker.dirty.contains("~/Library/Caches/A"))
}

@Test func dirtyTrackerIgnoresUnrelatedEventsAndClears() {
    var tracker = DirtyTracker(trackedPaths: ["~/Library/Caches/A"])
    _ = tracker.mark(eventPaths: ["/usr/local/var"])
    #expect(tracker.dirty.isEmpty)
    _ = tracker.mark(eventPaths: ["~/Library/Caches/A"])
    #expect(tracker.dirty.count == 1)
    tracker.clear()
    #expect(tracker.dirty.isEmpty)
}
