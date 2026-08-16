import Testing
import Foundation
@testable import DiskReservoirCore

@Test func predictsDaysUntilFull() {
    let now = Date()
    var snapshots: [Snapshot] = []
    for day in 0..<7 {
        let available = Int64(100_000_000_000 - Int64(day) * 2_000_000_000)
        snapshots.append(Snapshot(
            volume: VolumeInfo(
                totalBytes: 1_000_000_000_000,
                availableBytes: available,
                timestamp: now.addingTimeInterval(Double(day) * 86_400)
            ),
            items: []
        ))
    }
    let days = FullPrediction().daysUntilFull(snapshots: snapshots, waterlineBytes: 30_000_000_000)
    // 7 天线性拟合：第 0 天 100GB、第 6 天 88GB，斜率 -2GB/天；
    // 从最后一个快照（88GB）到水线 30GB：(88-30)/2 = 29 天
    #expect(days != nil)
    #expect(abs((days ?? 0) - 29) < 1.0)
}

@Test func predictionUsesActualTimeIntervals() {
    let now = Date()
    let snapshots = (0..<6).map { index in
        Snapshot(
            volume: VolumeInfo(
                totalBytes: 1_000_000_000_000,
                availableBytes: 100_000_000_000 - Int64(index) * 1_000_000_000,
                timestamp: now.addingTimeInterval(Double(index) * 12 * 3600)
            ),
            items: []
        )
    }
    let days = FullPrediction().daysUntilFull(
        snapshots: snapshots,
        waterlineBytes: 30_000_000_000
    )
    #expect(days != nil)
    #expect(abs((days ?? 0) - 32.5) < 1.0)
}

@Test func stableDiskReturnsNil() {
    let now = Date()
    let snapshots = (0..<5).map { day in
        Snapshot(
            volume: VolumeInfo(
                totalBytes: 1000,
                availableBytes: 900,
                timestamp: now.addingTimeInterval(Double(day) * 86_400)
            ),
            items: []
        )
    }
    #expect(FullPrediction().daysUntilFull(snapshots: snapshots, waterlineBytes: 100) == nil)
}

@Test func insufficientSamplesReturnsNil() {
    let now = Date()
    let one = Snapshot(
        volume: VolumeInfo(totalBytes: 1000, availableBytes: 900, timestamp: now),
        items: []
    )
    #expect(FullPrediction().daysUntilFull(snapshots: [one], waterlineBytes: 100) == nil)
}
