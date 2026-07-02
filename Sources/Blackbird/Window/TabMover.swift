import AppKit
import os

/// representedObject payload for the tab-move context-menu items. Windows
/// are held weakly: a window CAN die between menu build and action fire
/// (a shell-exit `performClose` queued on the main queue lands once menu
/// tracking's runloop mode ends), and a nil'd reference must be a logged
/// no-op, not a dangling pointer.
@MainActor
final class TabMoveRequest: NSObject {

    /// A weakly-held window, boxed so it can live inside an enum case
    /// (Swift doesn't allow `weak` directly on an associated value) —
    /// same shape as `TabOrderCoordinator.WeakWindowBox`.
    final class WeakWindow {
        private(set) weak var value: NSWindow?
        init(_ value: NSWindow) { self.value = value }
    }

    /// Where the tab is going. A closed enum instead of an Optional
    /// destination window so "detach to a new window" (deliberately no
    /// destination) and "the destination deallocated since menu build"
    /// (weak-zeroed box) are different states — with a nil-overloaded
    /// Optional the two were indistinguishable at fire time and a wiring
    /// bug would be mislabeled in the log as a benign race
    /// (type-design review; `ReinsertAnchor` precedent in
    /// TabOrderCoordinator.swift).
    enum Destination {
        /// Detach the tab into its own standalone window.
        case newWindow
        /// Splice the tab into this window's tab group.
        case toWindow(WeakWindow)
    }

    private(set) weak var tab: NSWindow?
    let destination: Destination

    init(tab: NSWindow, destination: Destination) {
        self.tab = tab
        self.destination = destination
    }
}

/// Programmatic move-a-tab-between-windows engine + the NSMenuItem action
/// target for the pill context menu's move items (RCA
/// docs/rca-tab-behaviors-2026-07-01.md Bug 6: the menu-based affordance;
/// pill drag-out/drag-in is a possible later layer on top of this).
///
/// A singleton because `NSMenuItem.target` is weak — the items built in
/// `TabStripView.menu(for:)` need a target that outlives menu tracking.
@MainActor
final class TabMover: NSObject {

    static let shared = TabMover()

    /// Compiler-enforced singleton (matches `TabOrderCoordinator`):
    /// `NSMenuItem.target` is weak, so a menu item wired to a freshly
    /// constructed `TabMover()` would go dead the moment the constructor's
    /// scope ends — exactly the failure the singleton exists to prevent.
    private override init() {}

    private static let logger = Logger(subsystem: "dev.conjfrnk.blackbird",
                                       category: "tabMove")

    #if DEBUG
    /// Test seam — visibility oracle override. Headless xctest must NEVER
    /// `orderFront` real windows (it destabilizes the shared host: AppKit's
    /// visible-window tab-merge animation + key-window churn dereference
    /// half-released state in later tests — the long-standing rule
    /// documented in `TabOrderCoordinatorTests.makeGroup`, re-confirmed by
    /// crash Blackbird-2026-07-02-143902.ips). Tests inject a synthetic
    /// visibility answer instead; production always reads `isVisible`.
    static var _isVisibleForTesting: ((NSWindow) -> Bool)?
    #endif

    /// The one visibility read every eligibility decision goes through.
    private static func isVisible(_ window: NSWindow) -> Bool {
        #if DEBUG
        if let probe = _isVisibleForTesting { return probe(window) }
        #endif
        return window.isVisible
    }

    #if DEBUG
    /// Test seam — suppress `moveTab`'s final `makeKeyAndOrderFront`.
    /// Making a window key / ordering it front is the other half of the
    /// headless-host prohibition above; the group-membership, selection,
    /// and sweep effects the tests assert are unaffected.
    static var _suppressPresentationForTesting = false
    #endif

    /// Whether `moveTab` should present the moved tab (key + front).
    private static var shouldPresentMovedTab: Bool {
        #if DEBUG
        return !_suppressPresentationForTesting
        #else
        return true
        #endif
    }

    // MARK: - Destinations

    /// Pure eligibility predicate for a move destination. Terminal windows
    /// only (Settings / About / Sparkle panels can't host tabs), visible
    /// only (a miniaturized window would swallow the tab into the Dock
    /// unseen), and not fullscreen (v1 safety: the fullscreen
    /// entry/reconfigure path is sensitive — see the frame-save
    /// suppression in c243128 — so fullscreen windows sit this feature
    /// out rather than risk a mid-Space tab splice).
    static func destinationEligible(isTerminalWindow: Bool,
                                    isVisible: Bool,
                                    styleMask: NSWindow.StyleMask) -> Bool {
        isTerminalWindow && isVisible && !styleMask.contains(.fullScreen)
    }

