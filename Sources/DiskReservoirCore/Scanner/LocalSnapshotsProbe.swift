import Foundation

/// Time Machine 本地快照只读探测。
///
/// 目的：解释「已删除文件但可用空间没有回升」——APFS 本地快照驻留期间，
/// 被删数据仍被快照引用，容量不会立刻释放。这是水线守护器的诚实计量义务，
/// 也是满盘预测的已知干扰源。探测绝不修改任何快照（回收快照属于 `tmutil` 域）。
public protocol LocalSnapshotsProbing: Sendable {
    /// 返回快照名列表；`nil` 表示未知（tmutil 缺失、失败或超时）。
    /// 未知与「零快照」是两种语义，调用方必须区分。
    func listLocalSnapshots(volumePath: String) -> [String]?
}

public struct TMUtilSnapshotsProbe: LocalSnapshotsProbing {
    private let tmutilURL: URL
    private let timeoutSeconds: TimeInterval

    public init(
        tmutilURL: URL = URL(fileURLWithPath: "/usr/bin/tmutil"),
        timeoutSeconds: TimeInterval = 10
    ) {
        self.tmutilURL = tmutilURL
        self.timeoutSeconds = timeoutSeconds
    }

    public func listLocalSnapshots(volumePath: String) -> [String]? {
        guard (try? tmutilURL.checkResourceIsReachable()) == true else { return nil }
        let process = Process()
        process.executableURL = tmutilURL
        process.arguments = ["listlocalsnapshots", volumePath]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return nil
        }
        // 超时兜底：探测绝不允许阻塞水线决策路径。
        let semaphore = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            process.waitUntilExit()
            semaphore.signal()
        }
        let timeout = DispatchTime.now() + .seconds(max(1, Int(timeoutSeconds)))
        guard semaphore.wait(timeout: timeout) == .success else {
            process.terminate()
            return nil
        }
        guard process.terminationStatus == 0 else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return Self.parse(String(data: data, encoding: .utf8) ?? "")
    }

    /// 解析 `tmutil listlocalsnapshots` 输出：只认 `com.apple.TimeMachine.` 前缀行。
    static func parse(_ output: String) -> [String] {
        output
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix("com.apple.TimeMachine.") }
    }
}
