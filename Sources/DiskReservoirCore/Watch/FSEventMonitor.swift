import Darwin
import Foundation

/// 目录变更监听器。
///
/// 类型名为兼容既有调用保留；实现刻意不再使用 `FSEventStream`。后者会打开
/// `/dev/fsevents`，并在部分 macOS 版本中持续产生
/// `FileIDTreeGetVRefNumForDevice(...devfs...) returned -36` 日志。
///
/// 每个已存在的监听根使用一个 vnode source。事件只表示“这个根可能变化了”，
/// 具体扫描与归因仍由上层完成；同一 latency 窗口内的根会合并后回调。
public final class FSEventMonitor: @unchecked Sendable {
    private let latency: TimeInterval
    private let queue: DispatchQueue
    private var sources: [DispatchSourceFileSystemObject] = []
    private var handler: (@Sendable ([String]) -> Void)?
    private var pendingPaths = Set<String>()
    private var pendingDelivery: DispatchWorkItem?

    public init(
        latency: TimeInterval = 1.0,
        queue: DispatchQueue = DispatchQueue(label: "com.poolproblem.directory-events")
    ) {
        self.latency = max(0, latency)
        self.queue = queue
    }

    /// 监听路径在 start 时传入（监听范围随扫描结果变化）。
    /// 不存在或无法打开的路径会被跳过，不向系统文件事件服务提交无效路径。
    public func start(
        paths: [String],
        handler: @escaping @Sendable ([String]) -> Void
    ) {
        stop()

        let normalizedPaths = Set(paths.map {
            URL(fileURLWithPath: $0, isDirectory: true)
                .standardizedFileURL
                .resolvingSymlinksInPath()
                .path
        }).sorted()
        guard !normalizedPaths.isEmpty else { return }

        var newSources: [DispatchSourceFileSystemObject] = []
        for path in normalizedPaths {
            let descriptor = Darwin.open(path, O_EVTONLY | O_CLOEXEC)
            guard descriptor >= 0 else { continue }

            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: descriptor,
                eventMask: [.write, .delete, .rename, .extend, .attrib, .link, .revoke],
                queue: queue
            )
            source.setEventHandler { [weak self] in
                self?.enqueue(path: path)
            }
            source.setCancelHandler {
                Darwin.close(descriptor)
            }
            newSources.append(source)
        }

        guard !newSources.isEmpty else { return }
        queue.sync {
            self.handler = handler
            self.sources = newSources
        }
        newSources.forEach { $0.resume() }
    }

    public func stop() {
        let oldSources: [DispatchSourceFileSystemObject] = queue.sync {
            pendingDelivery?.cancel()
            pendingDelivery = nil
            pendingPaths.removeAll()
            handler = nil
            let old = sources
            sources = []
            return old
        }
        oldSources.forEach { $0.cancel() }
    }

    private func enqueue(path: String) {
        pendingPaths.insert(path)
        pendingDelivery?.cancel()
        let delivery = DispatchWorkItem { [weak self] in
            self?.deliverPendingPaths()
        }
        pendingDelivery = delivery
        queue.asyncAfter(deadline: .now() + latency, execute: delivery)
    }

    private func deliverPendingPaths() {
        let paths = pendingPaths.sorted()
        pendingPaths.removeAll()
        pendingDelivery = nil
        guard !paths.isEmpty else { return }
        handler?(paths)
    }

    deinit { stop() }
}
