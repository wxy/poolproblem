import SwiftUI

@main
struct PoolProblemApp: App {
    @StateObject private var state: AppState
    @State private var service: AppService

    init() {
        let state = AppState()
        _state = StateObject(wrappedValue: state)
        _service = State(initialValue: AppService(state: state))
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(state: state, service: service)
        } label: {
            Image(systemName: "water.waves")
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(state: state, service: service)
        }
    }
}
