import Foundation
import AppKit

enum PermissionService {
    private static var cached: Bool?

    static func hasFullDiskAccess() async -> Bool {
        if let cached { return cached }
        let result = await Task.detached(priority: .userInitiated) {
            let containers = NSHomeDirectory() + "/Library/Containers"
            let trash = NSHomeDirectory() + "/.Trash"
            let containersOK = (try? FileManager.default.contentsOfDirectory(atPath: containers)) != nil
            let trashOK = (try? FileManager.default.contentsOfDirectory(atPath: trash)) != nil
            return containersOK && trashOK
        }.value
        cached = result
        return result
    }

    static func resetCache() {
        cached = nil
    }

    static func openSystemSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }
}
