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
                paths: item.paths,
                category: item.category,
                safety: item.safety,
                disposition: item.disposition,
                sizeBytes: item.sizeBytes,
                allocatedBytes: item.allocatedBytes,
                // 没有逐文件记录的项（如轻量测量的废纸篓）保留扫描到的原始可回收量，
                // 而不是被当成 0——否则废纸篓这类目录会显示为 0KB
                reclaimableBytes: estimates[item.id] ?? item.reclaimableBytes,
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
