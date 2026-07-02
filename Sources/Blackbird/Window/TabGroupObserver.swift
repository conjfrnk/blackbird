import AppKit
import os

/// Owns a `MainWindowController`'s tab-group observation machinery: the custom
/// titlebar pill-strip install, the `NSWindowTabGroup` KVO (windows
/// add/remove, selection, native-strip re-show), the window-title KVO +
/// same-group title broadcast, and the `refreshTabBar` reconciliation that
/// re-subscribes on tab-group identity changes. Split out of the controller so
/// the ~250 lines of KVO + reconciliation are one cohesive, separately-readable
/// concern.
///
/// `unowned let controller`: the controller owns this (`lazy var`), so its
/// lifetime is a strict subset of the controller's. Every method here runs only
/// while the controller is alive — install during `init`, the KVO/notification
/// callbacks while the window is on screen, `refreshTabBar` from delegate hooks
/// — never from the controller's `deinit`. So the back-ref is never read after
/// teardown.
///
/// LIFETIME NOTE: the `titleObserver` / `titleBroadcastObserver` KVO+token
/// FIELDS stay on `MainWindowController` (not here) because its `deinit`
/// invalidates them inline; an `unowned controller` read during the
/// controller's own `deinit` would trap. This type only manages those fields
/// through the controller while it is alive (`installTabTitleObservers` /
/// `teardownTitleObservers`). The `tabGroupObservers` array DOES live here; its
/// KVO tokens auto-invalidate when this object deallocs alongside the
/// controller — identical timing to when they lived on the controller.
final class TabGroupObserver {
    unowned let controller: MainWindowController

    init(controller: MainWindowController) {
        self.controller = controller
    }

    /// Fallback traffic-light reservation for environments where the live
    /// window-button geometry can't be queried (pre-install, nil window,
    /// non-standard style mask). The live path queries
    /// `standardWindowButton(.zoomButton)` and adds a visual gap —
    /// preferred because Apple nudges the light geometry between macOS
    /// releases (Big Sur, Sonoma both moved them by a few points) and
    /// a hard-coded 75 eventually drifts. Audit titlebar-tabs F11.
    private static let trafficLightsReservationFallback: CGFloat = 75

    /// Visual padding between the zoom button's trailing edge and the
    /// first pill. Matches the 8pt trailingInset used inside the strip
    /// (TabStripView.trailingInset) so the bar reads symmetric to the
    /// eye. Audit titlebar-tabs F11.
    private static let trafficLightsTrailingPadding: CGFloat = 8

    private var tabGroupObservers: [NSKeyValueObservation] = []
    /// Identity of the last tab group we subscribed to. When `window.tabGroup`
    /// becomes a different object (drag-out creates a new standalone-window
    /// group or nil; drag-back-in joins a different group), any KVO tokens
    /// in `tabGroupObservers` are pointed at an instance that no longer
    /// matters. Compare on every `refreshTabBar` and re-subscribe when the
    /// identity changes.
    private var lastObservedTabGroupID: ObjectIdentifier?
    /// Tab count at the last `refreshTabBar` call. Combined with
    /// `lastObservedTabGroupID` in `refreshTabBarIfStateChanged` so
    /// a focus-only transition (⌘-Tab into/out of a single-tab Blackbird
    /// window) skips the full pill-strip rebuild when nothing actually
    /// changed. (main-window F3)
    private var lastObservedTabCount: Int = 0

    /// `os.Logger` (not `NSLog`) so `privacy: .public` markers actually take
    /// effect — `log stream`'s reader otherwise redacts the message body to
    /// `<private>` because NSLog builds its format string at runtime.
    ///
    /// NOT gated on `#if DEBUG`: the conditions this logger is the canary
    /// for (AppKit private "TabBar" view-class drift, tab-group identity
    /// reassignment) are field-undiagnosable in Release. If a future macOS
    /// renames the private class, our strip-hiding silently stops working
    /// and Release users see both the native and the custom strip at once
    /// — we need the log line in production to know it happened.
    /// (audit M-4, sibling pattern of H-2)
    private static let tabsLogger = Logger(subsystem: "dev.conjfrnk.blackbird",
                                           category: "tabs")

