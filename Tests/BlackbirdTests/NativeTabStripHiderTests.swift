import XCTest
import AppKit
@testable import Blackbird

/// Blind contract tests for `NativeTabStripHider.hide(in:excluding:)`.
///
/// Contract (the only thing these tests rely on — the implementation file
/// is deliberately NOT read, per the project's blind-test rule):
///
///   `@discardableResult`
///   `static func hide(in root: NSView, excluding: [NSView] = []) -> Int`
///
///   1. Walks the tree rooted at `root`, depth-first, considering `root`
///      itself (root is visited, not skipped).
///   2. `excluding` is a hands-off list, compared by REFERENCE IDENTITY
///      (`===`): a view that IS one of the excluded views is never touched
///      (its `isHidden`/`frame` are left alone) AND is never looked inside
///      (none of its descendants are visited/modified), regardless of what
///      they are.
///   3. A view "matches" iff its runtime class name
///      (`String(describing: type(of: view))`) CONTAINS the case-sensitive
///      substring `"TabBar"`.
///   4. A view's subtree is considered to "contain a match" if the view
///      itself matches, or any descendant reachable WITHOUT crossing into
///      an excluded subtree matches.
///   5. Pruning happens at the SHALLOWEST view whose subtree contains a
///      match, and pruning STOPS the walk on that branch:
///        - the prune point gets `isHidden = true` AND `frame = .zero`,
///        - and ONLY the prune point — none of its descendants are touched
///          (they keep their `isHidden`/`frame`, even if they too match),
///        - and the walk does not recurse below a prune point.
///      A match directly under `root` prunes `root`'s relevant CHILD; a
///      match buried under several plain containers prunes the OUTERMOST
///      (shallowest) plain container, not the deep containers below it and
///      not the matching leaf itself. `root` itself becomes a prune point
///      only when `root` itself is a prune point per this rule (e.g. its
///      own class name matches).
///   6. The return value is the COUNT OF PRUNE POINTS (distinct pruned
///      subtrees), NOT the number of individually-matching views. Three
///      matches under one plain wrapper => one prune point => returns 1.
///   7. `root` in `excluding` => returns 0, nothing anywhere is touched
///      (not even matches nested inside `root`).
///   8. A match that only exists inside an excluded subtree can never cause
///      a prune: if the only match in the whole tree is inside an excluded
///      subtree, `hide` returns 0 and modifies nothing.
///   9. `excluding` defaults to `[]`, so `hide(in: root)` is valid and
///      behaves as if nothing is excluded.
///  10. Idempotent: two consecutive identical calls return the same count
///      and leave the tree in the same state (a re-found prune point is
///      re-hidden/re-zeroed as a no-op; no drift, no double-counting).
///
/// Key differentiators from a naive "hide every TabBar-classed view":
///   - only the SHALLOWEST pure ancestor is pruned (deep matches/containers
///     under it stay untouched),
///   - pruning ALSO zeroes `frame` (not just `isHidden`),
///   - the return value counts prune points, not matches,
///   - `excluding` is honoured by reference identity and blocks recursion.
///
/// NOTE ON A CONTRACT AMBIGUITY (flagged for the implementer, who has the
/// real code): the English contract is internally inconsistent about
/// whether a PLAIN `root` (one whose own class name does not match, but
/// whose subtree contains a match) is itself pruned. One clause suggests
/// "root's subtree qualifies as pure => root is the prune point"; the
/// worked examples and the per-test requirements say the shallowest
/// matching CHILD is pruned and a plain `root` is left untouched. These
/// tests encode the latter (plain root untouched; shallowest matching
/// descendant pruned). If the real implementation prunes a plain root
/// whose subtree contains a match, tests (a)/(b)/(c) and the
/// multiple-subtree test will fail and the ambiguity must be resolved.
///
/// Memory + safety budget (per `feedback_test_memory_safety`): synthetic
/// `NSView` instances only — no `NSWindow`, no `MainWindowController`, no
/// PTY/shell. A handful of bare views per test; effectively free, no
/// runloop spins, < 1 ms each.

