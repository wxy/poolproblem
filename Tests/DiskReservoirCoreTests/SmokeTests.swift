import Testing
@testable import DiskReservoirCore

@Test func schemaVersionIsOne() {
    #expect(DiskReservoirCore.schemaVersion == 1)
}
