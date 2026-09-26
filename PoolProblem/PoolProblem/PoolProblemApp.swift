import SwiftUI

@main
struct PoolProblemApp: App {
    @StateObject private var state: AppState
    @State private var service: AppService
    @State private var statusItemController: StatusItemController?

    init() {
        guard InstanceLock.acquire() else {
            exit(0)
        }
        let state = AppState()
        _state = StateObject(wrappedValue: state)
        let service = AppService(state: state)
        _service = State(initialValue: service)
        _statusItemController = State(initialValue: StatusItemController(state: state, service: service))
        service.start()
    }

    var body: some Scene {
        Settings {
            SettingsView(state: state, service: service)
        }
        .commands {
            // This menu-bar utility has no sidebar. Removing the unused system
            // command also avoids SwiftUI's repeated "Toggle Sidebar" lookup.
            CommandGroup(replacing: .sidebar) { }
        }
    }
}