// MARK: - Synthetic view subclasses (control the runtime class name)

/// Class name contains "TabBar" → matches.
private final class FakeTabBarView: NSView {}

/// Class name contains "TabBar" as a substring (not an exact match) →
/// proves substring, not equality, matching.
private final class MyTabBarStripThing: NSView {}

/// Another "TabBar"-bearing name, to exercise multiple distinct matching
/// classes in one tree.
private final class TabBarAccessory: NSView {}

/// Class name does NOT contain "TabBar" → never matches.
private final class PlainContentView: NSView {}

/// A second plain container, for building nesting that has no matches.
private final class PlainBoxView: NSView {}

final class NativeTabStripHiderTests: XCTestCase {

    // MARK: - Helpers

    /// Distinct, non-zero frame keyed by a seed so that:
    ///  - "untouched" views can be checked against their original frame, and
    ///  - "pruned" views (frame becomes `.zero`) are a *visible* change from
    ///    a non-zero starting frame.
    private func rect(_ seed: CGFloat) -> NSRect {
        NSRect(x: seed, y: seed + 1, width: seed + 100, height: seed + 50)
    }

    @discardableResult
    private func configure<V: NSView>(_ v: V, _ frame: NSRect) -> V {
        v.frame = frame
        XCTAssertFalse(v.isHidden, "Precondition: freshly created views start visible")
        XCTAssertNotEqual(frame, .zero, "Precondition: seed frames must be non-zero so pruning is observable")
        return v
    }

    private func makePlain(_ frame: NSRect) -> PlainContentView {
        configure(PlainContentView(), frame)
    }

    private func assertPruned(
        _ v: NSView, _ label: String,
        file: StaticString = #file, line: UInt = #line
    ) {
        XCTAssertTrue(v.isHidden, "\(label): a prune point must have isHidden == true", file: file, line: line)
        XCTAssertEqual(v.frame, .zero, "\(label): a prune point must have frame == .zero", file: file, line: line)
    }

    private func assertUntouched(
        _ v: NSView, _ original: NSRect, _ label: String,
        file: StaticString = #file, line: UInt = #line
    ) {
        XCTAssertFalse(v.isHidden, "\(label): an untouched view must keep isHidden == false", file: file, line: line)
        XCTAssertEqual(v.frame, original, "\(label): an untouched view must keep its original frame", file: file, line: line)
    }

    // MARK: - (a) Flat match directly under root

    func testFlatMatchUnderRootIsPrunedRootAndSiblingsUntouched() {
        let rootFrame = rect(1)
        let root = makePlain(rootFrame)

        let tabFrame = rect(2)
        let tab = configure(FakeTabBarView(), tabFrame)

        let aFrame = rect(3), bFrame = rect(4)
        let plainA = makePlain(aFrame)
        let plainB = makePlain(bFrame)

        root.addSubview(plainA)
        root.addSubview(tab)
        root.addSubview(plainB)

        let count = NativeTabStripHider.hide(in: root)

        XCTAssertEqual(count, 1, "One prune point: the single matching child")
        assertPruned(tab, "flat matching child")
        assertUntouched(root, rootFrame, "plain root")
        assertUntouched(plainA, aFrame, "plain sibling A")
        assertUntouched(plainB, bFrame, "plain sibling B")
    }

    // MARK: - (b) Match buried deep under plain containers

