import AppKit
import SwiftUI
import Combine

@MainActor
final class StatusItemController: NSObject, NSPopoverDelegate {
    private let statusItem: NSStatusItem
    private let popover: NSPopover
    private let state: AppState
    private var cancellables: Set<AnyCancellable> = []
    /// 清理时驱动气泡上升的定时器与当前进度（0 = 罐底，1 = 罐顶）
    private var bubbleTimer: Timer?
    private var bubbleProgress: Double = 0

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
        let activity: PoolStatusIcon.Activity
        if state.isCleaning {
            activity = .cleaning
        } else if state.isScanning {
            activity = .scanning
        } else {
            activity = .idle
        }
        if activity != .idle {
            if bubbleTimer == nil {
                bubbleProgress = 0
                bubbleTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 24.0, repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated {
                        self?.advanceBubble()
                    }
                }
            }
        } else {
            bubbleTimer?.invalidate()
            bubbleTimer = nil
        }
        statusItem.button?.image = PoolStatusIcon.image(
            availableBytes: state.availableBytes,
            waterlineBytes: state.waterlineBytes,
            activity: activity,
            bubbleProgress: activity != .idle ? bubbleProgress : nil
        )
    }

    /// 气泡进度推进：约 1.5 秒从罐底升到罐顶，然后循环。
    private func advanceBubble() {
        bubbleProgress += 1.0 / 36.0
        if bubbleProgress >= 1 {
            bubbleProgress = 0
        }
        statusItem.button?.image = PoolStatusIcon.image(
            availableBytes: state.availableBytes,
            waterlineBytes: state.waterlineBytes,
            activity: .cleaning,
            bubbleProgress: bubbleProgress
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
