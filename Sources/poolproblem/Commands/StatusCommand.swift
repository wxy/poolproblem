import ArgumentParser
import DiskReservoirCore
import Foundation

struct StatusCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "status",
        abstract: "水位、预测与最近清理记录"
    )

    @Flag(name: .long, help: "输出 JSON")
    var json = false

    func run() throws {
        let paths = StoragePaths()
        let config = try JSONStore().load(Config.self, from: paths.configURL) ?? .default
        let snapshots = try SnapshotStore(paths: paths).snapshots()
        let log = try CleanLogStore(paths: paths).entries()
        let prediction = FullPrediction().daysUntilFull(
            snapshots: snapshots,
            waterlineBytes: Int64(config.waterlineGB * 1_000_000_000)
        )
        if json {
            let data = try JSONOutput.status(snapshots: snapshots, log: log, prediction: prediction)
            FileHandle.standardOutput.write(data)
            FileHandle.standardOutput.write(Data("\n".utf8))
        } else {
            if let latest = snapshots.last {
                print("可用: \(latest.volume.availableBytes) 字节（快照 \(snapshots.count) 份）")
            } else {
                print("尚无快照，请先运行 scan 并保存（后续 App 版会自动保存）。")
            }
            if let prediction {
                print("按当前流速，约 \(Int(prediction.rounded())) 天后到水线。")
            }
            for entry in log.suffix(10) {
                print("清理 \(entry.timestamp)：\(entry.freedBytes) 字节 (\(entry.disposition.rawValue))")
            }
        }
    }
}