    /// Compute the left-side space that must be reserved for the three
    /// traffic-light buttons, measured live from the window's standard
    /// buttons where possible. Falls back to
    /// `trafficLightsReservationFallback` for edge cases (missing
    /// buttons, non-standard style mask). Audit titlebar-tabs F11.
    private func trafficLightsReservation() -> CGFloat {
        guard let window = controller.window else { return Self.trafficLightsReservationFallback }
        // `zoomButton.frame.maxX` is the trailing edge of the zoom
        // button in its superview's coordinate space — which is the
        // titlebar content view, with the button cluster anchored at
        // x≈7. For a standard window the three buttons run x=7..67,
        // so `zoom.frame.maxX` ≈ 67. Adding `trafficLightsTrailingPadding`
        // (8pt) gives ~75, matching the historical constant.
        //
        // Earlier iteration queried `zoom.superview?.frame.maxX`, but
        // the superview on modern macOS is the full titlebar container
        // (the themeFrame / titlebarContainerView), whose frame spans
        // the entire window width — yielding a reservation of ~window
        // width and pushing every tab pill into a tiny sliver on the
        // right. Stick with the button's OWN frame. Audit
        // titlebar-tabs F11.
        let reservation: CGFloat
        if let zoom = window.standardWindowButton(.zoomButton) {
            reservation = zoom.frame.maxX + Self.trafficLightsTrailingPadding
        } else {
            reservation = Self.trafficLightsReservationFallback
        }
        // Guard against a pathological window style mask that returns
        // 0 for the zoom button frame (e.g. a frameless inspector
        // panel). Fall back if the computed reservation is suspicious.
        return reservation > 20 ? reservation : Self.trafficLightsReservationFallback
    }

    // MARK: - Titlebar-integrated tab bar

    /// Attach the custom tab pill strip as a titlebar accessory, and hide
    /// AppKit's default strip-below-titlebar so only one tab UI is visible.
    /// Also wire up KVO on `tabGroup.windows` and `.selectedWindow` so the
    /// pills refresh when tabs are added, removed, or reordered.
    func installTitlebarTabBar() {
        guard let window = controller.window else { return }
        let vc = TitlebarTabBarViewController(window: window)
        window.addTitlebarAccessoryViewController(vc)
        controller.titlebarTabBar = vc
        refreshTabBar()
        // Defer the first "hide native strip" toggle until after the
        // window joins a tab group; tabGroup is nil before show.
        DispatchQueue.main.async { [weak self] in
            self?.hideNativeTabStrip()
            self?.observeTabGroup()
        }
    }

    func hideNativeTabStrip() {
        guard let window = controller.window else { return }
        // Walk the theme frame and neutralize the AppKit-private native tab
        // strip — both visually (isHidden) and for hit-testing (frame
        // zeroed at its hosting ancestor; see NativeTabStripHider's doc
        // comment for why isHidden alone stopped being sufficient on macOS
        // 26 "Tahoe" — RCA docs/rca-tab-behaviors-2026-07-01.md Bug 1).
        // Our OWN accessory view is excluded so this walk can never hide or
        // collapse Blackbird's pill strip.
        if let themeFrame = window.contentView?.superview {
            let excluding = [controller.titlebarTabBar?.view].compactMap { $0 }
            let matches = NativeTabStripHider.hide(in: themeFrame, excluding: excluding)
            // Log when the walker finds zero TabBar-classed views in a
            // multi-tab context. That's the canary for a future macOS
            // that renamed its private view class — our strip-hiding
            // silently stops working and users see both the native and
            // the custom strip at once. os.Logger with `.public` so the
            // message isn't redacted in `log stream`. (main-window F7)
            //
            // The logger now fires in Release too — this canary is the
            // only signal we'd have that AppKit renamed its private
            // class, and a Release-only regression is exactly the case
            // we can't reproduce in dev. (audit M-4)
            let inGroup = (window.tabGroup?.windows.count ?? 1) > 1
            if inGroup, matches == 0 {
                Self.tabsLogger.warning("hideNativeTabStrip: 0 'TabBar' views found in a multi-tab window — AppKit may have renamed its private class; pill + native strip may both be visible.")
            }
        }
    }

