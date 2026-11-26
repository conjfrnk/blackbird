import AppKit
import os

/// Windows are held weakly: a window can die between menu build and action fire.
@MainActor
final class TabMoveRequest: NSObject {

    final class WeakWindow {
        private(set) weak var value: NSWindow?
        init(_ value: NSWindow) { self.value = value }
    }

    enum Destination {
        case newWindow
        case toWindow(WeakWindow)
    }

    private(set) weak var tab: NSWindow?
    let destination: Destination

    init(tab: NSWindow, destination: Destination) {
        self.tab = tab
        self.destination = destination
    }
}

/// A singleton because `NSMenuItem.target` is weak: the move items need a target that outlives menu tracking.
@MainActor
final class TabMover: NSObject {

    static let shared = TabMover()

    private override init() {}

    private static let logger = Logger(subsystem: "dev.conjfrnk.blackbird",
                                       category: "tabMove")

    #if DEBUG
    static var _isVisibleForTesting: ((NSWindow) -> Bool)?
    #endif

    private static func isVisible(_ window: NSWindow) -> Bool {
        #if DEBUG
        if let probe = _isVisibleForTesting { return probe(window) }
        #endif
        return window.isVisible
    }

    #if DEBUG
    static var _suppressPresentationForTesting = false
    #endif

    private static var shouldPresentMovedTab: Bool {
        #if DEBUG
        return !_suppressPresentationForTesting
        #else
        return true
        #endif
    }

    // MARK: - Destinations

    /// Visible only: a miniaturized window would swallow the tab into the Dock unseen.
    static func destinationEligible(isTerminalWindow: Bool,
                                    isVisible: Bool,
                                    styleMask: NSWindow.StyleMask) -> Bool {
        isTerminalWindow && isVisible && !styleMask.contains(.fullScreen)
    }

    /// One representative window per eligible destination group, in `candidates` order; excludes
    /// `tab` and its own group. The representative is the group's `selectedWindow` when eligible.
    static func moveDestinations(for tab: NSWindow,
                                 among candidates: [NSWindow]) -> [NSWindow] {
        let sourceGroup = tab.tabGroup
        var seenGroups = Set<ObjectIdentifier>()
        var result: [NSWindow] = []
        for candidate in candidates {
            guard destinationEligible(
                isTerminalWindow: candidate is TerminalWindow,
                isVisible: isVisible(candidate),
                styleMask: candidate.styleMask
            ) else { continue }
            guard candidate !== tab else { continue }
            if let group = candidate.tabGroup {
                if let sourceGroup, group === sourceGroup { continue }
                let key = ObjectIdentifier(group)
                guard !seenGroups.contains(key) else { continue }
                seenGroups.insert(key)
                let selected = group.selectedWindow
                if let selected,
                   destinationEligible(
                       isTerminalWindow: selected is TerminalWindow,
                       isVisible: isVisible(selected),
                       styleMask: selected.styleMask
                   ) {
                    result.append(selected)
                } else {
                    result.append(candidate)
                }
            } else {
                result.append(candidate)
            }
        }
        return result
    }

    // MARK: - Moves

    func moveTabToNewWindow(_ tab: NSWindow) {
        guard let group = tab.tabGroup, group.windows.count > 1 else {
            Self.logger.notice("moveTabToNewWindow: tab has no siblings to detach from; ignoring")
            return
        }
        if !(tab is TerminalWindow) {
            // The refresh sweep rides the `TerminalWindow.moveTabToNewWindow` override; a plain
            // `NSWindow` detaches but leaves every sibling strip stale.
            Self.logger.notice("moveTabToNewWindow: tab is not a TerminalWindow — the detach refresh sweep will NOT fire")
        }
        tab.moveTabToNewWindow(nil)
    }

    func moveTab(_ tab: NSWindow, toWindow destination: NSWindow) {
        guard tab !== destination else {
            Self.logger.notice("moveTab: tab and destination are the same window; ignoring")
            return
        }
        if let sourceGroup = tab.tabGroup, sourceGroup === destination.tabGroup {
            Self.logger.notice("moveTab: tab already belongs to the destination's group; ignoring")
            return
        }
        // Re-validate at fire time: the weak payload refs catch deallocation, not a state change
        // (fullscreen, miniaturize, closed-but-retained) since menu build.
        guard Self.destinationEligible(
            isTerminalWindow: destination is TerminalWindow,
            isVisible: Self.isVisible(destination),
            styleMask: destination.styleMask
        ) else {
            Self.logger.notice("moveTab: destination is no longer an eligible move target (visible=\(Self.isVisible(destination), privacy: .public), fullscreen=\(destination.styleMask.contains(.fullScreen), privacy: .public)); ignoring")
            return
        }
        // The pill strip is reachable in native fullscreen (titlebar accessories reveal with the menu bar).
        guard !tab.styleMask.contains(.fullScreen) else {
            Self.logger.notice("moveTab: tab belongs to a fullscreen window — cross-window moves sit out fullscreen (v1); ignoring")
            return
        }
        // `addTabbedWindow` removes the window from its old group as a side effect.
        destination.addTabbedWindow(tab, ordered: .above)
        // `addTabbedWindow` is a request AppKit can decline; confirm membership before select and sweep.
        guard let group = tab.tabGroup, group === destination.tabGroup else {
            Self.logger.notice("moveTab: addTabbedWindow did not join the tab to the destination's group; skipping select/sweep")
            return
        }
        group.selectedWindow = tab
        if Self.shouldPresentMovedTab {
            tab.makeKeyAndOrderFront(nil)
        }
        // A destination that was standalone has no tab-group KVO installed; the app-wide sweep covers it.
        TerminalWindow.postExternalTabActionSweep()
    }

    // MARK: - Menu action

    @objc func moveTabAction(_ sender: NSMenuItem) {
        guard let request = sender.representedObject as? TabMoveRequest else {
            Self.logger.notice("moveTabAction: sender carries no TabMoveRequest — mis-wired menu item; ignoring")
            return
        }
        guard let tab = request.tab else {
            Self.logger.notice("moveTabAction: tab died between menu build and action; ignoring")
            return
        }
        switch request.destination {
        case .newWindow:
            moveTabToNewWindow(tab)
        case .toWindow(let box):
            guard let destination = box.value else {
                Self.logger.notice("moveTabAction: destination died between menu build and action; ignoring")
                return
            }
            moveTab(tab, toWindow: destination)
        }
    }
}
