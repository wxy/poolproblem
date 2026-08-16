import ServiceManagement

enum LaunchAtLoginService {
    static var isEnabled: Bool {
        guard Bundle.main.bundleURL.path.hasPrefix("/Applications/") else {
            return false
        }
        return SMAppService.mainApp.status == .enabled
    }

    static func setEnabled(_ enabled: Bool) throws {
        guard Bundle.main.bundleURL.path.hasPrefix("/Applications/") else {
            return
        }
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }
}
