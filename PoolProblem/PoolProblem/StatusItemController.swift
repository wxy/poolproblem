import AppKit
import SwiftUI
import Combine

@MainActor
final class StatusItemController: NSObject, NSPopoverDelegate {
    private let statusItem: NSStatusItem
    private let popover: NSPopover
    private let state: AppState
    private var cancellables: Set<AnyCancellable> = []

    init(state: AppState, service: AppService) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        popover = NSPopover()
        self.state = state
        super.init()

        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
        let hostingController = NSHostingController(rootView: MenuBarView(state: state, service: service))
        popover.contentViewController = hostingController

        if let button = statusItem.button {
            button.image = PoolStatusIcon.image(
                availableBytes: state.availableBytes,
                waterlineBytes: state.waterlineBytes
            )
            button.action = #selector(togglePopover)
            button.target = self
            button.setAccessibilityLabel("The Pool Problem")
        }
        // 数据变化时刷新图标水位
        state.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.refreshIcon()
            }
            .store(in: &cancellables)
    }

    private func refreshIcon() {
        statusItem.button?.image = PoolStatusIcon.image(
            availableBytes: state.availableBytes,
            waterlineBytes: state.waterlineBytes
        )
    }

    @objc private func togglePopover() {
        if popover.isShown {
            popover.performClose(nil)
        } else {
            showPopover()
        }
    }

    private func showPopover() {
        guard let button = statusItem.button else { return }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        NSApp.activate(ignoringOtherApps: true)
    }
}
