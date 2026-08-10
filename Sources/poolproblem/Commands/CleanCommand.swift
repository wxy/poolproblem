import ArgumentParser
import DiskReservoirCore
import Foundation

struct CleanCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "clean",
        abstract: "按水线与规则执行清理"
    )

    @Flag(name: .long, help: "只预览，不实际删除")
    var dryRun = false

    @Flag(name: .long, help: "输出 JSON")
    var json = false

    func run() throws {
        let paths = StoragePaths()
        let config = try JSONStore().load(Config.self, from: paths.configURL) ?? .default
        let waterlineBytes = Int64(config.waterlineGB * 1_000_000_000)
        let scanner = DiskReservoirCore.Scanner(cloneRatios: config.cloneRatios)
        let result = try scanner.scan(recipes: RecipeRegistry.builtIn(), homeDirectory: NSHomeDirectory())
        let evaluator = RuleEvaluator(config: config)
        let logStore = CleanLogStore(paths: paths)
        let cleaner = Cleaner(
            evaluator: evaluator,
            deleter: FileManagerFileDeleter(),
            inspector: PGrepProcessInspector(),
            logStore: logStore
        )
        let outcome: CleanOutcome
        if dryRun {
            let suggestions = result.items.compactMap { item -> (ScanItem, EvaluatedAction)? in
                let action = evaluator.evaluate(item: item, isProcessRunning: { name in
                    name.map { PGrepProcessInspector().isRunning($0) } ?? false
                })
                switch action.action {
                case .skip, .notify: return nil
                default: return (item, action)
                }
            }
            let dry = CleanOutcome(
                entries: suggestions.map { entry in
                    let disposition: CleanDisposition
                    if case .trash = entry.1.action {
                        disposition = .trash
                    } else {
                        disposition = .deletePermanently
                    }
                    return CleanLogEntry(
                        id: UUID(),
                        timestamp: Date(),
                        itemIDs: [entry.0.id],
                        freedBytes: entry.0.reclaimableBytes,
                        disposition: disposition
                    )
                },
                freedBytes: suggestions.reduce(0) { $0 + $1.0.reclaimableBytes },
                actualFreedBytes: 0,
                stillBelowWaterline: result.volume.availableBytes < waterlineBytes
            )
            outcome = dry
        } else {
            outcome = try cleaner.run(scan: result, config: config, waterlineBytes: waterlineBytes)
            if !outcome.calibrationUpdates.isEmpty {
                var updated = config
                for (recipeID, ratio) in outcome.calibrationUpdates {
                    updated.cloneRatios[recipeID] = ratio
                }
                try JSONStore().save(updated, to: paths.configURL)
            }
        }
        if json {
            let data = try JSONOutput.clean(outcome: outcome)
            FileHandle.standardOutput.write(data)
            FileHandle.standardOutput.write(Data("\n".utf8))
        } else {
            print("清理项: \(outcome.entries.count)，估算释放: \(outcome.freedBytes)，实测释放: \(outcome.actualFreedBytes)")
        }
    }
}
