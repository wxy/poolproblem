import Foundation

/// A short, cooperative pause used when latency-sensitive UI must win over a
/// background directory walk. Checkpoints are intentionally cheap and do not
/// cancel or discard scan progress.
public final class ScanWorkloadGate: @unchecked Sendable {
    public static let shared = ScanWorkloadGate()

    private let condition = NSCondition()
    private var paused = false

    private init() {}

    public func pause() {
        condition.lock()
        paused = true
        condition.unlock()
    }

    public func resume() {
        condition.lock()
        paused = false
        condition.broadcast()
        condition.unlock()
    }

    public func checkpoint() {
        condition.lock()
        while paused {
            condition.wait()
        }
        condition.unlock()
    }
}