    private func observeTabGroup() {
        tabGroupObservers.removeAll()
        // Consolidated tear-down so the three sites (re-subscribe here,
        // detach path in `refreshTabBar`, deinit) share one place. Handles
        // both the KVO token (auto-invalidates on reassignment but explicit
        // is better) and the NotificationCenter token. (main-window F2)
        teardownTitleObservers()
        guard let group = controller.window?.tabGroup else { return }
        installTabGroupKVO(group)
        installTabTitleObservers()
    }

    /// Install the three `NSWindowTabGroup` KVO observers into
    /// `tabGroupObservers` (windows add/remove, selection, native-strip
    /// re-show). Split out of `observeTabGroup`; the teardown + guard stay
    /// there. KVO fires on the mutating thread — `NSWindowTabGroup` mutates
    /// on main — and the handlers touch AppKit views, so each trips a
    /// `dispatchPrecondition(.onQueue(.main))` rather than risk an off-main
    /// layout assertion (audit L-2). Called synchronously (no main.async) so
    /// the native strip is hidden in the same transaction as AppKit's insert
    /// — the async wrappers used to add a one-tick flash on ⌘T.
    private func installTabGroupKVO(_ group: NSWindowTabGroup) {
        // KVO callbacks fire on the thread that mutated the observed
        // property. `NSWindowTabGroup` mutates on main, so these blocks
        // run on main already — the `DispatchQueue.main.async` wrappers
        // used to live here (and inside visObs below) were adding a
        // runloop tick between AppKit showing the native strip and our
        // walker hiding it. That one-tick gap is what the user sees as
        // a flash when opening a new tab: on ⌘T, AppKit inserts the
        // native tab bar + re-lays the window, our async ran on the
        // next tick, and the native strip flickered in for ~8ms. Call
        // the handlers synchronously so the strip is hidden in the
        // same transaction as AppKit's insert.
        let winObs = group.observe(\.windows, options: [.new]) { [weak self] _, _ in
            // KVO is documented to fire on the mutator thread.
            // `NSWindowTabGroup` mutates on main today, but that's an
            // implementation detail Apple could change in a future
            // macOS (Sparkle relaunch sequencing, a private hook, an
            // off-main animation pipeline) — the synchronous calls
            // below into `hideNativeTabStrip` / `refreshTabBar` touch
            // AppKit views and therefore MUST run on main. Trip
            // immediately if the contract ever breaks instead of
            // landing in a hard-to-debug AppKit assertion deep inside
            // a layout pass. Same pattern as the M-12 / M-22 tripwires
            // from prior batches. (audit L-2)
            dispatchPrecondition(condition: .onQueue(.main))
            self?.hideNativeTabStrip()
            self?.refreshTabBar()
        }
        let selObs = group.observe(\.selectedWindow, options: [.new]) { [weak self] _, change in
            dispatchPrecondition(condition: .onQueue(.main))
            self?.refreshTabBar()
            // Drive focus to this tab's TerminalView when WE are the
            // newly-selected tab. Unified focus-restore site for all
            // tab-switch paths: mouse-pill click, ⌘1–9, ⌃⇥ / ⌃⇧⇥, AppKit
            // ⌘⇧] / ⌘⇧[, drag-tab-out / drag-tab-in.
            // `windowDidBecomeKey` covers cross-window-group transitions
            // but does NOT reliably fire on tab-group-internal swaps:
            // AppKit treats the group's representative as still-key and
            // just swaps the underlying NSWindow on display. Without
            // this hook, mouse-pill clicks leave first responder on the
            // source strip view and keystrokes ring NSBeep until the
            // user clicks the content area.
            //
            // Each controller in the group runs its own observer; the
            // identity check below means only the destination's
            // controller fires the restore (instead of every sibling).
            // `change.newValue` is `NSWindow??` (KVO outer optionality
            // plus the property's own `NSWindow?` type) — `flatMap`
            // flattens both layers.
            guard let self,
                  let newWindow = change.newValue.flatMap({ $0 }),
                  newWindow === self.controller.window
            else { return }
            self.controller.restoreTerminalFirstResponderIfNeeded()
        }
        // AppKit re-shows the native strip every time a tab is added. KVO
        // on `isTabBarVisible` lets us flip it back off the moment it
        // happens, before the user ever sees a second tab UI.
        let visObs = group.observe(\.isTabBarVisible, options: [.new]) { [weak self] _, change in
            dispatchPrecondition(condition: .onQueue(.main))
            guard change.newValue == true else { return }
            self?.hideNativeTabStrip()
        }
        tabGroupObservers = [winObs, selObs, visObs]
    }

