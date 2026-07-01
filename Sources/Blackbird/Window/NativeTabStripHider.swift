import AppKit

/// Isolated, defensively-guarded helper for hiding AppKit's private native tab
/// strip so it doesn't stack on top of Blackbird's custom pill strip.
///
/// NSWindowTabGroup's public API only exposes a read-only `isTabBarVisible` and
/// a `toggleTabBar(_:)` that some macOS builds decline to call when KVO-driven.
/// So we walk the theme frame and hide any view whose class name contains
/// "TabBar" — the same approach iTerm2 and WezTerm settle on. `isHidden` also
/// removes the view's height contribution, so `safeAreaInsets.top` drops back
/// to the titlebar-only value.
///
/// The fragile part — matching an AppKit-PRIVATE view class by string — lives
/// here in one place (REFACTOR.md Area 5: "native tab strip hidden by
/// recursively string-matching private AppKit class names … guaranteed
/// OS-update break"). Concentrating it makes the OS-version risk auditable and,
/// unlike the old instance-method form, unit-testable against a synthetic view
/// tree. `hide(in:)` returns the match count so the caller can fire a canary
/// when a multi-tab window turns up zero matches (a future macOS that renamed
/// the private class).
enum NativeTabStripHider {
    /// Recursively hide every "TabBar"-classed view under `root`. Returns the
    /// number of views hidden — `0` in a multi-tab window is the caller's
    /// canary that AppKit may have renamed its private class.
    ///
    /// Audit L12. Deliberately uses `isHidden = true` ALONE — never
    /// `view.frame = .zero`. Mutating the frame of an AppKit-private view is
    /// fragile against macOS layout changes (a future version that reads the
    /// frame for cached insets / safe-area math could read our zero). The
    /// documented AppKit contract is that hidden views contribute no layout
    /// space and no rendering, which is exactly what we want.
    @discardableResult
    static func hide(in root: NSView) -> Int {
        var matches = 0
        walk(root, matches: &matches)
        return matches
    }

    private static func walk(_ view: NSView, matches: inout Int) {
        let className = String(describing: type(of: view))
        if className.contains("TabBar") {
            matches += 1
            view.isHidden = true
        }
        for sub in view.subviews {
            walk(sub, matches: &matches)
        }
    }
}
