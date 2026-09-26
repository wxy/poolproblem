import Foundation

/// 工具自清理命令（owner-command cleanup）。
///
/// 原理：`uv cache prune`、`go clean -modcache`、`pnpm store prune` 这类
/// owner 命令遵守工具自己的锁与代际语义，比直接删目录安全。配方声明
/// owner 命令后，清理引擎优先执行它；工具不可用或命令失败时才降级为
/// 按配方处置删除路径；两者都不可用则跳过并留痕。
/// 语义见 docs/superpowers/plans/2026-09-24-mole-informed-improvements.md §1.4。
public struct OwnerCommand: Equatable, Sendable {
    /// 可执行文件名（经 PATH 解析，如 "go"、"uv"）。
    public let executable: String
    public let arguments: [String]

    public init(executable: String, arguments: [String]) {
        self.executable = executable
        self.arguments = arguments
    }

    /// 配方集合 → 配方ID → owner 命令 映射（构造 Cleaner 时使用）。
    public static func mapByRecipeID(_ recipes: [Recipe]) -> [String: OwnerCommand] {
        Dictionary(uniqueKeysWithValues: recipes.compactMap { recipe in
            recipe.ownerCommand.map { (recipe.id, $0) }
        })
    }
}

/// owner 命令执行器抽象（测试注入假实现）。
public protocol OwnerCommandRunning: Sendable {
    /// 返回是否成功（exit 0）。缺失、超时、失败一律返回 false，由调用方降级。
    func run(_ command: OwnerCommand) -> Bool
}

/// 经 `/usr/bin/env` 解析 PATH 并执行 owner 命令，带超时兜底。
public struct EnvOwnerCommandRunner: OwnerCommandRunning {
    private let envURL: URL
    private let timeoutSeconds: TimeInterval

    public init(
        envURL: URL = URL(fileURLWithPath: "/usr/bin/env"),
        timeoutSeconds: TimeInterval = 120
    ) {
        self.envURL = envURL
        self.timeoutSeconds = timeoutSeconds
    }

    public func run(_ command: OwnerCommand) -> Bool {
        guard (try? envURL.checkResourceIsReachable()) == true else { return false }
        let process = Process()
        process.executableURL = envURL
        process.arguments = [command.executable] + command.arguments
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return false
        }
        let semaphore = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            process.waitUntilExit()
            semaphore.signal()
        }
        let timeout = DispatchTime.now() + .seconds(max(1, Int(timeoutSeconds)))
        guard semaphore.wait(timeout: timeout) == .success else {
            process.terminate()
            return false
        }
        return process.terminationStatus == 0
    }
}