    func testDeeplyNestedMatchPrunesShallowestContainerLeavingDeeperViewsUntouched() {
        // root -> c1 -> c2 -> c3 -> leaf(match), every container plain.
        let rootFrame = rect(1)
        let c1Frame = rect(2), c2Frame = rect(3), c3Frame = rect(4)
        let leafFrame = rect(5)

        let root = makePlain(rootFrame)
        let c1 = makePlain(c1Frame)
        let c2 = makePlain(c2Frame)
        let c3 = makePlain(c3Frame)
        let leaf = configure(FakeTabBarView(), leafFrame)

        root.addSubview(c1)
        c1.addSubview(c2)
        c2.addSubview(c3)
        c3.addSubview(leaf)

        let count = NativeTabStripHider.hide(in: root)

        XCTAssertEqual(count, 1, "One prune point at the shallowest plain container")
        assertPruned(c1, "shallowest plain container (c1)")

        // The whole point: everything below the prune point is untouched,
        // INCLUDING the matching leaf (isHidden still false, frame intact).
        assertUntouched(root, rootFrame, "plain root")
        assertUntouched(c2, c2Frame, "deeper container c2")
        assertUntouched(c3, c3Frame, "deeper container c3")
        assertUntouched(leaf, leafFrame, "the matching leaf itself")
        XCTAssertFalse(leaf.isHidden, "The deep matching leaf must NOT be hidden — only its ancestor is pruned")
    }

    // MARK: - (c) Several matches under one wrapper => one prune point

    func testThreeMatchesUnderOneWrapperProduceSinglePrunePoint() {
        let rootFrame = rect(1), wrapperFrame = rect(2)
        let t1Frame = rect(3), t2Frame = rect(4), t3Frame = rect(5)

        let root = makePlain(rootFrame)
        let wrapper = makePlain(wrapperFrame)
        let tab1 = configure(FakeTabBarView(), t1Frame)
        let tab2 = configure(MyTabBarStripThing(), t2Frame)
        let tab3 = configure(TabBarAccessory(), t3Frame)

        root.addSubview(wrapper)
        wrapper.addSubview(tab1)
        wrapper.addSubview(tab2)
        wrapper.addSubview(tab3)

        let count = NativeTabStripHider.hide(in: root)

        XCTAssertEqual(count, 1, "Three matches under one wrapper collapse to ONE prune point, not three")
        assertPruned(wrapper, "the single plain wrapper")
        assertUntouched(root, rootFrame, "plain root")
        assertUntouched(tab1, t1Frame, "matching leaf tab1 (below prune point)")
        assertUntouched(tab2, t2Frame, "matching leaf tab2 (below prune point)")
        assertUntouched(tab3, t3Frame, "matching leaf tab3 (below prune point)")
    }

    // MARK: - (d) Zero matches

    func testTreeWithNoMatchesLeavesEverythingUntouched() {
        let rootFrame = rect(1), aFrame = rect(2), bFrame = rect(3), cFrame = rect(4)
        let root = makePlain(rootFrame)
        let a = makePlain(aFrame)
        let b = configure(PlainBoxView(), bFrame)
        let c = makePlain(cFrame)

        root.addSubview(a)
        a.addSubview(b)
        b.addSubview(c)

        let count = NativeTabStripHider.hide(in: root)

        XCTAssertEqual(count, 0, "A tree of only plain views yields no prune points")
        assertUntouched(root, rootFrame, "root")
        assertUntouched(a, aFrame, "a")
        assertUntouched(b, bFrame, "b")
        assertUntouched(c, cFrame, "c")
    }

    // MARK: - (e) Root itself matches

    func testRootItselfMatchingIsPrunedDirectly() {
        let rootFrame = rect(1), childFrame = rect(2)
        let root = configure(FakeTabBarView(), rootFrame)   // root's own class matches
        let plainChild = makePlain(childFrame)
        root.addSubview(plainChild)

        let count = NativeTabStripHider.hide(in: root)

        XCTAssertEqual(count, 1, "A matching root is itself the (only) prune point")
        assertPruned(root, "matching root")
        // Root is the prune point => its descendants are not touched.
        assertUntouched(plainChild, childFrame, "child below the pruned root")
    }

    // MARK: - (f1) Only match lives inside an excluded subtree (rule 8/9)

