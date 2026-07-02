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
    /// different identifier. A dead group's key is therefore never read
    /// again: its entry's weak windows all nil out, but the entry itself
    /// would otherwise linger for the process lifetime. `purgeDeadGroups()`
    /// (run on every reconcile commit) evicts those all-nil entries so the
    /// map tracks only live groups.
    private var ordersByGroup: [ObjectIdentifier: [WeakWindow]] = [:]

    /// One-shot "where did I used to sit" hints for windows that recently
    /// dropped out of some group's visual order (closed, detached, or moved
    /// to another window) — an ARRAY holding weak references, not a
    /// `Dictionary` keyed by `ObjectIdentifier`, specifically so a departed
    /// window's hint can be detected and purged the same way
    /// `ordersByGroup`'s dead-group entries are (a dictionary keyed by a
    /// stale identifier has no way to notice its key's referent is gone).
    ///
    /// Consulted — and removed — the next time that EXACT window shows up
    /// as a newly-seen member of ANY group's `reconcile` (see the
    /// newly-seen-arrival loop below), so a tab that briefly left a group
    /// and came back (RCA docs/rca-tab-behaviors-2026-07-01.md Bug 4) slots
    /// back in near its old neighbor instead of being blindly appended at
    /// the end, matching how new tabs have always arrived. Safe by
    /// construction for a genuinely unrelated later join: the remembered
    /// neighbor must ALSO be present in the destination group's
    /// currently-being-built order for the hint to apply — if it isn't
    /// (the common case for an unrelated join, since the neighbor almost
    /// certainly isn't a member of some other group), the window falls
    /// through to the ordinary newly-seen-arrival append.
    /// A weakly-held window, boxed so it can live inside an enum case
    /// (Swift doesn't allow `weak` directly on an associated value).
    private struct WeakWindowBox {
        weak var value: NSWindow?
    }

    /// Where a returning window should reinsert, relative to its remembered
    /// position. A closed enum instead of a `Bool` + `Optional` pair
    /// (the previous shape) so "was at the front AND had a remembered
    /// neighbor" — representable but never actually constructed — is
    /// statically unrepresentable rather than merely undocumented
    /// (type-design review).
    private enum ReinsertAnchor {
        /// `departed` was at index 0 of its stored order — no left
        /// neighbor ever existed.
        case front
        /// `departed` had a left neighbor at departure time. Boxed/weak:
        /// if that neighbor has since deallocated, or isn't a member of
        /// the destination this window is rejoining, the hint falls
        /// through to an ordinary append rather than inserting anywhere
        /// specific — we no longer know where `departed` belonged.
        case afterNeighbor(WeakWindowBox)
    }
    private struct DepartureHint {
        weak var departed: NSWindow?
        let anchor: ReinsertAnchor
    }
    private var departureHints: [DepartureHint] = []

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
        // No purgeDeadGroups() here: a successful move implies this group is
        // live (we just located `window` in it), and any dead sibling entries
        // are reclaimed at the next `orderedTabs` reconcile commit.
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

    /// Index to select after closing the tab at `closingIndex` within a visual
    /// order of `count` tabs: the right neighbour, or the left neighbour when
    /// closing the last tab. Returns `nil` when there is no surviving neighbour
    /// (`count <= 1`) or the index is out of range. Pure + static so the
    /// close-promotion choice — visual adjacency, not AppKit's arrival-order
    /// auto-promotion — is unit-testable.
    static func neighborIndexAfterClose(closingIndex: Int, count: Int) -> Int? {
        guard count > 1, closingIndex >= 0, closingIndex < count else { return nil }
        return closingIndex + 1 < count ? closingIndex + 1 : closingIndex - 1
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
        for (index, entry) in stored.enumerated() {
            guard let w = entry.value else { continue }
            if live.contains(where: { $0 === w }) {
                result.append(w)
                seen.insert(ObjectIdentifier(w))
            } else {
                // `w` just dropped out of this group's live membership.
                // Remember its immediate left neighbor from the STORED
                // order (not the partial `result` being built) so a later
                // return — to this group or another — can restore its slot
                // instead of appending at the end (Bug 4).
                if index == 0 {
                    departureHints.append(DepartureHint(departed: w, anchor: .front))
                } else {
                    // `stored[index - 1].value` may itself already be nil
                    // (that predecessor also deallocated) — a nil box
                    // value correctly falls through to an ordinary append
                    // on return, since we no longer know where `w`
                    // belonged relative to whatever survives.
                    departureHints.append(DepartureHint(
                        departed: w,
                        anchor: .afterNeighbor(WeakWindowBox(value: stored[index - 1].value))))
                }
            }
        }
        for w in live where !seen.contains(ObjectIdentifier(w)) {
            if let hintIndex = departureHints.firstIndex(where: { $0.departed === w }) {
                let hint = departureHints[hintIndex]
                departureHints.remove(at: hintIndex) // one-shot
                switch hint.anchor {
                case .front:
                    // Debug-level, not `.notice`: this is the EXPECTED,
                    // successful case (a returning tab reclaiming its old
                    // slot), not an anomaly — but the match is a flat,
                    // unscoped-by-group identity lookup, and the only way
                    // to distinguish "restored a genuinely departed tab"
                    // from "coincidentally reunited with an unrelated
                    // window that happens to share the same neighbor
                    // reference" after the fact is a log line (silent-
                    // failure review, RCA docs/rca-tab-behaviors-2026-07-01.md
                    // batch).
                    Self.logger.debug("reconcile: restored departed window to the front of its destination order (hint match)")
                    result.insert(w, at: 0)
                    continue
                case .afterNeighbor(let box):
                    if let neighbor = box.value,
                       let neighborIndex = result.firstIndex(where: { $0 === neighbor }) {
                        Self.logger.debug("reconcile: restored departed window after its remembered neighbor at index \(neighborIndex, privacy: .public) (hint match)")
                        result.insert(w, at: neighborIndex + 1)
                        continue
                    }
                    // Neighbor existed but isn't resolvable in this
                    // destination's order (unrelated join, or the neighbor
                    // itself never made it here) — fall through to the
                    // ordinary newly-seen-arrival append below. Expected/
                    // common case, not logged (matches the pre-fix
                    // behavior exactly).
                }
            }
            result.append(w)
        }
        if let key {
            ordersByGroup[key] = result.map(WeakWindow.init)
            // Opportunistic eviction: a reconcile commit is the natural
            // choke point to drop entries for groups that have since gone
            // fully dead (every weak window nil). Cheap — one entry per
            // live tab session — and the dead group's own key is never
            // read again, so nothing else would ever evict it.
            purgeDeadGroups()
            purgeStaleDepartureHints()
        }
        return result
    }

    /// A departure hint is stale once the window it was tracking has
    /// deallocated (closed for good, never coming back) — mirrors
    /// `purgeDeadGroups()`'s cleanup for `ordersByGroup`. Called on every
    /// reconcile commit so `departureHints` can't grow unbounded across a
    /// long session's worth of tab churn.
    private func purgeStaleDepartureHints() {
        departureHints.removeAll { $0.departed == nil }
    }

    /// A stored entry is dead when every window it tracked has deallocated.
    /// Single source of truth for the "fully-closed group" predicate.
    private static func isDeadGroup(_ weaks: [WeakWindow]) -> Bool {
        !weaks.contains { $0.value != nil }
    }

    /// Evict storage entries whose windows have ALL deallocated — a tab
    /// group fully closed/detached. Entries with ≥1 live window are kept.
    /// Called on every reconcile commit (see `reconcile`). O(stored
    /// groups), which is tiny (one entry per live tab session).
    internal func purgeDeadGroups() {
        ordersByGroup = ordersByGroup.filter { !Self.isDeadGroup($1) }
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
    /// `group.windows` alone. Also drops `departureHints` — a test driving
    /// `reconcileForTesting` (which records hints unconditionally, not
    /// gated on `commitTo`) must not leak a hint into an unrelated later
    /// test.
    internal func resetForTesting() {
        ordersByGroup.removeAll()
        departureHints.removeAll()
    }

    /// Test seam — number of live (non-deallocated) departure hints
    /// currently held. Lets a test assert the one-shot-consume /
    /// purge-on-commit contracts without reaching into the private
    /// `DepartureHint` type.
    internal func departureHintCountForTesting() -> Int {
        departureHints.filter { $0.departed != nil }.count
    }

    // MARK: Dead-group purge seams

    /// Test seam — inject a raw stored entry for `key`, reproducing the
    /// all-nil "dead group" state a closed group decays into (production
    /// never constructs dead entries directly). Lets a purge test set up
    /// deterministic state without owning a real NSWindowTabGroup.
    internal func seedRawForTesting(_ key: ObjectIdentifier, _ weaks: [WeakWindow]) {
        ordersByGroup[key] = weaks
    }

    /// Test seam — the set of group keys currently retained in storage.
    internal func storedGroupKeysForTesting() -> Set<ObjectIdentifier> {
        Set(ordersByGroup.keys)
    }

    /// Test seam — drive the production `reconcile`+commit path (which runs
    /// `purgeDeadGroups()` on commit) with a synthetic `key`, so a test can
    /// assert commit-time purge without owning a real NSWindowTabGroup.
    internal func reconcileCommittingForTesting(key: ObjectIdentifier,
                                                stored: [NSWindow?],
                                                live: [NSWindow]) -> [NSWindow] {
        reconcile(stored: stored.map { WeakWindow(value: $0) },
                  live: live,
                  commitTo: key)
    }
    #endif
}
