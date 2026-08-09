import Foundation

public struct PGrepProcessInspector: ProcessInspecting {
    private let pgrepURL: URL
    private let maxAttempts: Int

    public init(pgrepURL: URL = URL(fileURLWithPath: "/usr/bin/pgrep"), maxAttempts: Int = 3) {
        self.pgrepURL = pgrepURL
        self.maxAttempts = maxAttempts
    }

    public func isRunning(_ processName: String) -> Bool {
        for _ in 0..<maxAttempts {
            let process = Process()
            process.executableURL = pgrepURL
            process.arguments = ["-x", processName]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = Pipe()
            do {
                try process.run()
                process.waitUntilExit()
                if process.terminationStatus == 0 { return true }
            } catch {
                return false
            }
        }
        return false
    }
}