    func testOnlyMatchInsideExcludedSubtreeCausesNoPruning() {
        let rootFrame = rect(1), exclFrame = rect(2), tabFrame = rect(3)
        let root = makePlain(rootFrame)
        let excludedContainer = makePlain(exclFrame)
        let tab = configure(FakeTabBarView(), tabFrame)

        root.addSubview(excludedContainer)
        excludedContainer.addSubview(tab)

        let count = NativeTabStripHider.hide(in: root, excluding: [excludedContainer])

        XCTAssertEqual(count, 0, "A match reachable only through an excluded subtree must cause no prune")
        assertUntouched(root, rootFrame, "root (its only match is behind an exclusion)")
        assertUntouched(excludedContainer, exclFrame, "excluded container")
        assertUntouched(tab, tabFrame, "match inside the excluded subtree")
    }

    // MARK: - (f2) An unrelated exclusion doesn't affect a separate match

    func testExcludedLeafDoesNotAffectUnrelatedMatchPruning() {
        let rootFrame = rect(1)
        let exclFrame = rect(2)
        let branchFrame = rect(3), tabFrame = rect(4)

        let root = makePlain(rootFrame)
        let excludedLeaf = makePlain(exclFrame)      // plain leaf, excluded, unrelated
        let branchB = makePlain(branchFrame)
        let tab = configure(FakeTabBarView(), tabFrame)

        root.addSubview(excludedLeaf)
        root.addSubview(branchB)
        branchB.addSubview(tab)

        let count = NativeTabStripHider.hide(in: root, excluding: [excludedLeaf])

        XCTAssertEqual(count, 1, "The unrelated exclusion must not suppress a separate, legitimate prune")
        assertPruned(branchB, "branch containing the unrelated match")
        assertUntouched(root, rootFrame, "plain root")
        assertUntouched(excludedLeaf, exclFrame, "excluded (unrelated) leaf")
        assertUntouched(tab, tabFrame, "matching leaf below the pruned branch")
    }

    // MARK: - Exclusion protects a view that WOULD otherwise be pruned (rule 2)

    func testExcludedViewThatItselfMatchesIsNeverPruned() {
        let rootFrame = rect(1), protectedFrame = rect(2), otherFrame = rect(3)
        let root = makePlain(rootFrame)
        let protectedTab = configure(FakeTabBarView(), protectedFrame)   // matches, but excluded
        let otherTab = configure(TabBarAccessory(), otherFrame)          // matches, not excluded

        root.addSubview(protectedTab)
        root.addSubview(otherTab)

        let count = NativeTabStripHider.hide(in: root, excluding: [protectedTab])

        XCTAssertEqual(count, 1, "Only the non-excluded match is a prune point")
        assertUntouched(protectedTab, protectedFrame,
                        "an excluded view is never pruned even though its class name matches")
        assertPruned(otherTab, "the non-excluded matching sibling")
        assertUntouched(root, rootFrame, "plain root")
    }

    // MARK: - (g) Default `excluding` argument

    func testHideWithDefaultExcludingBehavesLikeEmptyArray() {
        // Two structurally identical trees; one called with the default
        // argument, one with an explicit empty array. Results must match.
        let rootFrameA = rect(1), tabFrameA = rect(2)
        let rootA = makePlain(rootFrameA)
        let tabA = configure(MyTabBarStripThing(), tabFrameA)
        rootA.addSubview(tabA)

        let rootFrameB = rect(1), tabFrameB = rect(2)
        let rootB = makePlain(rootFrameB)
        let tabB = configure(MyTabBarStripThing(), tabFrameB)
        rootB.addSubview(tabB)

        let countDefault = NativeTabStripHider.hide(in: rootA)             // default excluding
        let countExplicit = NativeTabStripHider.hide(in: rootB, excluding: [])

        XCTAssertEqual(countDefault, 1, "Default-argument call prunes the single match")
        XCTAssertEqual(countDefault, countExplicit, "hide(in:) must behave identically to excluding: []")
        assertPruned(tabA, "match under default-argument call")
        assertPruned(tabB, "match under explicit-empty call")
        assertUntouched(rootA, rootFrameA, "root under default-argument call")
        assertUntouched(rootB, rootFrameB, "root under explicit-empty call")
    }

