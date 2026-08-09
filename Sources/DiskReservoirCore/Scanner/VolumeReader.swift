import Foundation

public enum VolumeReader {
    public static func read(fileURL: URL) -> VolumeInfo {
        let keys: Set<URLResourceKey> = [
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey,
        ]
        let values = try? fileURL.resourceValues(forKeys: keys)
        return VolumeInfo(
            totalBytes: Int64(values?.volumeTotalCapacity ?? 0),
            availableBytes: Int64(values?.volumeAvailableCapacityForImportantUsage ?? 0),
            timestamp: Date()
        )
    }
}
