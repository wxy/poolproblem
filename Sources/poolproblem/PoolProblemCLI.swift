import ArgumentParser

@main
struct PoolProblemCLI: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "poolproblem",
        abstract: CLILocalized.string("cli.abstract"),
        version: "1.1.0",
        subcommands: [
            ScanCommand.self,
            SuggestCommand.self,
            CleanCommand.self,
            StatusCommand.self,
            MCPCommand.self,
        ]
    )
}
