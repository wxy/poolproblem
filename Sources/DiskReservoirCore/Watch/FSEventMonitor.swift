import Foundation
import CoreServices

/// FSEventStream 轻量封装：
/// - 事件在专用串行队列上回调（latency 窗口内由系统合并）；
/// - 只报告"哪些路径变了"，扫描/归因交给上层；
/// - `@unchecked Sendable`：所有可变状态只在 `queue` 上访问。
public final class FSEventMonitor: @unchecked Sendable {
    private let paths: [String]
    private let latency: TimeInterval
    /// fileprivate：同一文件的 C 回调需要访问。
    fileprivate let queue: DispatchQueue
    private var stream: FSEventStreamRef?
    /// fileprivate：同一文件的 C 回调需要访问。
    fileprivate var handler: (@Sendable ([String]) -> Void)?

    public init(
        paths: [String],
        latency: TimeInterval = 1.0,
        queue: DispatchQueue = DispatchQueue(label: "com.poolproblem.fsevents")
    ) {
        self.paths = paths
        self.latency = latency
        self.queue = queue
    }

    public func start(handler: @escaping @Sendable ([String]) -> Void) {
        stop()
        self.handler = handler
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            fsEventCallback,
            &context,
            paths as CFArray,
            FSEventsGetCurrentEventId(),
            latency,
            // UseCFTypes：回调收到 CFArray（而非原始 C 数组），否则 unsafeBitCast 会崩溃
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents)
                | FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes)
        ) else { return }
        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
    }

    public func stop() {
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            self.stream = nil
        }
        handler = nil
    }

    deinit { stop() }
}

private func fsEventCallback(
    _ stream: ConstFSEventStreamRef,
    _ info: UnsafeMutableRawPointer?,
    _ numEvents: Int,
    _ eventPaths: UnsafeMutableRawPointer,
    _ eventFlags: UnsafePointer<FSEventStreamEventFlags>,
    _ eventIDs: UnsafePointer<FSEventStreamEventId>
) {
    guard let info else { return }
    let monitor = Unmanaged<FSEventMonitor>.fromOpaque(info).takeUnretainedValue()
    let paths = unsafeBitCast(eventPaths, to: NSArray.self) as? [String] ?? []
    monitor.queue.async { monitor.handler?(paths) }
}
