import Testing
import Foundation
@testable import DiskReservoirCore

@Test func scanItemCodableRoundTrip() throws {
    let item = ScanItem(
        id: "xctest-1", recipeID: "xctestdevices", name: "XCTestDevices",
        path: "/tmp/x", category: .xcode, safety: .safeWhileRunning,
        disposition: .deletePermanently, sizeBytes: 100, allocatedBytes: 80,
        reclaimableBytes: 10, fileCount: 3, lastModified: nil
    )
    let data = try JSONEncoder().encode(item)
    let decoded = try JSONDecoder().decode(ScanItem.self, from: data)
    #expect(decoded == item)
}

@Test func configDefaultWaterlineIs30GB() {
    #expect(Config.default.waterlineGB == 30)
}

@Test func cleanLogEntryRoundTrip() throws {
    let entry = CleanLogEntry(
        id: UUID(), timestamp: Date(timeIntervalSince1970: 1_000_000),
        itemIDs: ["a"], freedBytes: 42, disposition: .trash
    )
    let data = try JSONEncoder().encode(entry)
    let decoded = try JSONDecoder().decode(CleanLogEntry.self, from: data)
    #expect(decoded == entry)
}

@Test func cleanLogEntryDecodesWithoutItemNamesForBackwardCompatibility() throws {
    let json = """
    {
      "id": "00000000-0000-0000-0000-000000000001",
      "timestamp": "2001-09-09T01:46:40Z",
      "itemIDs": ["xctestdevices:/tmp/old"],
      "freedBytes": 42,
      "disposition": "trash"
    }
    """.data(using: .utf8)!
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let decoded = try decoder.decode(CleanLogEntry.self, from: json)
    #expect(decoded.itemNames.isEmpty)
    #expect(decoded.source == .manual)
    #expect(decoded.itemIDs == ["xctestdevices:/tmp/old"])
}