    /// Install the window-title KVO + the same-tab-group title-broadcast
    /// notification observer, so the custom pill strip stays in sync with the
    /// shell's OSC 0/2 title (which TerminalView writes straight into
    /// `window.title`, bypassing the add/remove/select refresh paths). Split
    /// out of `observeTabGroup`; both are torn down by `teardownTitleObservers`.
    ///
    /// The `titleObserver` / `titleBroadcastObserver` fields live on
    /// `MainWindowController` (its `deinit` invalidates them inline); this
    /// method writes them through the controller while it is alive.
    private func installTabTitleObservers() {
        // When the shell emits OSC 2 / OSC 0, TerminalView writes the new
        // string into window.title — but the custom pill strip doesn't
        // auto-redraw from that (refreshTabBar is only invoked on
        // add/remove/select). Observe title so tab pills stay in sync with
        // the shell's reported title, and broadcast so sibling tabs in the
        // same group also re-read this window's new title when they repaint
        // their own pill (each pill strip lists every tab).
        //
        // The broadcast is scoped to the SAME tab group: a title change in
        // window A only matters for windows that show A's pill. Posting with
        // `object: hostWindow` lets observers compare tab groups and skip
        // both their own posts (already refreshed via the local KVO above)
        // and posts from windows in unrelated tab groups (their pills don't
        // list us). Without this every title change refreshed every window
        // in every group across the app, and the originating window
        // refreshed twice.
        if let hostWindow = controller.window {
            // RW-01 / L-4: capture `hostWindow` weakly inside the
            // dispatched closure. Otherwise an already-queued main.async
            // block holds a strong ref to a window that's mid-close,
            // posting `.blackbirdTabTitleChanged` against it after
            // `teardownTitleObservers()` invalidated the KVO. Recipients
            // safely discard via their nil-tabGroup guards, but the
            // strong hold-open on a closing NSWindow is a hygiene
            // problem and the spurious post wakes every peer's
            // refreshTabBar pointlessly.
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
                // Skip the originating window — already refreshed via its
                // own titleObserver KVO callback.
                if senderWindow === myWindow { return }
                // Skip windows in unrelated tab groups — our pill strip
                // doesn't list any of their tabs.
                guard
                    let myGroup = myWindow.tabGroup,
                    let theirGroup = senderWindow.tabGroup,
                    myGroup === theirGroup
                else { return }
                self.refreshTabBar()
            }
            controller.titleBroadcastObserver = tok
        }
    }

    /// Consolidated tear-down for the title KVO + title-broadcast
    /// notification observer. Invoked on (a) re-subscribing via
    /// `observeTabGroup`, (b) the detach branch in `refreshTabBar` when
    /// the window leaves its tab group. Both run while the controller is
    /// alive; the controller's `deinit` does its own inline cleanup of the
    /// same fields (it cannot call back into this object without an
    /// unowned-in-deinit trap).
    /// Before this existed, (b) left both observers alive pointing at a
    /// now-stale tab group identity — the broadcast observer would then
    /// post on every title change in any group, and every peer window's
    /// filter would do the O(N) work to discard it.
    /// (main-window F2)
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
        // Re-assert native-strip suppression on EVERY call, not just the
        // handful of KVO/key-window paths that used to call it individually
        // (Bug 5 — RCA docs/rca-tab-behaviors-2026-07-01.md). `refreshTabBar`
        // is the one function guaranteed to run on every transition that
        // matters (tab add/close, drag-reorder commit, ⌘T, the external
        // merge/move-to-new-window hook), so re-hiding here closes every gap
        // where a stale KVO token (bound to a now-dead group instance) would
        // otherwise leave the native strip's suppression unrefreshed.
        // Idempotent and cheap (a bounded view-tree walk).
        hideNativeTabStrip()
        // Detect tab-group identity changes. A user dragging a tab out of a
        // window produces a fresh NSWindowTabGroup (or nil on the detached
        // side); dragging back in may join yet another group. KVO tokens in
        // `tabGroupObservers` are bound to a single instance, so a change
        // silently stops selection / add / visibility events on this
        // controller. Clear-and-resubscribe keeps the strip in sync.
        let currentGroupID = window.tabGroup.map(ObjectIdentifier.init)
        if currentGroupID != lastObservedTabGroupID {
            tabGroupObservers.removeAll()
            // Drop the title KVO + broadcast observer on detach so a
            // window dragged out of its group stops re-firing work for
            // its old peers. `observeTabGroup()` will re-install them
            // if/when the window joins a new group. (main-window F2)
            if currentGroupID == nil {
                teardownTitleObservers()
            }
            lastObservedTabGroupID = currentGroupID
            // Release builds also log this transition; tab-group identity
            // change in production is one of the seams where the native
            // strip can re-show silently. (audit M-4)
            let kind = currentGroupID == nil ? "detached" : "new group"
            Self.tabsLogger.log("tab-group identity changed (\(kind, privacy: .public)) — resubscribing")
        }
        // The FIRST window's installTitlebarTabBar runs its async
        // observeTabGroup before any other window joins — so tabGroup is
        // nil at that moment and observers never attach. Subsequent ⌘T
        // calls form a tab group but only the newly-added controller has
        // tabGroup observers. Retry here: every refresh (fired by
        // AppDelegate.refreshAllTabBars on add/remove) now re-attempts to
        // install observers, so once the group exists every controller
        // ends up subscribed and selection KVO fires for all of them.
        if tabGroupObservers.isEmpty, window.tabGroup != nil {
            observeTabGroup()
        }
        let tabCount = window.tabGroup?.windows.count ?? 1
        lastObservedTabCount = tabCount
        if tabCount <= 1 {
            // Commit any in-flight inline rename before hiding the strip.
            // Without this the field survives the transition as a subview
            // of a hidden view and re-appears — over the wrong pill — the
            // next time the cohort grows back to ≥2 tabs. The strip itself
            // guards against stale edits across layout changes (see
            // `TabStripView.update`) but single-tab transitions skip the
            // update path entirely; cover it here. (main-window F8)
            controller.titlebarTabBar?.commitAnyInFlightEdit()
            // Restore the stock single-tab titlebar: title text centered,
            // no custom pill chrome. Hide the accessory view AND collapse
            // its frame to zero so AppKit doesn't keep reserving the strip's
            // last multi-tab width on the right side of the titlebar — that
            // reservation was pushing the centered window title leftward
            // for the rest of the window's life after returning to one tab.
            controller.titlebarTabBar?.view.isHidden = true
            controller.titlebarTabBar?.view.frame = .zero
            window.titleVisibility = .visible
        } else {
            controller.titlebarTabBar?.view.isHidden = false
            // Tab pills carry the title; suppressing the system title
            // avoids stacking 'zsh' twice.
            window.titleVisibility = .hidden
            // Single source of truth for titlebar accessory width math —
            // the tab bar VC just consumes what we give it. `200` floor
            // keeps narrow windows rendering at least something legible
            // in the strip.
            let total = window.frame.width
            let available = max(200, total - trafficLightsReservation())
            controller.titlebarTabBar?.refresh(availableWidth: available)
        }
    }

    /// Like `refreshTabBar()`, but only runs when the tab-group identity
    /// or tab count has changed since the last refresh on this controller.
    /// The common ⌘-Tab path (focus just returns to an existing single
    /// Blackbird window) no longer recomputes pill geometry and kicks a
    /// `setNeedsDisplay` for no reason. Drag-out (tabGroup becomes nil)
    /// and drag-in (new group identity) still trigger the refresh because
    /// both paths move `currentGroupID` or change the count.
    /// (main-window F3)
    func refreshTabBarIfStateChanged() {
        guard let window = controller.window else { return }
        let currentGroupID = window.tabGroup.map(ObjectIdentifier.init)
        let currentCount = window.tabGroup?.windows.count ?? 1
        if currentGroupID == lastObservedTabGroupID,
           currentCount == lastObservedTabCount {
            return
        }
        refreshTabBar()
    }
}
