import Foundation

public struct StoragePaths: Sendable {
    public let baseURL: URL
    public let homeDirectory: String

    public init(baseURL: URL? = nil, homeDirectory: String? = nil) {
        // CLI 测试/自定义环境可用 POOLPROBLEM_HOME 覆盖主目录，
        // 避免测试真实扫描用户主目录；未设置时回落 NSHomeDirectory()
        self.homeDirectory = homeDirectory
            ?? ProcessInfo.processInfo.environment["POOLPROBLEM_HOME"]
            ?? NSHomeDirectory()
        if let baseURL {
            self.baseURL = baseURL
        } else if let env = ProcessInfo.processInfo.environment["POOLPROBLEM_DATA_DIR"] {
            self.baseURL = URL(fileURLWithPath: env, isDirectory: true)
        } else if let group = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: "group.xingyu.wang.poolproblem"
        ) {
            self.baseURL = group
        } else {
            self.baseURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("PoolProblem", isDirectory: true)
        }
    }

    public var snapshotsURL: URL { baseURL.appendingPathComponent("snapshots.json") }
    public var configURL: URL { baseURL.appendingPathComponent("config.json") }
    public var cleanLogURL: URL { baseURL.appendingPathComponent("clean-log.json") }
    public var growthLedgerURL: URL { baseURL.appendingPathComponent("growth-ledger.json") }
    public var surfaceSnapshotURL: URL { baseURL.appendingPathComponent("surface-snapshot.json") }
    public var recipeSuggestionsURL: URL { baseURL.appendingPathComponent("recipe-suggestions.json") }
}
