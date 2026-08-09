import Foundation

public struct ScanResult: Sendable {
    public let volume: VolumeInfo
    public let items: [ScanItem]
    public let records: [FileRecord]
    public let volumeURL: URL

    public init(volume: VolumeInfo, items: [ScanItem], records: [FileRecord], volumeURL: URL) {
        self.volume = volume
        self.items = items
        self.records = records
        self.volumeURL = volumeURL
    }
}

public struct Scanner: Sendable {
    private let now: @Sendable () -> Date
    private let includeHidden: Bool

    public init(
        now: @escaping @Sendable () -> Date = { Date() },
        includeHidden: Bool = true
    ) {
        self.now = now
        self.includeHidden = includeHidden
    }

    public func scan(recipes: [Recipe], homeDirectory: String) throws -> ScanResult {
        let paths = StoragePaths(baseURL: nil, homeDirectory: homeDirectory)
        var items: [ScanItem] = []
        var records: [FileRecord] = []
        for recipe in recipes {
            for path in recipe.resolvePaths(paths) {
                guard FileManager.default.fileExists(atPath: path) else { continue }
                let url = URL(fileURLWithPath: path, isDirectory: true)
                let (size, allocated, count, modified, files) = try measureDirectory(url, itemID: recipe.id)
                items.append(ScanItem(
                    id: "\(recipe.id):\(path)",
                    recipeID: recipe.id,
                    name: recipe.name,
                    path: path,
                    category: recipe.category,
                    safety: recipe.safety,
                    disposition: recipe.disposition,
                    sizeBytes: size,
                    allocatedBytes: allocated,
                    reclaimableBytes: allocated,
                    fileCount: count,
                    lastModified: modified
                ))
                records.append(contentsOf: files)
            }
        }
        let volume = VolumeReader.read(fileURL: URL(fileURLWithPath: homeDirectory))
        let honestItems = ReclaimableEstimator().apply(to: items, records: records)
        return ScanResult(
            volume: volume,
            items: honestItems,
            records: records,
            volumeURL: URL(fileURLWithPath: homeDirectory)
        )
    }

    private func measureDirectory(
        _ url: URL, itemID: String
    ) throws -> (size: Int64, allocated: Int64, count: Int, modified: Date?, files: [FileRecord]) {
        let keys: Set<URLResourceKey> = [
            .isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey,
            .fileSizeKey, .totalFileAllocatedSizeKey, .contentModificationDateKey,
        ]
        let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: Array(keys),
            options: includeHidden ? [] : [.skipsHiddenFiles]
        )
        var size: Int64 = 0
        var allocated: Int64 = 0
        var count = 0
        var newest: Date?
        var files: [FileRecord] = []
        while let element = enumerator?.nextObject() as? URL {
            let values = try element.resourceValues(forKeys: keys)
            if values.isSymbolicLink == true { continue }
            if values.isRegularFile == true {
                let alloc = Int64(values.totalFileAllocatedSize ?? values.fileSize ?? 0)
                size += Int64(values.fileSize ?? 0)
                allocated += alloc
                count += 1
                let fileStat = element.withUnsafeFileSystemRepresentation { ptr -> stat in
                    var st = stat()
                    if let ptr { stat(ptr, &st) }
                    return st
                }
                files.append(FileRecord(
                    itemID: itemID,
                    url: element,
                    allocatedBytes: alloc,
                    deviceID: fileStat.st_dev,
                    inode: fileStat.st_ino,
                    lastModified: values.contentModificationDate ?? .distantPast
                ))
                if let date = values.contentModificationDate, date > (newest ?? .distantPast) {
                    newest = date
                }
            }
        }
        return (size, allocated, count, newest, files)
    }
}
