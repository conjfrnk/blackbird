import AppKit
import os

/// Isolated, defensively-guarded helper for neutralizing AppKit's private
/// native tab strip so it doesn't stack on top of Blackbird's custom pill
/// strip AND — critically — so it can't steal mouse events from underneath
/// the pills / the terminal grid.
///
/// NSWindowTabGroup's public API only exposes a read-only `isTabBarVisible`
/// and a `toggleTabBar(_:)` that some macOS builds decline to call when
/// KVO-driven. So we walk the theme frame and find the private native strip
/// by class-name matching (the same approach iTerm2 and WezTerm settle on):
/// any view whose runtime class name contains "TabBar" marks the presence
/// of AppKit's native tab bar somewhere in that subtree.
///
/// FRAME-ZEROING RATIONALE (macOS 26 "Tahoe" regression, RCA
/// docs/rca-tab-behaviors-2026-07-01.md Bug 1): on macOS ≤15, `isHidden =
/// true` alone was sufficient — a hidden view is skipped entirely by
/// AppKit's standard hit-test recursion. On Tahoe the native tab bar was
/// rebuilt on Liquid-Glass / SwiftUI hosting (`NSGlassEffectView`,
/// `_NSCoreHostingView<...>`); empirically (see the probe artifacts cited
/// in the RCA), a HIDDEN `NSTabBar` still answers `hitTest(_:)` — clicks in
/// the reserved 36pt tab-bar band (which sits UNDER visible terminal text,
/// since `TerminalView` deliberately ignores that phantom band — see
/// `TerminalView.titlebarOnlyTopInset`) switch tabs or tear them off, even
/// though nothing is drawn there.
///
/// `isHidden` is proven insufficient on Tahoe, so `hide(in:excluding:)` ALSO
/// zeroes the FRAME of the ANCESTOR that hosts the native tab bar — not the
/// private `NSTabBar`/`NSGlassEffectView`/etc. views themselves, whose own
/// private `hitTest` override is exactly what ignores `isHidden`. The
/// ancestor is a completely generic, un-subclassed `NSView` (AppKit's own
/// internal wrapper for the native tab-bar accessory), so its hit-test
/// recursion is the ordinary, well-documented `NSView` contract: a
/// superview only calls `hitTest` on a subview whose FRAME contains the
/// query point. Zeroing that generic ancestor's frame makes the private
/// `NSTabBar` override unreachable regardless of what it does internally —
/// the fix doesn't depend on (and isn't defeated by a future change to)
/// `NSTabBar`'s own hit-test behavior.
///
/// PRUNE-POINT DEFINITION — a view's subtree is "pure tab-bar content"
/// (eligible to be collapsed as a single unit) iff the view itself is a
/// "TabBar"-classed leaf, OR it has at least one subview and EVERY one of
/// its subviews is ALSO pure. This is deliberately NOT "does this subtree
/// contain a TabBar view ANYWHERE" — that weaker condition is satisfied by
/// essentially every ancestor up to the window's whole content view (since
/// the native tab bar lives SOMEWHERE below it), which would collapse far
/// more than the tab bar. Requiring EVERY child to be pure means a node
/// with even one sibling branch of legitimate content (our own pill strip,
/// the titlebar background, the traffic-light buttons, …) is correctly
/// left alone, and the walk keeps descending through it to find the
/// actual, narrower prune point.
///
/// The `root` passed to `hide(in:excluding:)` is deliberately EXEMPTED from
/// the "subtree is pure" inference — it is pruned only via a direct
/// class-name match, exactly like any other node reached by direct name.
/// This guarantees `hide` can never collapse the exact view the caller
/// passed in wholesale, even in a degenerate tree shape where every one of
/// `root`'s descendants happens to funnel into tab-bar content. That
/// shape can't happen with the real production root (the window's theme
/// frame — the terminal view is always a non-tab-bar sibling), but the
/// guarantee should hold unconditionally rather than by accident of the
/// current tree shape.
///
/// `excluding` MUST include Blackbird's own custom tab-strip view (and any
/// other view that legitimately lives in the same window chrome) so this
/// walk can never hide or collapse our own UI even if some future macOS
/// nests things differently. A view in `excluding` — and everything
/// beneath it — is left completely untouched; the walk does not even
/// recurse into it, and its presence can never make an ancestor "pure"
/// either (an excluded view never counts as pure, so an ancestor that
/// contains one is never fully pure through it).
enum NativeTabStripHider {
    /// `os.Logger` (not `NSLog`) so `privacy: .public` markers actually take
    /// effect. NOT gated on `#if DEBUG` — see `warnIfLeafPrune`'s doc
    /// comment for why this canary must survive in Release.
    private static let logger = Logger(subsystem: "dev.conjfrnk.blackbird", category: "tabs")

