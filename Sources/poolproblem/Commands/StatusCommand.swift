import ArgumentParser
import DiskReservoirCore
import Foundation

struct StatusCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "status",
        abstract: CLILocalized.string("status.abstract")
    )

    @Flag(name: .long, help: ArgumentHelp(CLILocalized.string("flag.json")))
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
        // TM 本地快照只读探测：解释「删后不回升」。未知（nil）时两处输出都不展示。
        let localSnapshots = TMUtilSnapshotsProbe().listLocalSnapshots(volumePath: "/")
        if json {
            let data = try JSONOutput.status(
                snapshots: snapshots,
                log: log,
                prediction: prediction,
                localSnapshots: localSnapshots
            )
            FileHandle.standardOutput.write(data)
            FileHandle.standardOutput.write(Data("\n".utf8))
        } else {
            if let latest = snapshots.last {
                print(CLILocalized.string("status.available", latest.volume.availableBytes, snapshots.count))
            } else {
                print(CLILocalized.string("status.no_snapshot"))
            }
            if let prediction {
                print(CLILocalized.string("status.prediction", Int(prediction.rounded())))
            }
            if let localSnapshots, !localSnapshots.isEmpty {
                print(CLILocalized.string("status.snapshots", localSnapshots.count))
            }
            for entry in log.suffix(10) {
                print(CLILocalized.string("status.clean_log", entry.timestamp.description, entry.freedBytes, entry.disposition.rawValue))
            }
        }
    }
}
