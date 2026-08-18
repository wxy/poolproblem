import Testing
import Foundation
@testable import DiskReservoirCore

@Test func patternizeReplacesHomeAndHashes() {
    let home = "/Users/alice"
    #expect(PathPatternizer.patternize("/Users/alice/Library/Caches/MyApp", homeDirectory: home)
            == "~/Library/Caches/MyApp")
    #expect(PathPatternizer.patternize(
        "/Users/alice/Library/Developer/Xcode/DerivedData/AB12CD34EF56",
        homeDirectory: home
    ) == "~/Library/Developer/Xcode/DerivedData/*")
    #expect(PathPatternizer.patternize(
        "/Users/alice/Library/Caches/Tool/8F4B2C1A-9D3E-4A5B-8C6D-7E8F9A0B1C2D",
        homeDirectory: home
    ) == "~/Library/Caches/Tool/*")
}

@Test func patternizeLeavesOtherPathsIntact() {
    #expect(PathPatternizer.patternize("/usr/local/var", homeDirectory: "/Users/alice")
            == "/usr/local/var")
}