    /// Recursively neutralize AppKit's native tab-bar subtree(s) under
    /// `root`, without touching anything in `excluding`. Returns the number
    /// of distinct subtrees neutralized (prune points) — `0` in a
    /// multi-tab window is the caller's canary that AppKit may have
    /// changed its private structure such that no "TabBar"-classed view
    /// exists anywhere reachable from `root`.
    @discardableResult
    static func hide(in root: NSView, excluding: [NSView] = []) -> Int {
        let excludedIDs = Set(excluding.map(ObjectIdentifier.init))
        if excludedIDs.contains(ObjectIdentifier(root)) {
            return 0
        }
        if isTabBarClassed(root) {
            warnIfLeafPrune(root)
            root.isHidden = true
            root.frame = .zero
            return 1
        }
        var matches = 0
        for sub in root.subviews {
            walk(sub, excluded: excludedIDs, matches: &matches)
        }
        return matches
    }

    private static func walk(_ view: NSView, excluded: Set<ObjectIdentifier>, matches: inout Int) {
        if excluded.contains(ObjectIdentifier(view)) {
            // Off-limits subtree — don't touch it, don't look inside it.
            return
        }
        if isPureTabBarSubtree(view, excluded: excluded) {
            matches += 1
            warnIfLeafPrune(view)
            view.isHidden = true
            view.frame = .zero
            return // shallowest safe prune point — don't descend further
        }
        for sub in view.subviews {
            walk(sub, excluded: excluded, matches: &matches)
        }
    }

    /// Log a canary when a prune point is ITSELF "TabBar"-classed (a leaf
    /// prune), rather than a generic, non-"TabBar"-classed ancestor
    /// wrapping one. This is the shape where frame-zeroing may NOT
    /// actually suppress hit-testing: the FRAME-ZEROING RATIONALE (see the
    /// type's doc comment) depends on the prune point's hitTest following
    /// the ordinary `NSView` frame-containment contract, which is exactly
    /// what a private `NSTabBar`'s own overridden hitTest does NOT do
    /// (it's what ignores `isHidden` in the first place, per the RCA). A
    /// leaf prune here means the shallowest PURE ancestor collapsed all
    /// the way down to the interactive view itself — e.g. because a
    /// future macOS nested a non-tab-bar sibling under today's generic
    /// wrapper, making that wrapper no longer "pure". In that shape the
    /// click-hijack this fix targets could silently return with no other
    /// signal (`matches` stays ≥ 1, so the zero-matches canary elsewhere
    /// doesn't fire). NOT gated on `#if DEBUG`: this is a
    /// field-undiagnosable future-macOS-structural-change class, the same
    /// Release-diagnosability rationale as the sibling `tabsLogger`
    /// canaries in `TabGroupObserver` (code review, RCA
    /// docs/rca-tab-behaviors-2026-07-01.md batch).
    private static func warnIfLeafPrune(_ view: NSView) {
        guard isTabBarClassed(view) else { return }
        logger.warning("hide: prune point \(String(describing: type(of: view)), privacy: .public) is itself TabBar-classed (a leaf, not a generic ancestor) — frame-zeroing may not fully suppress hit-testing here; investigate if band clicks are reported again.")
    }

    private static func isTabBarClassed(_ view: NSView) -> Bool {
        String(describing: type(of: view)).contains("TabBar")
    }

    /// See the PRUNE-POINT DEFINITION in the type's doc comment.
    private static func isPureTabBarSubtree(_ view: NSView, excluded: Set<ObjectIdentifier>) -> Bool {
        if excluded.contains(ObjectIdentifier(view)) { return false }
        if isTabBarClassed(view) { return true }
        guard !view.subviews.isEmpty else { return false }
        return view.subviews.allSatisfy { isPureTabBarSubtree($0, excluded: excluded) }
    }
}
