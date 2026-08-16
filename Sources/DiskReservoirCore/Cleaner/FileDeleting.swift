import Foundation

public struct FileDeletionResult: Sendable {
    public let freedBytes: Int64
    public let resultingURL: URL?

    public init(freedBytes: Int64, resultingURL: URL? = nil) {
        self.freedBytes = freedBytes
        self.resultingURL = resultingURL
    }
}

public protocol FileDeleting: Sendable {
    func delete(url: URL, disposition: CleanDisposition) throws -> Int64
    func deleteReturningResult(url: URL, disposition: CleanDisposition) throws -> FileDeletionResult
}

public extension FileDeleting {
    func deleteReturningResult(url: URL, disposition: CleanDisposition) throws -> FileDeletionResult {
        FileDeletionResult(freedBytes: try delete(url: url, disposition: disposition))
    }
}

public struct FileManagerFileDeleter: FileDeleting {
    public init() {}

    public func delete(url: URL, disposition: CleanDisposition) throws -> Int64 {
        try deleteReturningResult(url: url, disposition: disposition).freedBytes
    }

    public func deleteReturningResult(url: URL, disposition: CleanDisposition) throws -> FileDeletionResult {
        switch disposition {
        case .none:
            return FileDeletionResult(freedBytes: 0)
        case .trash:
            let allocated = allocatedBytes(of: url)
            var resulting: NSURL?
            try FileManager.default.trashItem(at: url, resultingItemURL: &resulting)
            return FileDeletionResult(freedBytes: allocated, resultingURL: resulting as URL?)
        case .deletePermanently:
            let allocated = allocatedBytes(of: url)
            try FileManager.default.removeItem(at: url)
            return FileDeletionResult(freedBytes: allocated)
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
