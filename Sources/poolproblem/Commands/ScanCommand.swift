import ArgumentParser
import DiskReservoirCore
import Foundation

struct ScanCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "scan",
        abstract: "扫描各配方并输出大小与可释放量"
    )

    @Flag(name: .long, help: "输出 JSON")
    var json = false

    func run() throws {
        let paths = StoragePaths()
        let config = try JSONStore().load(Config.self, from: paths.configURL) ?? .default
        let scanner = DiskReservoirCore.Scanner(cloneRatios: config.cloneRatios)
        let result = try scanner.scan(recipes: RecipeRegistry.builtIn(), homeDirectory: NSHomeDirectory())
        try SnapshotStore(paths: paths).append(Snapshot(volume: result.volume, items: result.items))
        if json {
            let data = try JSONOutput.scan(result: result)
            FileHandle.standardOutput.write(data)
            FileHandle.standardOutput.write(Data("\n".utf8))
        } else {
            print("可用: \(result.volume.availableBytes) 字节")
            for item in result.items.sorted(by: { $0.reclaimableBytes > $1.reclaimableBytes }) {
                print("\(item.name): 可释放 \(item.reclaimableBytes) 字节 (\(item.safety.rawValue))")
            }
        }
    }
}
