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

    /// Shared body of selectNextTab/selectPreviousTab. Two fall-throughs:
    ///   1. No tabGroup → standalone window. Returns `true` so the caller
    ///      defers to AppKit's no-op `super` (plain-NSWindow behaviour).
    ///   2. Has a tabGroup but the coordinator can't find us in it →
    ///      reconciliation race during a detach/merge. We must NOT call super
    ///      here — super cycles against `tabGroup.windows` (arrival order),
    ///      silently undermining the entire reason this subclass exists — so we
    ///      log, abort the cycle, and return `false`. The next ⌘⇧] / ⌘⇧[ lands
    ///      after reconciliation catches up.
    /// `caller` defaults to the overriding method's name for an accurate log.
    /// Returns `true` ⇔ the caller should invoke `super`.
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
