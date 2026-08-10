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
    private let cloneRatios: [String: Double]

    public init(
        now: @escaping @Sendable () -> Date = { Date() },
        includeHidden: Bool = true,
        cloneRatios: [String: Double] = [:]
    ) {
        self.now = now
        self.includeHidden = includeHidden
        self.cloneRatios = cloneRatios
    }

    public func scan(recipes: [Recipe], homeDirectory: String) throws -> ScanResult {
        let paths = StoragePaths(baseURL: nil, homeDirectory: homeDirectory)
        var items: [ScanItem] = []
        var records: [FileRecord] = []
        for recipe in recipes {
            for path in recipe.resolvePaths(paths) {
                guard FileManager.default.fileExists(atPath: path) else { continue }
                let url = URL(fileURLWithPath: path, isDirectory: true)
                let itemID = "\(recipe.id):\(path)"
                let (size, allocated, count, modified, files) = try measureDirectory(url, itemID: itemID)
                items.append(ScanItem(
                    id: itemID,
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
        var honestItems = ReclaimableEstimator().apply(to: items, records: records)
        // 克隆型配方（如 XCTestDevices）按校准比例估算真实可释放量
        honestItems = honestItems.map { item in
            guard let recipe = recipes.first(where: { $0.id == item.recipeID }), recipe.cloneProne else {
                return item
            }
            let ratio = cloneRatios[item.recipeID] ?? 0.2
            return ScanItem(
                id: item.id,
                recipeID: item.recipeID,
                name: item.name,
                path: item.path,
                category: item.category,
                safety: item.safety,
                disposition: item.disposition,
                sizeBytes: item.sizeBytes,
                allocatedBytes: item.allocatedBytes,
                reclaimableBytes: Int64(Double(item.allocatedBytes) * ratio),
                fileCount: item.fileCount,
                lastModified: item.lastModified
            )
        }
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
