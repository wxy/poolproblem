import AppKit
import SwiftUI
import Combine

@MainActor
final class StatusItemController: NSObject, NSPopoverDelegate {
    private let statusItem: NSStatusItem
    private let popover: NSPopover
    private let state: AppState
    private let service: AppService
    private var cancellables: Set<AnyCancellable> = []
    private var globalClickMonitor: Any?
    private var localClickMonitor: Any?
    /// 清理时驱动气泡上升的定时器与当前进度（0 = 罐底，1 = 罐顶）
    private var bubbleTimer: Timer?
    private var bubbleProgress: Double = 0

    init(state: AppState, service: AppService) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        popover = NSPopover()
        self.state = state
        self.service = service
        super.init()

        popover.behavior = .transient
        // The first SwiftUI frame is already visually rich. AppKit's additional
        // open animation delayed hit testing and made the pointer feel blocked.
        popover.animates = false
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
        // Only icon-relevant values drive rendering. The previous broad
        // objectWillChange subscription redrew AppKit images for every panel
        // state mutation, including list/detail animation updates.
        Publishers.CombineLatest4(
            state.$availableBytes.removeDuplicates(),
            state.$waterlineBytes.removeDuplicates(),
            state.$isScanning.removeDuplicates(),
            state.$isCleaning.removeDuplicates()
        )
            .debounce(for: .milliseconds(80), scheduler: DispatchQueue.main)
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
                bubbleTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 8.0, repeats: true) { [weak self] _ in
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
        bubbleProgress += 1.0 / 12.0
        if bubbleProgress >= 1 {
            bubbleProgress = 0
        }
        statusItem.button?.image = PoolStatusIcon.image(
            availableBytes: state.availableBytes,
            waterlineBytes: state.waterlineBytes,
            activity: state.isCleaning ? .cleaning : .scanning,
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
        // Show a static first frame; animation starts only after AppKit has put
        // the popover on screen, so the click does not wait for TimelineView.
        state.isPopoverVisible = false
        service.prioritizePopoverPresentation()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        Task { [weak service] in
            await service?.reconcileDashboardState()
        }
    }

    private func installDismissalMonitors() {
        removeDismissalMonitors()
        let mouseEvents: NSEvent.EventTypeMask = [
            .leftMouseDown,
            .rightMouseDown,
            .otherMouseDown,
        ]

        // A global monitor sees clicks delivered to other apps and the desktop.
        // Dispatch back to MainActor because the monitor does not promise actor
        // isolation even though AppKit normally invokes it on the main thread.
        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: mouseEvents
        ) { [weak self] _ in
            DispatchQueue.main.async {
                self?.closePopoverFromOutsideClick()
            }
        }

        // A local monitor covers other windows owned by this app. Preserve
        // interaction inside the popover and any sheet attached to it.
        localClickMonitor = NSEvent.addLocalMonitorForEvents(
            matching: mouseEvents
        ) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self else { return }
                let popoverWindow = self.popover.contentViewController?.view.window
                let clickedWindow = event.window
                let isInsidePopover = clickedWindow === popoverWindow
                    || clickedWindow?.sheetParent === popoverWindow
                let isStatusButton = clickedWindow === self.statusItem.button?.window
                if !isInsidePopover, !isStatusButton {
                    self.closePopoverFromOutsideClick()
                }
            }
            return event
        }
    }

    private func closePopoverFromOutsideClick() {
        guard popover.isShown else {
            removeDismissalMonitors()
            return
        }
        popover.performClose(nil)
    }

    private func removeDismissalMonitors() {
        if let globalClickMonitor {
            NSEvent.removeMonitor(globalClickMonitor)
            self.globalClickMonitor = nil
        }
        if let localClickMonitor {
            NSEvent.removeMonitor(localClickMonitor)
            self.localClickMonitor = nil
        }
    }

    func popoverDidShow(_ notification: Notification) {
        installDismissalMonitors()
        DispatchQueue.main.async { [weak self] in
            guard let self, self.popover.isShown else { return }
            self.state.isPopoverVisible = true
        }
    }

    func popoverWillClose(_ notification: Notification) {
        removeDismissalMonitors()
        service.endPopoverPresentationPriority()
        state.isPopoverVisible = false
    }

}
