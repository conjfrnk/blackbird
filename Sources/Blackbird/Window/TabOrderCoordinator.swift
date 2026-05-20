import AppKit
import os

/// Per-tab-group visual ordering layer on top of AppKit's `NSWindowTabGroup`.
///
/// AppKit owns `tabGroup.windows` (system order: arrival order, modulo close /
/// detach). Physically reordering that array requires detach-then-reattach
/// (`addTabbedWindow(_:ordered:)`) which routes through the same machinery
/// behind the deferred tab-merge flash — so reorder via AppKit produces a
/// brief 36 pt strip animation that the user shouldn't see.
///
/// Instead, the coordinator stores a per-group visual permutation. The
/// pill strip, ⌘1-9, and ⌘⇧] / ⌘⇧[ cycle all consult the coordinator;
/// AppKit's own selection remains coherent because `selectedWindow` is
/// set by window identity (not by index). System order and visual order
/// stay independent — selection / focus / window membership are routed by
/// identity throughout the codebase, so the divergence is invisible to
/// every consumer that doesn't look up windows by position.
///
/// Reconciliation rule on every read: keep stored windows still in
/// `group.windows`, drop the rest (closed / detached / deallocated),
/// then append any `group.windows` entry we haven't seen yet — preserving
/// their relative AppKit order. New tabs therefore arrive at the end of
/// the visual strip, matching how the pill bar appended them before this
/// layer existed.
final class TabOrderCoordinator {

    static let shared = TabOrderCoordinator()

    /// Posted (with `object = NSWindowTabGroup`) after `move(window:to:in:)`
    /// commits a new order. `MainWindowController` listens app-wide and
    /// runs `refreshAllTabBars()` so every sibling strip in the group
    /// repaints the new permutation in the same runloop tick.
    static let orderDidChange = Notification.Name("dev.conjfrnk.blackbird.tabOrderDidChange")

    // `internal` (not `private`) because `reconcile(stored:live:commitTo:)`
    // is itself internal — the test target needs to drive it via the
    // `#if DEBUG` `reconcileForTesting` adapter below, which in turn
    // forwards through `reconcile`. Tightening WeakWindow to private
    // would force `reconcile` to private too, hiding the testable seam.
    internal struct WeakWindow {
        weak var value: NSWindow?
    }

    /// Storage is keyed by `ObjectIdentifier(tabGroup)`. NSWindowTabGroup
    /// is a system class whose lifetime tracks the underlying group —
    /// once empty, AppKit deallocates it and the next read of `tabGroup`
    /// on any window in that group returns a fresh instance with a
    /// different identifier. Stale keys for dead groups are harmless
    /// (the dictionary never grows unbounded in practice; each tab
    /// session is one group) and would be evicted by an explicit
    /// `purge` if it ever became a leak. Not bothering for now.
    private var ordersByGroup: [ObjectIdentifier: [WeakWindow]] = [:]

    private static let logger = Logger(subsystem: "dev.conjfrnk.blackbird",
                                       category: "tabOrder")

    private init() {}

    /// User-visible tab order for `group`. Reconciles storage with the
    /// group's current windows (see file-level rule). Always returns at
    /// least the live windows in some order — empty input → empty out.
    func orderedTabs(for group: NSWindowTabGroup) -> [NSWindow] {
        return reconcile(stored: ordersByGroup[ObjectIdentifier(group)] ?? [],
                         live: group.windows,
                         commitTo: ObjectIdentifier(group))
    }

