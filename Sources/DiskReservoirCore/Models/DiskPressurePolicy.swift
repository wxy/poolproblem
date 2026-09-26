import Foundation

public enum DiskPressureState: String, Codable, Equatable, Sendable {
    case healthy
    case warning
    case critical
}

/// Hysteretic free-space policy. Healthy machines only perform the cheap
/// volume-capacity probe; directory analysis starts in the warning band and
/// unattended cleanup is permitted only below the target waterline.
public struct DiskPressurePolicy: Equatable, Sendable {
    public let targetBytes: Int64
    public let analysisMarginBytes: Int64
    public let recoveryMarginBytes: Int64

    public init(targetBytes: Int64) {
        self.targetBytes = max(1_000_000_000, targetBytes)
        analysisMarginBytes = max(5_000_000_000, self.targetBytes / 3)
        recoveryMarginBytes = max(2_000_000_000, self.targetBytes / 6)
    }

    public func state(availableBytes: Int64) -> DiskPressureState {
        if availableBytes < targetBytes { return .critical }
        if availableBytes < targetBytes + analysisMarginBytes { return .warning }
        return .healthy
    }

    public var recoveryTargetBytes: Int64 {
        targetBytes + recoveryMarginBytes
    }

    /// Full analysis is edge-triggered and rate-limited. A sharp capacity drop
    /// may bring it forward, allowing genuine emergencies to preempt the normal
    /// cadence without turning every capacity probe into recursive I/O.
    public func shouldAnalyze(
        state: DiskPressureState,
        previousState: DiskPressureState?,
        now: Date,
        lastAnalysisAt: Date,
        availableBytes: Int64,
        lastAnalyzedAvailableBytes: Int64?
    ) -> Bool {
        guard state != .healthy else { return false }
        if previousState != state { return true }

        let minimumInterval: TimeInterval
        let significantDrop: Int64
        switch state {
        case .healthy:
            return false
        case .warning:
            minimumInterval = 30 * 60
            significantDrop = 1_000_000_000
        case .critical:
            minimumInterval = 10 * 60
            significantDrop = 500_000_000
        }
        if now.timeIntervalSince(lastAnalysisAt) >= minimumInterval {
            return true
        }
        if let lastAnalyzedAvailableBytes,
           lastAnalyzedAvailableBytes - availableBytes >= significantDrop {
            return true
        }
        return false
    }
}
