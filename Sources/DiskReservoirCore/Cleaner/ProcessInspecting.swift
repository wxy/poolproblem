public protocol ProcessInspecting: Sendable {
    func isRunning(_ processName: String) -> Bool
}

public struct AlwaysFalseProcessInspector: ProcessInspecting {
    public init() {}
    public func isRunning(_ processName: String) -> Bool { false }
}
