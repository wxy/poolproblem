import ArgumentParser

@main
struct PoolProblemCLI: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "poolproblem",
        abstract: "The Pool Problem - 磁盘蓄水池：扫描、预测、清理。",
        version: "0.1.0",
        subcommands: [ScanCommand.self, SuggestCommand.self, CleanCommand.self, StatusCommand.self]
    )
}
