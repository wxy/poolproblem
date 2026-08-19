import ArgumentParser
import DiskReservoirCore
import Foundation

struct ScanCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "scan",
        abstract: CLILocalized.string("scan.abstract")
    )

    @Flag(name: .long, help: ArgumentHelp(CLILocalized.string("flag.json")))
    var json = false

    func run() throws {
        let paths = StoragePaths()
        let config = try JSONStore().load(Config.self, from: paths.configURL) ?? .default
        let scanner = DiskReservoirCore.Scanner(cloneRatios: config.cloneRatios)
        let result = try scanner.scan(recipes: RecipeRegistry.builtIn(), homeDirectory: paths.homeDirectory)
        try SnapshotStore(paths: paths).append(Snapshot(volume: result.volume, items: result.items))
        if json {
            let data = try JSONOutput.scan(result: result)
            FileHandle.standardOutput.write(data)
            FileHandle.standardOutput.write(Data("\n".utf8))
        } else {
            print(CLILocalized.string("scan.available", result.volume.availableBytes))
            for item in result.items.sorted(by: { $0.reclaimableBytes > $1.reclaimableBytes }) {
                print(CLILocalized.string("scan.item", item.name, item.reclaimableBytes, item.safety.rawValue))
            }
        }
    }
}
