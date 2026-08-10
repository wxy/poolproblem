import Foundation

public struct StoragePaths: Sendable {
    public let baseURL: URL
    public let homeDirectory: String

    public init(baseURL: URL? = nil, homeDirectory: String = NSHomeDirectory()) {
        self.homeDirectory = homeDirectory
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
}
