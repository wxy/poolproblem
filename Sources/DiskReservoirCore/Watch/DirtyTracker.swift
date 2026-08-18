import Foundation

/// 纯逻辑脏路径跟踪：把 FSEvents 事件归并为需要重扫的受监听路径。
public struct DirtyTracker: Sendable {
    public let trackedPaths: [String]
    public private(set) var dirty: Set<String> = []

    public init(trackedPaths: [String]) {
        self.trackedPaths = trackedPaths
    }

    /// 事件路径 → 命中的受监听路径；返回本次新变脏的路径。
    @discardableResult
    public mutating func mark(eventPaths: [String]) -> [String] {
        var newlyDirty: [String] = []
        for event in eventPaths {
            for tracked in trackedPaths where Self.matches(event: event, tracked: tracked) {
                if dirty.insert(tracked).inserted {
                    newlyDirty.append(tracked)
                }
            }
        }
        return newlyDirty
    }

    /// 事件是受监听路径本身、其子路径、或其父路径之一即命中。
    public static func matches(event: String, tracked: String) -> Bool {
        event == tracked
            || event.hasPrefix(tracked + "/")
            || tracked.hasPrefix(event + "/")
    }

    public mutating func clear() {
        dirty.removeAll()
    }
}
