import Testing
import Foundation
@testable import DiskReservoirCore

private func entry(
    _ path: String,
    delta: Int64,
    observedAt: Date,
    itemID: String? = nil,
    kind: GrowthKind = .surface,
    pattern: String? = nil
) -> GrowthEntry {
    GrowthEntry(
        observedAt: observedAt,
        elapsedDays: 1,
        itemID: itemID,
        recipeID: nil,
        name: URL(fileURLWithPath: path).lastPathComponent,
        path: path,
        pattern: pattern ?? path,
        kind: kind,
        deltaBytes: delta,
        rateBytesPerDay: Double(delta)
    )
}

@Test func mergerCollapsesIdenticalDeltaDuplicates() {
    let date = Date(timeIntervalSince1970: 1_000_000)
    let merged = GrowthInsightMerger.merge([
        entry("/tmp/project/.build", delta: 5_936_476_706, observedAt: date),
        entry("/tmp/project/.build", delta: 5_936_476_706, observedAt: date.addingTimeInterval(600)),
    ])
    #expect(merged.count == 1)
    #expect(merged[0].deltaBytes == 5_936_476_706)
}

@Test func mergerSumsDistinctDeltasForSamePath() {
    let date = Date(timeIntervalSince1970: 1_000_000)
    let merged = GrowthInsightMerger.merge([
        entry("/tmp/project", delta: 100, observedAt: date),
        entry("/tmp/project", delta: 50, observedAt: date.addingTimeInterval(600)),
    ])
    #expect(merged.count == 1)
    #expect(merged[0].deltaBytes == 150)
}

@Test func mergerKeepsDifferentPathsSeparate() {
    let date = Date(timeIntervalSince1970: 1_000_000)
    let merged = GrowthInsightMerger.merge([
        entry("/tmp/project-a", delta: 100, observedAt: date),
        entry("/tmp/project-b", delta: 200, observedAt: date),
    ])
    #expect(merged.count == 2)
}

@Test func mergerUsesLatestObservationTime() {
    let early = Date(timeIntervalSince1970: 1_000_000)
    let late = early.addingTimeInterval(3600)
    let merged = GrowthInsightMerger.merge([
        entry("/tmp/project", delta: 100, observedAt: early),
        entry("/tmp/project", delta: 50, observedAt: late),
    ])
    #expect(merged[0].observedAt == late)
}

@Test func mergerGroupsUnknownSpaceByItemID() {
    let date = Date(timeIntervalSince1970: 1_000_000)
    let merged = GrowthInsightMerger.merge([
        entry("", delta: 10, observedAt: date, itemID: "unknown", kind: .unknownSpace),
        entry("", delta: 20, observedAt: date, itemID: "unknown", kind: .unknownSpace),
    ])
    #expect(merged.count == 1)
    #expect(merged[0].deltaBytes == 30)
}
