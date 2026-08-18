import Testing
import Foundation
@testable import DiskReservoirCore

@Test func volumeReaderReadsRootVolume() {
    let info = VolumeReader.read(fileURL: URL(fileURLWithPath: "/"))
    #expect(info.totalBytes > 0)
    #expect(info.availableBytes > 0)
    #expect(info.availableBytes <= info.totalBytes)
}

@Test func statvfsFallbackReturnsSaneValues() {
    let info = VolumeReader.statvfsRead(fileURL: URL(fileURLWithPath: "/"))
    #expect(info != nil)
    #expect((info?.totalBytes ?? 0) > 0)
    #expect((info?.availableBytes ?? 0) > 0)
}

@Test func statvfsFallbackReturnsNilForMissingPath() {
    let info = VolumeReader.statvfsRead(fileURL: URL(fileURLWithPath: "/definitely/not/a/real/path-\(UUID().uuidString)"))
    #expect(info == nil)
}
