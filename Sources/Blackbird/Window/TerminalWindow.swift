import AppKit
import os

/// Cycles ⌘⇧] / ⌘⇧[ in pill order rather than AppKit's `tabGroup.windows` arrival order.
final class TerminalWindow: NSWindow {

    private static let logger = Logger(subsystem: "dev.conjfrnk.blackbird",
                                       category: "tabs")

    /// AppKit posts no app-level notification for Merge All Windows or Move Tab to New Window,
    /// and only the key window's controller gets a callback, so every controller is swept.
    static let externalTabActionDidRun = Notification.Name(
        "dev.conjfrnk.blackbird.externalTabActionDidRun")

    #if DEBUG
    static var _sweepScheduleCountForTesting = 0
    #endif

    /// Posts on the next runloop turn so the tab group has settled before controllers re-read it.
    static func postExternalTabActionSweep() {
        #if DEBUG
        _sweepScheduleCountForTesting += 1
        #endif
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: Self.externalTabActionDidRun, object: nil)
        }
    }

    private func announceExternalTabAction() {
        Self.postExternalTabActionSweep()
    }

    override func mergeAllWindows(_ sender: Any?) {
        super.mergeAllWindows(sender)
        // A merge fires no resize; without this push the merged tabs keep a stale PTY winsize.
        (windowController as? MainWindowController)?.syncFrameToSiblingTabs()
        announceExternalTabAction()
    }

    override func moveTabToNewWindow(_ sender: Any?) {
        super.moveTabToNewWindow(sender)
        announceExternalTabAction()
    }

    /// Returns `true` when the caller should invoke `super` (standalone window). With a live group the
    /// coordinator cannot place us in, never call `super`: it cycles in `tabGroup.windows` arrival order.
    private func cycle(
        _ caller: StaticString = #function,
        toNeighbor neighbor: (NSWindow, NSWindowTabGroup) -> NSWindow?
    ) -> Bool {
        guard let group = tabGroup else { return true }
        guard let target = neighbor(self, group) else {
            Self.logger.notice("\(caller): coordinator returned nil for a live tabGroup (likely mid-detach); skipping cycle")
            return false
        }
        group.selectedWindow = target
        target.makeKeyAndOrderFront(nil)
        return false
    }

    override func selectNextTab(_ sender: Any?) {
        if cycle(toNeighbor: { TabOrderCoordinator.shared.nextWindow(after: $0, in: $1) }) {
            super.selectNextTab(sender)
        }
    }

    override func selectPreviousTab(_ sender: Any?) {
        if cycle(toNeighbor: { TabOrderCoordinator.shared.previousWindow(before: $0, in: $1) }) {
            super.selectPreviousTab(sender)
        }
    }
}
