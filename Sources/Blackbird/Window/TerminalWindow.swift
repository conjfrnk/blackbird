import AppKit
import os

/// `NSWindow` subclass for terminal sessions only. Exists for one reason:
/// to override `selectNextTab(_:)` and `selectPreviousTab(_:)` so ⌘⇧] /
/// ⌘⇧[ cycle in the user-visible (pill) order, not AppKit's internal
/// `tabGroup.windows` arrival order. After a drag-reorder, those two
/// orders diverge; without the override, ⌘⇧] would jump to a tab whose
/// pill sits elsewhere in the strip and the user would lose their place.
///
/// Settings (and any other non-terminal window) keep using plain
/// `NSWindow` — they don't tab and don't need the override.
final class TerminalWindow: NSWindow {

    private static let logger = Logger(subsystem: "dev.conjfrnk.blackbird",
                                       category: "tabs")

    override func selectNextTab(_ sender: Any?) {
        // Two separate fall-throughs:
        //   1. No tabGroup → standalone window, defer to AppKit's no-op
        //      `super.selectNextTab` so behaviour matches a plain
        //      NSWindow.
        //   2. Has a tabGroup but the coordinator can't find us in it →
        //      reconciliation race during a detach/merge transition.
        //      We must NOT call super in this case: super would cycle
        //      against `tabGroup.windows` (arrival order), silently
        //      undermining the entire reason this subclass exists.
        //      Log and abort the cycle; the next ⌘⇧] press will land
        //      after reconciliation has caught up.
        guard let group = tabGroup else {
            super.selectNextTab(sender)
            return
        }
        guard let next = TabOrderCoordinator.shared.nextWindow(after: self, in: group) else {
            Self.logger.notice("selectNextTab: coordinator returned nil for a live tabGroup (likely mid-detach); skipping cycle")
            return
        }
        group.selectedWindow = next
        next.makeKeyAndOrderFront(nil)
    }

    override func selectPreviousTab(_ sender: Any?) {
        guard let group = tabGroup else {
            super.selectPreviousTab(sender)
            return
        }
        guard let prev = TabOrderCoordinator.shared.previousWindow(before: self, in: group) else {
            Self.logger.notice("selectPreviousTab: coordinator returned nil for a live tabGroup (likely mid-detach); skipping cycle")
            return
        }
        group.selectedWindow = prev
        prev.makeKeyAndOrderFront(nil)
    }
}