    // MARK: - (h) Idempotence

    func testHideIsIdempotentAcrossTwoConsecutiveCalls() {
        let rootFrame = rect(1), wrapperFrame = rect(2), tabFrame = rect(3)
        let root = makePlain(rootFrame)
        let wrapper = makePlain(wrapperFrame)
        let tab = configure(FakeTabBarView(), tabFrame)

        root.addSubview(wrapper)
        wrapper.addSubview(tab)

        let first = NativeTabStripHider.hide(in: root)
        // Capture state after the first call.
        let wrapperHiddenAfterFirst = wrapper.isHidden
        let wrapperFrameAfterFirst = wrapper.frame
        let tabHiddenAfterFirst = tab.isHidden
        let tabFrameAfterFirst = tab.frame

        let second = NativeTabStripHider.hide(in: root)

        XCTAssertEqual(first, 1, "First call has exactly one prune point")
        XCTAssertEqual(second, first, "A second identical call returns the same count (no drift/double-count)")

        XCTAssertEqual(wrapper.isHidden, wrapperHiddenAfterFirst, "Prune-point isHidden must be stable across calls")
        XCTAssertEqual(wrapper.frame, wrapperFrameAfterFirst, "Prune-point frame must be stable across calls")
        XCTAssertEqual(tab.isHidden, tabHiddenAfterFirst, "Below-prune-point isHidden must be stable across calls")
        XCTAssertEqual(tab.frame, tabFrameAfterFirst, "Below-prune-point frame must be stable across calls")

        // And concretely: the wrapper is (still) pruned, the leaf (still) untouched.
        assertPruned(wrapper, "wrapper after two calls")
        assertUntouched(tab, tabFrame, "matching leaf after two calls")
        assertUntouched(root, rootFrame, "root after two calls")
    }

    // MARK: - (i) Root itself excluded (rule 7)

    func testRootInExcludingReturnsZeroAndTouchesNothing() {
        // Root itself matches AND contains a nested match, but is excluded:
        // nothing anywhere may be touched.
        let rootFrame = rect(1), nestedFrame = rect(2)
        let root = configure(FakeTabBarView(), rootFrame)   // matches, but excluded
        let nestedTab = configure(MyTabBarStripThing(), nestedFrame)
        root.addSubview(nestedTab)

        let count = NativeTabStripHider.hide(in: root, excluding: [root])

        XCTAssertEqual(count, 0, "An excluded root yields no prune points")
        assertUntouched(root, rootFrame, "excluded root (never modified, even though it matches)")
        assertUntouched(nestedTab, nestedFrame, "match nested inside an excluded root (never visited)")
    }

    // MARK: - Multiple independent subtrees each produce a prune point

    func testMultipleIndependentSubtreesEachProduceAPrunePoint() {
        let rootFrame = rect(1)
        let aFrame = rect(2), tabAFrame = rect(3)
        let bFrame = rect(4), tabBFrame = rect(5)

        let root = makePlain(rootFrame)
        let branchA = makePlain(aFrame)
        let tabA = configure(FakeTabBarView(), tabAFrame)
        let branchB = makePlain(bFrame)
        let tabB = configure(TabBarAccessory(), tabBFrame)

        root.addSubview(branchA)
        branchA.addSubview(tabA)
        root.addSubview(branchB)
        branchB.addSubview(tabB)

        let count = NativeTabStripHider.hide(in: root)

        XCTAssertEqual(count, 2, "Two independent pure subtrees => two prune points")
        assertPruned(branchA, "shallowest container of branch A")
        assertPruned(branchB, "shallowest container of branch B")
        assertUntouched(root, rootFrame, "plain root")
        assertUntouched(tabA, tabAFrame, "match below branch-A prune point")
        assertUntouched(tabB, tabBFrame, "match below branch-B prune point")
    }
}
