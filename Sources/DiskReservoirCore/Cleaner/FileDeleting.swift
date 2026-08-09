import Foundation

public protocol FileDeleting: Sendable {
    func delete(url: URL, disposition: CleanDisposition) throws -> Int64
}

public struct FileManagerFileDeleter: FileDeleting {
    public init() {}

    public func delete(url: URL, disposition: CleanDisposition) throws -> Int64 {
        switch disposition {
        case .none:
            return 0
        case .trash:
            let allocated = allocatedBytes(of: url)
            var resulting: NSURL?
            try FileManager.default.trashItem(at: url, resultingItemURL: &resulting)
            return allocated
        case .deletePermanently:
            let allocated = allocatedBytes(of: url)
            try FileManager.default.removeItem(at: url)
            return allocated
        }
    }

    private func allocatedBytes(of url: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.totalFileAllocatedSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }
        var total: Int64 = 0
        while let element = enumerator.nextObject() as? URL {
            let values = try? element.resourceValues(forKeys: [.totalFileAllocatedSizeKey])
            total += Int64(values?.totalFileAllocatedSize ?? 0)
        }
        return total
    }
}
