import AppKit
import os

/// Tab-group observation for a `MainWindowController`, which owns this; nothing here may run from its `deinit`.
/// `titleObserver` / `titleBroadcastObserver` stay on the controller because its `deinit` invalidates them inline.
final class TabGroupObserver {
    unowned let controller: MainWindowController

    init(controller: MainWindowController) {
        self.controller = controller
    }

    private static let trafficLightsReservationFallback: CGFloat = 75

    private static let trafficLightsTrailingPadding: CGFloat = 8

    private var tabGroupObservers: [NSKeyValueObservation] = []
    /// Must be `weak`, not an `ObjectIdentifier`: `NSKeyValueObservation` does not retain what it
    /// observes, so a dead group's address can be reused by a later group and read as "unchanged".
    private weak var lastObservedTabGroup: NSWindowTabGroup?
    private var lastObservedTabCount: Int = 0

    private static let tabsLogger = Logger(subsystem: "dev.conjfrnk.blackbird",
                                           category: "tabs")

    private func trafficLightsReservation() -> CGFloat {
        guard let window = controller.window else { return Self.trafficLightsReservationFallback }
        // Use the zoom button's own frame: its superview spans the whole window width.
        let reservation: CGFloat
        if let zoom = window.standardWindowButton(.zoomButton) {
            reservation = zoom.frame.maxX + Self.trafficLightsTrailingPadding
        } else {
            reservation = Self.trafficLightsReservationFallback
        }
        return reservation > 20 ? reservation : Self.trafficLightsReservationFallback
    }

    /// No minimum: the accessory is `.right`-anchored, so a wider strip overflows leftward under the traffic lights.
    private func tabStripWidth(forWindowWidth windowWidth: CGFloat) -> CGFloat {
        max(0, windowWidth - trafficLightsReservation())
    }

    // MARK: - Titlebar-integrated tab bar

    func installTitlebarTabBar() {
        guard let window = controller.window else { return }
        let vc = TitlebarTabBarViewController(window: window)
        window.addTitlebarAccessoryViewController(vc)
        controller.titlebarTabBar = vc
        refreshTabBar()
        // `tabGroup` is nil before the window is shown.
        DispatchQueue.main.async { [weak self] in
            self?.hideNativeTabStrip()
            self?.observeTabGroup()
        }
    }

    func hideNativeTabStrip() {
        guard let window = controller.window else { return }
        if let themeFrame = window.contentView?.superview {
            let excluding = [controller.titlebarTabBar?.view].compactMap { $0 }
            let matches = NativeTabStripHider.hide(in: themeFrame, excluding: excluding)
            let inGroup = (window.tabGroup?.windows.count ?? 1) > 1
            if inGroup, matches == 0 {
                Self.tabsLogger.warning("hideNativeTabStrip: 0 'TabBar' views found in a multi-tab window — AppKit may have renamed its private class; pill + native strip may both be visible.")
            }
        }
    }

    private func observeTabGroup() {
        tabGroupObservers.removeAll()
        teardownTitleObservers()
        guard let group = controller.window?.tabGroup else { return }
        installTabGroupKVO(group)
        installTabTitleObservers()
    }

    /// Handlers run synchronously on main (no `main.async`) so the native strip is hidden in the same
    /// transaction as AppKit's insert. Never call this inline with a group mutation; see `refreshTabBar`.
    private func installTabGroupKVO(_ group: NSWindowTabGroup) {
        let winObs = group.observe(\.windows, options: [.new]) { [weak self] _, _ in
            dispatchPrecondition(condition: .onQueue(.main))
            self?.hideNativeTabStrip()
            self?.refreshTabBar()
        }
        let selObs = group.observe(\.selectedWindow, options: [.new]) { [weak self] _, change in
            dispatchPrecondition(condition: .onQueue(.main))
            self?.refreshTabBar()
            // `windowDidBecomeKey` does not reliably fire on a tab switch inside a group, so focus is
            // restored here. Every controller in the group observes; only the newly selected one acts.
            guard let self,
                  let newWindow = change.newValue.flatMap({ $0 }),
                  newWindow === self.controller.window
            else { return }
            self.controller.restoreTerminalFirstResponderIfNeeded()
        }
        // AppKit re-shows the native strip every time a tab is added.
        let visObs = group.observe(\.isTabBarVisible, options: [.new]) { [weak self] _, change in
            dispatchPrecondition(condition: .onQueue(.main))
            guard change.newValue == true else { return }
            self?.hideNativeTabStrip()
        }
        tabGroupObservers = [winObs, selObs, visObs]
    }

