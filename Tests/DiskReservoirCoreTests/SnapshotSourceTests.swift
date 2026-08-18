import Testing
import Foundation
@testable import DiskReservoirCore

@Test func snapshotDecodesLegacyJSONWithoutSourceAsFull() throws {
    let json = """
    {"volume":{"totalBytes":1000,"availableBytes":500,"timestamp":"2026-08-18T00:00:00Z"},"items":[]}
    """
    let data = try #require(json.data(using: .utf8))
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let snapshot = try decoder.decode(Snapshot.self, from: data)
    #expect(snapshot.source == .full)
}

@Test func snapshotRoundTripsSource() throws {
    let snapshot = Snapshot(
        volume: VolumeInfo(totalBytes: 1000, availableBytes: 500, timestamp: Date()),
        items: [],
        source: .incremental
    )
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let data = try encoder.encode(snapshot)
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let decoded = try decoder.decode(Snapshot.self, from: data)
    #expect(decoded.source == .incremental)
}
