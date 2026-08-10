import Testing
import Foundation
@testable import DiskReservoirCore

private func item(_ id: String, recipe: String, name: String, category: DiskReservoirCore.Category, size: Int64) -> ScanItem {
    ScanItem(
        id: id, recipeID: recipe, name: name, path: "/tmp/\(id)",
        category: category, safety: .safeWhileRunning, disposition: .deletePermanently,
        sizeBytes: size, allocatedBytes: size, reclaimableBytes: size,
        fileCount: 1, lastModified: nil
    )
}

@Test func attributionComputesDeltas() {
    let earlier = Snapshot(
        volume: VolumeInfo(totalBytes: 1000, availableBytes: 800, timestamp: Date().addingTimeInterval(-86_400)),
        items: [item("x1", recipe: "xctestdevices", name: "XCTest", category: .xcode, size: 100)]
    )
    let later = Snapshot(
        volume: VolumeInfo(totalBytes: 1000, availableBytes: 700, timestamp: Date()),
        items: [item("x1", recipe: "xctestdevices", name: "XCTest", category: .xcode, size: 250)]
    )
    let report = FlowAnalyzer().attribution(snapshots: [earlier, later])
    #expect(report.recipeDeltas["xctestdevices"] == 150)
    #expect(report.categoryDeltas[.xcode] == 150)
    #expect(report.totalDelta == 150)
}

@Test func growthAlertTriggersOnAbsoluteGrowth() {
    let earlier = Snapshot(
        volume: VolumeInfo(totalBytes: 1000, availableBytes: 800, timestamp: Date().addingTimeInterval(-86_400)),
        items: [item("x1", recipe: "r", name: "N", category: .xcode, size: 100)]
    )
    let later = Snapshot(
        volume: VolumeInfo(totalBytes: 1000, availableBytes: 400, timestamp: Date()),
        items: [item("x1", recipe: "r", name: "N", category: .xcode, size: 3_000_000_000)]
    )
    let alert = FlowAnalyzer().growthAlert(snapshots: [earlier, later])
    #expect(alert?.itemID == "x1")
    #expect((alert?.deltaBytes ?? 0) > 2 << 30)
}

@Test func regrowthTracksCleanup() {
    let log = CleanLogEntry(
        id: UUID(), timestamp: Date().addingTimeInterval(-86_400),
        itemIDs: ["x1"], freedBytes: 500, disposition: .deletePermanently
    )
    let earlier = Snapshot(
        volume: VolumeInfo(totalBytes: 1000, availableBytes: 900, timestamp: Date().addingTimeInterval(-86_400)),
        items: []
    )
    let later = Snapshot(
        volume: VolumeInfo(totalBytes: 1000, availableBytes: 850, timestamp: Date()),
        items: [item("x1", recipe: "xctestdevices", name: "XCTest", category: .xcode, size: 300)]
    )
    let reports = FlowAnalyzer().regrowth(snapshots: [earlier, later], log: [log])
    #expect(reports.first?.cleanedBytes == 500)
    #expect(reports.first?.regrownBytes == 300)
}

@Test func growthRatesEstimatePerItemSlope() {
    let now = Date()
    var snapshots: [Snapshot] = []
    for day in 0..<3 {
        let size = 100 + Int64(day) * 200
        snapshots.append(Snapshot(
            volume: VolumeInfo(
                totalBytes: 1000,
                availableBytes: 800,
                timestamp: now.addingTimeInterval(Double(day) * 86_400)
            ),
            items: [item("g1", recipe: "r", name: "N", category: .xcode, size: size)]
        ))
    }
    let rates = FlowAnalyzer().growthRates(snapshots: snapshots)
    #expect(rates["g1"] != nil)
    #expect(abs((rates["g1"] ?? 0) - 200) < 1)
}
