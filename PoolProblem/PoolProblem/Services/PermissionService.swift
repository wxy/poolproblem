import Foundation
import AppKit
import DiskReservoirCore

enum PermissionService {
    static func hasFullDiskAccess() async -> Bool {
        // 每次实时检测：避免用户在系统设置中授权/撤销后，应用内状态陈旧
        return await Task.detached(priority: .userInitiated) {
            let fm = FileManager.default
            // 主检测：读取 TCC 数据库。该文件受完全磁盘访问保护，
            // 且任何 macOS 上都必定存在，不会因为"目录恰好为空"产生误判。
            let tccCandidates = [
                NSHomeDirectory() + "/Library/Application Support/com.apple.TCC/TCC.db",
                "/Library/Application Support/com.apple.TCC/TCC.db",
            ]
            if tccCandidates.contains(where: { fm.contents(atPath: $0) != nil }) {
                return true
            }
            // 兜底：能对废纸篓做 POSIX 枚举也视为已授权。
            // 不能使用 FileManager.contentsOfDirectory 判定：在部分系统版本上
            // 它对 ~/.Trash 即使有权限也返回空列表（成功但不抛出）。
            return POSIXDirectoryWalker.firstLevelCount(path: NSHomeDirectory() + "/.Trash") != nil
        }.value
    }

    static func resetCache() {
        // 已改为实时检测，保留空实现以兼容调用方
    }

    static func openSystemSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }
}
