import AppKit
import Foundation
import BBCore

/// NSAccessibility overrides for `TerminalView`. Kept in a focused
/// extension file so the a11y contract stays visible in one place:
/// role (.staticText when bare, container when the find bar is
/// installed), label ("Terminal"), value (snapshot grid joined with
/// newlines), and the cache that keeps VoiceOver polling cheap.
///
/// The stored state (`a11yCache` and the DEBUG-only
/// `a11ySnapshotOverride`) lives on the class body; see
/// `TerminalView.swift`. Swift requires stored properties on the
/// declaring type, not on extensions — they're marked `internal`
/// rather than `private` so this extension can reach them across the
/// file boundary.
///
/// Audited by terminal-view-2 F1 (cache-key identity), swift-tests-
/// view F1 (leak reap). 3 tests in `AccessibilityTests.swift` pin
/// the contract.
extension TerminalView {

    public override func isAccessibilityElement() -> Bool {
        // When the find bar is installed, declaring ourselves a leaf would
        // hide its text fields and buttons from VoiceOver entirely — AppKit
        // stops descending into subviews of an accessibility-leaf parent.
        // Become a container in that mode; `accessibilityChildren()` below
        // exposes the find bar (and every other subview) so VO can reach
        // them. When the bar is absent, keep the leaf behaviour so VO
        // focus lands on a single "Terminal" element (matches what
        // `testStaticTextRole` pins).
        findBar == nil
    }

    public override func accessibilityRole() -> NSAccessibility.Role? { .staticText }

    public override func accessibilityLabel() -> String? { "Terminal" }

    public override func accessibilityHelp() -> String? {
        "Terminal output. Scroll back to read earlier content."
    }

    public override func accessibilityChildren() -> [Any]? {
        // Only meaningful when we're in container mode (find bar visible).
        // AppKit ignores `accessibilityChildren()` on a leaf, but returning
        // the default (super) here keeps behaviour symmetric in case a
        // future tool inspects the value directly.
        guard let bar = findBar else { return super.accessibilityChildren() }
        // Order matters for VO navigation: bar on top visually, every
        // other subview below. Covers drop-highlight / bell flash / scroll
        // indicator in case any of them ever grow accessibility affordances.
        var kids: [Any] = [bar]
        for sub in subviews where sub !== bar {
            kids.append(sub)
        }
        return kids
    }

    public override func accessibilityValue() -> Any? {
        // Test overrides take precedence so headless tests can inject a
        // deterministic grid without a running BBTerm. Under production
        // builds the #if DEBUG branch compiles out entirely.
        #if DEBUG
        let source: A11ySnapshotSource? = a11ySnapshotOverride ?? currentSnapshot
        #else
        let source: A11ySnapshotSource? = currentSnapshot
        #endif
        guard let source else { return "" }
        let identity = source.a11yIdentity
        if a11yCache.snapshotIdentity == identity {
            return a11yCache.value
        }
        let computed = source.visibleRowsAsText()
            .map { $0.trimmingTrailingWhitespace() }
            .joined(separator: "\n")
        a11yCache.snapshotIdentity = identity
        a11yCache.value = computed
        a11yCache.computations += 1
        return computed
    }

    #if DEBUG
    /// Test introspection for the a11y cache. Lets `AccessibilityTests`
    /// assert that `accessibilityValue()` short-circuits when the
    /// snapshot hasn't changed.
    var accessibilityCacheStatsForTests: (computations: Int, snapshotIdentity: UnsafeRawPointer?) {
        (a11yCache.computations, a11yCache.snapshotIdentity)
    }

    /// Install a fake snapshot that the a11y value path will consume.
    /// Assigns a fresh identity each call so cache invalidation is
    /// exercised.
    func installSnapshotForTests(rows: [String]) {
        a11ySnapshotOverride = A11yFakeSnapshot(rows: rows)
        // New identity ⇒ next accessibilityValue() must recompute.
        a11yCache.snapshotIdentity = nil
    }
    #endif
}
