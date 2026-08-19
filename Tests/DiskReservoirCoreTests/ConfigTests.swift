import Testing
import Foundation
@testable import DiskReservoirCore

@Test func configRoundTripsDevRoots() throws {
    var config = Config.default
    config.devRoots = ["/Users/alice/develop"]
    config.declinedDevRoots = ["/Users/alice/tmp"]
    let encoder = JSONEncoder()
    let data = try encoder.encode(config)
    let decoded = try JSONDecoder().decode(Config.self, from: data)
    #expect(decoded.devRoots == ["/Users/alice/develop"])
    #expect(decoded.declinedDevRoots == ["/Users/alice/tmp"])
}

@Test func configDecodesLegacyWithoutDevRoots() throws {
    let legacy = """
    {"waterlineGB":30,"rules":[],"whitelistPaths":[],"enabledRecipes":[]}
    """
    let config = try JSONDecoder().decode(Config.self, from: Data(legacy.utf8))
    #expect(config.devRoots.isEmpty)
    #expect(config.declinedDevRoots.isEmpty)
}
