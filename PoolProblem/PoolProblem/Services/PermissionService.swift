import Foundation
import AppKit

enum PermissionService {
    private static var cached: Bool?

    static func hasFullDiskAccess() async -> Bool {
        if let cached { return cached }
        let result = await Task.detached(priority: .userInitiated) {
            let containers = NSHomeDirectory() + "/Library/Containers"
            return (try? FileManager.default.contentsOfDirectory(atPath: containers)) != nil
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
