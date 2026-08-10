import Foundation
import Darwin
import DiskReservoirCore

enum InstanceLock {
    private static var handle: FileHandle?

    /// 获取单实例锁；返回 false 表示已有实例在运行。
    static func acquire() -> Bool {
        let paths = StoragePaths()
        try? FileManager.default.createDirectory(at: paths.baseURL, withIntermediateDirectories: true)
        let url = paths.baseURL.appendingPathComponent(".instance.lock")
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        guard let fileHandle = try? FileHandle(forWritingTo: url) else { return false }
        handle = fileHandle
        let result = flock(fileHandle.fileDescriptor, LOCK_EX | LOCK_NB)
        return result == 0
    }
}
