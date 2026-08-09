import Foundation

public struct ReclaimableEstimator: Sendable {
    public init() {}

    public func estimate(records: [FileRecord]) -> [String: Int64] {
        var inodeOwners: [InodeKey: (Int64, Set<String>)] = [:]
        var allItemIDs: Set<String> = []
        for record in records {
            allItemIDs.insert(record.itemID)
            let key = InodeKey(device: record.deviceID, inode: record.inode)
            var entry = inodeOwners[key] ?? (0, [])
            entry.0 = max(entry.0, record.allocatedBytes)
            entry.1.insert(record.itemID)
            inodeOwners[key] = entry
        }
        var result: [String: Int64] = Dictionary(uniqueKeysWithValues: allItemIDs.map { ($0, 0) })
        for (_, (bytes, owners)) in inodeOwners where owners.count == 1 {
            let owner = owners.first!
            result[owner, default: 0] += bytes
        }
        return result
    }

    public func apply(to items: [ScanItem], records: [FileRecord]) -> [ScanItem] {
        let estimates = estimate(records: records)
        return items.map { item in
            ScanItem(
                id: item.id,
                recipeID: item.recipeID,
                name: item.name,
                path: item.path,
                category: item.category,
                safety: item.safety,
                disposition: item.disposition,
                sizeBytes: item.sizeBytes,
                allocatedBytes: item.allocatedBytes,
                reclaimableBytes: estimates[item.id] ?? 0,
                fileCount: item.fileCount,
                lastModified: item.lastModified
            )
        }
    }

    private struct InodeKey: Hashable {
        let device: Int32
        let inode: UInt64
    }
}
