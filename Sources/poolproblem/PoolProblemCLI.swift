import ArgumentParser

@main
struct PoolProblemCLI: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "poolproblem",
        abstract: CLILocalized.string("cli.abstract"),
        version: "0.1.0",
        subcommands: [ScanCommand.self, SuggestCommand.self, CleanCommand.self, StatusCommand.self]
    )
}
