import Testing
import Foundation
@testable import DiskReservoirCore

@Test func scanItemCodableRoundTrip() throws {
    let item = ScanItem(
        id: "xctest-1", recipeID: "xctestdevices", name: "XCTestDevices",
        path: "/tmp/x", category: .xcode, safety: .safeWhileRunning,
        disposition: .deletePermanently, sizeBytes: 100, allocatedBytes: 80,
        reclaimableBytes: 10, fileCount: 3, lastModified: nil,
        cleanability: .trashOnly
    )
    let data = try JSONEncoder().encode(item)
    let decoded = try JSONDecoder().decode(ScanItem.self, from: data)
    #expect(decoded == item)
    #expect(decoded.cleanability == .trashOnly)
}

@Test func scanItemDecodesLegacyJSONWithoutCleanability() throws {
    let json = """
    {
      "id": "trash:/Users/tester/.Trash",
      "recipeID": "trash",
      "name": "废纸篓",
      "path": "/Users/tester/.Trash",
      "category": "common",
      "safety": "userConfirm",
      "disposition": "none",
      "sizeBytes": 0,
      "allocatedBytes": 0,
      "reclaimableBytes": 0,
      "fileCount": 0,
      "lastModified": null
    }
    """.data(using: .utf8)!
    let decoded = try JSONDecoder().decode(ScanItem.self, from: json)
    #expect(decoded.cleanability == .regenerable)
}

@Test func configDefaultWaterlineIs30GB() {
    #expect(Config.default.waterlineGB == 30)
}

@Test func configDefaultProtectsBuildCriticalCacheChildren() {
    #expect(Config.default.protectedCacheChildren.contains("org.swift.swiftpm"))
    #expect(Config.default.protectedCacheChildren.contains("node-gyp"))
}

@Test func configDecodesLegacyJSONWithoutProtectedChildren() throws {
    let json = """
    {
      "waterlineGB": 30,
      "rules": [],
      "whitelistPaths": [],
      "enabledRecipes": [],
      "cloneRatios": {},
      "keptItemIDs": []
    }
    """.data(using: .utf8)!
    let decoded = try JSONDecoder().decode(Config.self, from: json)
    #expect(decoded.protectedCacheChildren == Config.default.protectedCacheChildren)
}

@Test func configRoundTripsProtectedChildren() throws {
    var config = Config.default
    config.protectedCacheChildren = ["org.swift.swiftpm", "custom-cache"]
    let data = try JSONEncoder().encode(config)
    let decoded = try JSONDecoder().decode(Config.self, from: data)
    #expect(decoded.protectedCacheChildren == ["org.swift.swiftpm", "custom-cache"])
}

@Test func configDefaultsMinimumCleanSizeAndRoundTrips() throws {
    var config = Config.default
    #expect(config.minimumCleanItemMB == 500)
    config.minimumCleanItemMB = 1200
    let data = try JSONEncoder().encode(config)
    let decoded = try JSONDecoder().decode(Config.self, from: data)
    #expect(decoded.minimumCleanItemMB == 1200)
}

@Test func legacyConfigWithoutMinimumCleanSizeDefaultsTo500() throws {
    let json = """
    {
      "waterlineGB": 30,
      "rules": [],
      "whitelistPaths": [],
      "cloneRatios": {},
      "keptItemIDs": []
    }
    """.data(using: .utf8)!
    let decoded = try JSONDecoder().decode(Config.self, from: json)
    #expect(decoded.minimumCleanItemMB == 500)
}

@Test func configDefaultsAutoEmptyBatchesOffAndRoundTrips() throws {
    var config = Config.default
    #expect(config.autoEmptyOwnTrashBatches == false)
    config.autoEmptyOwnTrashBatches = true
    let data = try JSONEncoder().encode(config)
    let decoded = try JSONDecoder().decode(Config.self, from: data)
    #expect(decoded.autoEmptyOwnTrashBatches == true)
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
