import Foundation
import AppKit

enum PermissionService {
    static func hasFullDiskAccess() -> Bool {
        let containers = NSHomeDirectory() + "/Library/Containers"
        return (try? FileManager.default.contentsOfDirectory(atPath: containers)) != nil
    }

    static func openSystemSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }
}
