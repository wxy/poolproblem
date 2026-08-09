import Foundation
import AppKit

enum PermissionService {
    static func hasFullDiskAccess() async -> Bool {
        await Task.detached(priority: .userInitiated) {
            let containers = NSHomeDirectory() + "/Library/Containers"
            return (try? FileManager.default.contentsOfDirectory(atPath: containers)) != nil
        }.value
    }

    static func openSystemSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }
}
