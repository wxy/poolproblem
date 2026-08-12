import Foundation
import AppKit

enum PermissionService {
    static func hasFullDiskAccess() async -> Bool {
        // 每次实时检测：避免用户在系统设置中授权/撤销后，应用内状态陈旧
        return await Task.detached(priority: .userInitiated) {
            let containers = NSHomeDirectory() + "/Library/Containers"
            let trash = NSHomeDirectory() + "/.Trash"
            let containersOK = (try? FileManager.default.contentsOfDirectory(atPath: containers)) != nil
            let trashOK = (try? FileManager.default.contentsOfDirectory(atPath: trash)) != nil
            return containersOK && trashOK
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
