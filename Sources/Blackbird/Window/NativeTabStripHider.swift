import AppKit
import os

/// Neutralizes AppKit's private native tab strip, found by "TabBar" class-name matching.
/// On macOS 26 a hidden `NSTabBar` still answers `hitTest`, so the frame of its generic ancestor is zeroed too.
enum NativeTabStripHider {
    private static let logger = Logger(subsystem: "dev.conjfrnk.blackbird", category: "tabs")

    /// `excluding` must include Blackbird's own tab-strip view; excluded subtrees are never touched or entered.
    /// `root` is pruned only by a direct class-name match, never by the pure-subtree inference.
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
            return
        }
        if isPureTabBarSubtree(view, excluded: excluded) {
            matches += 1
            warnIfLeafPrune(view)
            view.isHidden = true
            view.frame = .zero
            return
        }
        for sub in view.subviews {
            walk(sub, excluded: excluded, matches: &matches)
        }
    }

    /// A "TabBar"-classed prune point has its own `hitTest` override, so zeroing its frame may not suppress hit-testing.
    private static func warnIfLeafPrune(_ view: NSView) {
        guard isTabBarClassed(view) else { return }
        logger.warning("hide: prune point \(String(describing: type(of: view)), privacy: .public) is itself TabBar-classed (a leaf, not a generic ancestor) — frame-zeroing may not fully suppress hit-testing here; investigate if band clicks are reported again.")
    }

    private static func isTabBarClassed(_ view: NSView) -> Bool {
        String(describing: type(of: view)).contains("TabBar")
    }

    /// Pure means "TabBar"-classed, or every subview is pure; "contains a TabBar somewhere" would match every ancestor.
    private static func isPureTabBarSubtree(_ view: NSView, excluded: Set<ObjectIdentifier>) -> Bool {
        if excluded.contains(ObjectIdentifier(view)) { return false }
        if isTabBarClassed(view) { return true }
        guard !view.subviews.isEmpty else { return false }
        return view.subviews.allSatisfy { isPureTabBarSubtree($0, excluded: excluded) }
    }
}