    /// `TerminalView` writes the OSC 0/2 title straight into `window.title`, bypassing the tab refresh paths.
    private func installTabTitleObservers() {
        if let hostWindow = controller.window {
            // Capture `hostWindow` weakly: a queued block would otherwise hold a closing window and post against it.
            controller.titleObserver = hostWindow.observe(\.title, options: [.new]) { [weak self, weak hostWindow] _, _ in
                DispatchQueue.main.async { [weak hostWindow] in
                    guard let hostWindow else { return }
                    self?.refreshTabBar()
                    NotificationCenter.default.post(
                        name: .blackbirdTabTitleChanged,
                        object: hostWindow
                    )
                }
            }
            let tok = NotificationCenter.default.addObserver(
                forName: .blackbirdTabTitleChanged,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                guard
                    let self,
                    let myWindow = self.controller.window,
                    let senderWindow = notification.object as? NSWindow
                else { return }
                if senderWindow === myWindow { return }
                guard
                    let myGroup = myWindow.tabGroup,
                    let theirGroup = senderWindow.tabGroup,
                    myGroup === theirGroup
                else { return }
                // Only the selected tab's strip is on screen; a background strip catches up through the `selectedWindow` KVO.
                guard myGroup.selectedWindow === myWindow else { return }
                self.refreshTabBar()
            }
            controller.titleBroadcastObserver = tok
        }
    }

    private func teardownTitleObservers() {
        controller.titleObserver?.invalidate()
        controller.titleObserver = nil
        if let tok = controller.titleBroadcastObserver {
            NotificationCenter.default.removeObserver(tok)
            controller.titleBroadcastObserver = nil
        }
    }

    func refreshTabBar() {
        guard let window = controller.window else { return }
        // Re-hide on every call: this is the one function that runs on every tab transition.
        hideNativeTabStrip()
        let currentGroup = window.tabGroup
        if currentGroup !== lastObservedTabGroup {
            tabGroupObservers.removeAll()
            lastObservedTabGroup = currentGroup
            let kind = currentGroup == nil ? "detached" : "new group"
            Self.tabsLogger.log("tab-group identity changed (\(kind, privacy: .public)) — resubscribing")
        }
        // Checked unconditionally: `lastObservedTabGroup` is weak, so a deallocated group already
        // reads nil and the identity comparison above can miss the window going standalone.
        if currentGroup == nil {
            teardownTitleObservers()
        }
        // Deferred one runloop turn, never inline: this can run inside the `\.windows` KVO that AppKit
        // fires mid-`addTabbedWindow`, and observing a group while it mutates over-retains the joining window.
        if tabGroupObservers.isEmpty, window.tabGroup != nil {
            DispatchQueue.main.async { [weak self] in
                guard let self,
                      self.tabGroupObservers.isEmpty,
                      !self.controller.isClosing,
                      self.controller.window?.tabGroup != nil else { return }
                self.observeTabGroup()
                self.hideNativeTabStrip()
            }
        }
        let tabCount = window.tabGroup?.windows.count ?? 1
        lastObservedTabCount = tabCount
        if tabCount <= 1 {
            // Single-tab transitions skip `TabStripView.update`, so commit any in-flight rename here.
            controller.titlebarTabBar?.commitAnyInFlightEdit()
            // The strip holds its window list strongly; without this a closed sibling stays retained.
            controller.titlebarTabBar?.clearTabs()
            // Zero the frame too, or AppKit keeps reserving the strip's width and pushes the centered title left.
            controller.titlebarTabBar?.view.isHidden = true
            controller.titlebarTabBar?.view.frame = .zero
            window.titleVisibility = .visible
        } else {
            controller.titlebarTabBar?.view.isHidden = false
            window.titleVisibility = .hidden
            controller.titlebarTabBar?.refresh(
                availableWidth: tabStripWidth(forWindowWidth: window.frame.width))
        }
    }

    /// Width-only relayout for a live resize tick or a tab-group frame push; the full refresh runs at `windowDidEndLiveResize`.
    func relayoutTabStripForWidth() {
        guard let window = controller.window,
              lastObservedTabCount > 1,
              let bar = controller.titlebarTabBar else { return }
        bar.refresh(availableWidth: tabStripWidth(forWindowWidth: window.frame.width))
    }

    func refreshTabBarIfStateChanged() {
        guard let window = controller.window else { return }
        let currentGroup = window.tabGroup
        let currentCount = currentGroup?.windows.count ?? 1
        if currentGroup === lastObservedTabGroup,
           currentCount == lastObservedTabCount {
            return
        }
        refreshTabBar()
    }
}