    /// Move `window` from its current visual position to `newIndex`
    /// (clamped to `[0, count-1]`). No-op if the window isn't in the
    /// group or the index doesn't change order. Posts
    /// `orderDidChange` on commit.
    func move(window: NSWindow, to newIndex: Int, in group: NSWindowTabGroup) {
        var current = orderedTabs(for: group)
        guard let oldIndex = current.firstIndex(where: { $0 === window }) else {
            // Caller asked to reorder a window that's not in `group` after
            // reconciliation — either it never was a member, or it was
            // detached between the gesture's start and its commit. The
            // strip's `mouseUp` shouldn't drive this path (it now guards
            // on `target.tabGroup != nil` first), so reaching this branch
            // means an unexpected call site. Log so the regression is
            // visible without aborting.
            Self.logger.notice("move: window not present in group's visual order after reconcile; ignoring")
            return
        }
        let clamped = max(0, min(newIndex, current.count - 1))
        if clamped == oldIndex { return }
        current.remove(at: oldIndex)
        current.insert(window, at: clamped)
        ordersByGroup[ObjectIdentifier(group)] = current.map(WeakWindow.init)
        NotificationCenter.default.post(name: Self.orderDidChange, object: group)
    }

    /// Visual successor of `window` in `group`, wrapping at the end.
    /// Returns `nil` when `window` isn't in the group or only one tab
    /// exists (cycle has no meaning).
    func nextWindow(after window: NSWindow, in group: NSWindowTabGroup) -> NSWindow? {
        let order = orderedTabs(for: group)
        guard order.count > 1,
              let idx = order.firstIndex(where: { $0 === window }) else { return nil }
        return order[(idx + 1) % order.count]
    }

    /// Visual predecessor of `window` in `group`, wrapping at the start.
    /// Same nil-conditions as `nextWindow`.
    func previousWindow(before window: NSWindow, in group: NSWindowTabGroup) -> NSWindow? {
        let order = orderedTabs(for: group)
        guard order.count > 1,
              let idx = order.firstIndex(where: { $0 === window }) else { return nil }
        return order[(idx - 1 + order.count) % order.count]
    }

    // MARK: - Internal (testable)

    /// Pure reconciliation: stored order projected onto `live`, then any
    /// `live` member not in stored appended in `live`'s order. `commitTo`
    /// is the dictionary key to write the reconciled order back to;
    /// passing it through keeps the function side-effect-explicit so
    /// tests can call it without mutating shared state.
    ///
    /// Internal so `TabOrderCoordinatorTests` can drive every reconcile
    /// edge case without instantiating real NSWindowTabGroups.
    internal func reconcile(stored: [WeakWindow],
                            live: [NSWindow],
                            commitTo key: ObjectIdentifier?) -> [NSWindow] {
        var seen = Set<ObjectIdentifier>()
        var result: [NSWindow] = []
        for entry in stored {
            guard let w = entry.value else { continue }
            if live.contains(where: { $0 === w }) {
                result.append(w)
                seen.insert(ObjectIdentifier(w))
            }
        }
        for w in live where !seen.contains(ObjectIdentifier(w)) {
            result.append(w)
        }
        if let key {
            ordersByGroup[key] = result.map(WeakWindow.init)
        }
        return result
    }

    #if DEBUG
    /// Test hook — drive `reconcile` against a synthetic input pair.
    /// Returns the reconciled identity sequence so a test can assert
    /// order without owning real NSWindow instances long enough to
    /// match against the result.
    internal func reconcileForTesting(stored: [NSWindow?], live: [NSWindow]) -> [NSWindow] {
        let weaks = stored.map { WeakWindow(value: $0) }
        return reconcile(stored: weaks, live: live, commitTo: nil)
    }

    /// Test hook — seed visual order for `group` without going through a
    /// real reorder gesture. Used to set up cycle / move tests.
    internal func setOrderForTesting(_ windows: [NSWindow], in group: NSWindowTabGroup) {
        ordersByGroup[ObjectIdentifier(group)] = windows.map(WeakWindow.init)
    }

    /// Test hook — drop all stored orders so suites don't leak state
    /// into each other. Calls to `orderedTabs` after this rebuild from
    /// `group.windows` alone.
    internal func resetForTesting() {
        ordersByGroup.removeAll()
    }
    #endif
}
