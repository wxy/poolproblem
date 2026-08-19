import ArgumentParser
import DiskReservoirCore
import Foundation

struct SuggestCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "suggest",
        abstract: CLILocalized.string("suggest.abstract")
    )

    @Flag(name: .long, help: ArgumentHelp(CLILocalized.string("flag.json")))
    var json = false

    func run() throws {
        let paths = StoragePaths()
        let config = try JSONStore().load(Config.self, from: paths.configURL) ?? .default
        let scanner = DiskReservoirCore.Scanner(cloneRatios: config.cloneRatios)
        let result = try scanner.scan(recipes: RecipeRegistry.builtIn(), homeDirectory: paths.homeDirectory)
        let evaluator = RuleEvaluator(config: config)
        let suggestions = result.items.compactMap { item -> (ScanItem, EvaluatedAction)? in
            let action = evaluator.evaluate(item: item, isProcessRunning: { name in
                name.map { PGrepProcessInspector().isRunning($0) } ?? false
            })
            switch action.action {
            case .skip: return nil
            default: return (item, action)
            }
        }
        if json {
            let data = try JSONOutput.suggestions(suggestions)
            FileHandle.standardOutput.write(data)
            FileHandle.standardOutput.write(Data("\n".utf8))
        } else {
            for (item, action) in suggestions {
                print("\(item.name): \(action.action)")
            }
        }
    }
}
