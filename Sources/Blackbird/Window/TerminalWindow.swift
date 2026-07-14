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

    /// Posted after `mergeAllWindows(_:)` or `moveTabToNewWindow(_:)` runs.
    /// `AppDelegate` observes this and sweeps `refreshTabBar()` across every
    /// controller — the only reliable hook for these two AppKit tab-group
    /// actions (both are dispatched via the auto-injected Window-menu items
    /// with `target = nil`, routed to whichever window is key; there is no
    /// other app-level notification for them).
    ///
    /// Why this matters (RCA docs/rca-tab-behaviors-2026-07-01.md X1/X2):
    /// merging a cohort of STANDALONE windows (`tabGroup == nil` beforehand)
    /// gives each of them a group for the first time, but only the KEY
    /// window's controller gets a callback (`windowDidBecomeKey`) — the
    /// other members have no tab-group KVO installed at all (`tabGroup` was
    /// nil when their `observeTabGroup()` last ran) and their strip stays
    /// stale until the user happens to select them. `refreshTabBar()`
    /// already retries the KVO subscription whenever it's called and finds
    /// an empty `tabGroupObservers` array with a live group — so sweeping
    /// every controller through it here both repaints stale strips (Bug 5)
    /// and installs the missing KVO (X1/X2) in one pass.
    static let externalTabActionDidRun = Notification.Name(
        "dev.conjfrnk.blackbird.externalTabActionDidRun")

    /// AppKit settles tab-group membership synchronously within the call in
    /// practice, but the sweep is dispatched to the next runloop turn
    /// anyway — same convention as `AppDelegate.scheduleTabBarRefresh`,
    /// which defers for the same class of tab-group mutation (tab add /
    /// close) so the group has fully settled before every controller
    /// re-reads it.
    ///
    /// Static so `TabMover`'s programmatic `addTabbedWindow` move — the
    /// same class of external tab-group mutation as Merge All Windows —
    /// can fire the identical sweep without owning a TerminalWindow
    /// reference.
    #if DEBUG
    /// Test-only: incremented synchronously each time a sweep is SCHEDULED
    /// (the notification itself posts on a later main-queue turn). Lets the
    /// TabMover no-op tests assert "this action scheduled no sweep" as a
    /// race-free before/after counter comparison with no runloop spin in
    /// between — the previous oracle (0.3 s inverted expectation on the
    /// globally-posted, deliberately-deferred notification) was fulfilled on
    /// slow CI hosts by a PRIOR test's nested-async sweep slipping past a
    /// single main-queue drain (run 29308450697). Absent from release builds.
    static var _sweepScheduleCountForTesting = 0
    #endif

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
        announceExternalTabAction()
    }

    override func moveTabToNewWindow(_ sender: Any?) {
        super.moveTabToNewWindow(sender)
        announceExternalTabAction()
    }

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