    /// One representative window per eligible destination, in `candidates`
    /// order (first occurrence of a group claims its position). Excludes
    /// `tab` itself and every member of `tab`'s current group — moving a
    /// tab "to" its own group is a no-op the menu shouldn't offer.
    ///
    /// Grouped candidates dedupe by `tabGroup` identity; the representative
    /// is the group's `selectedWindow` when that window is itself eligible
    /// (its title is what the user sees front on that window), otherwise
    /// the first eligible member encountered. Standalone (`tabGroup ==
    /// nil`) windows each stand for themselves.
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
                // Prefer the group's selected window as the face of the
                // destination — but only when it is itself eligible (it
                // could be the fullscreen member of a mixed group in some
                // future AppKit behavior; don't hand the menu an
                // ineligible window).
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

    /// Detach `tab` from its group into its own standalone window.
    /// Delegates to AppKit's `NSWindow.moveTabToNewWindow(_:)` — the
    /// `TerminalWindow` override posts the app-wide refresh sweep, so
    /// source-group strips repaint and the hidden-native-strip hider
    /// re-asserts (RCA Bug 5 path).
    func moveTabToNewWindow(_ tab: NSWindow) {
        guard let group = tab.tabGroup, group.windows.count > 1 else {
            Self.logger.notice("moveTabToNewWindow: tab has no siblings to detach from; ignoring")
            return
        }
        if !(tab is TerminalWindow) {
            // The refresh sweep rides the TerminalWindow.moveTabToNewWindow
            // override; a plain-NSWindow caller detaches fine but leaves
            // every sibling strip stale — exactly the Bug-5 class this
            // machinery exists to fix. No such caller exists today; the
            // canary is for the future one. (silent-failure review)
            Self.logger.notice("moveTabToNewWindow: tab is not a TerminalWindow — the detach refresh sweep will NOT fire")
        }
        tab.moveTabToNewWindow(nil)
    }

    /// Move `tab` into `destination`'s tab group, select it there, and
    /// make it key — native drag semantics: focus follows the tab.
    func moveTab(_ tab: NSWindow, toWindow destination: NSWindow) {
        guard tab !== destination else {
            Self.logger.notice("moveTab: tab and destination are the same window; ignoring")
            return
        }
        if let sourceGroup = tab.tabGroup, sourceGroup === destination.tabGroup {
            Self.logger.notice("moveTab: tab already belongs to the destination's group; ignoring")
            return
        }
        // Re-validate at fire time, not just menu-build time: the
        // destination can change state between the two (enter fullscreen,
        // miniaturize, close-but-stay-retained) — the weak payload refs
        // only catch deallocation, not state, and a future drag-in layer
        // would call this engine with no build-time filter at all (TOCTOU;
        // type-design + silent-failure reviews). Without this, a move into
        // an ordered-out window makes the tab vanish from the screen with
        // its shell session unreachable.
        guard Self.destinationEligible(
            isTerminalWindow: destination is TerminalWindow,
            isVisible: Self.isVisible(destination),
            styleMask: destination.styleMask
        ) else {
            Self.logger.notice("moveTab: destination is no longer an eligible move target (visible=\(Self.isVisible(destination), privacy: .public), fullscreen=\(destination.styleMask.contains(.fullScreen), privacy: .public)); ignoring")
            return
        }
        // The SOURCE side of the same v1 fullscreen rule: the pill strip is
        // reachable in native fullscreen (titlebar accessories reveal with
        // the menu bar), and splicing a tab OUT of a fullscreen group
        // across Spaces is the same sensitive path as splicing into one.
        // The menu also filters this at build time; both layers log.
        guard !tab.styleMask.contains(.fullScreen) else {
            Self.logger.notice("moveTab: tab belongs to a fullscreen window — cross-window moves sit out fullscreen (v1); ignoring")
            return
        }
        // `addTabbedWindow` removes the window from its old group as a side
        // effect (a window belongs to at most one tab group).
        destination.addTabbedWindow(tab, ordered: .above)
        // Post-condition, not assumption: `addTabbedWindow` is a request —
        // AppKit can decline it (tabbingMode.disallowed, odd window
        // states). Selecting / sweeping anyway would launder the refusal
        // into a consistent-looking repaint with zero evidence anything
        // failed. (silent-failure review; same shape as TerminalWindow.cycle's
        // coordinator-disagreement canary.)
        guard let group = tab.tabGroup, group === destination.tabGroup else {
            Self.logger.notice("moveTab: addTabbedWindow did not join the tab to the destination's group; skipping select/sweep")
            return
        }
        group.selectedWindow = tab
        if Self.shouldPresentMovedTab {
            tab.makeKeyAndOrderFront(nil)
        }
        // The destination may have been standalone a moment ago — no
        // tab-group KVO installed at all (the X1/X2 standalone-merge gap).
        // The app-wide sweep is the one reliable refresh for that case,
        // same as AppKit's own Merge All Windows path.
        TerminalWindow.postExternalTabActionSweep()
    }

    // MARK: - Menu action

    /// The one selector every move menu item fires. Routing on the
    /// payload's `Destination` enum (rather than pairing two selectors
    /// with an Optional destination) makes a selector/payload mismatch
    /// unrepresentable and keeps "detach on purpose" distinguishable from
    /// "destination died since menu build" — each failure logs as what it
    /// actually is.
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
