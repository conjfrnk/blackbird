import XCTest
import AppKit
@testable import Blackbird

/// Blind contract tests for `NativeTabStripHider.hide(in:)`.
///
/// Contract (the only thing these tests rely on — the implementation file
/// is deliberately NOT read, per the project's blind-test rule):
///
///   `@discardableResult static func hide(in root: NSView) -> Int`
///
///   1. Recursively walks `root` AND every descendant subview, depth-first,
///      INCLUDING `root` itself.
///   2. For every view whose runtime class name —
///      `String(describing: type(of: view))` — CONTAINS the case-sensitive
///      substring `"TabBar"`, it sets `view.isHidden = true`.
///   3. Views without "TabBar" in their class name are left untouched
///      (`isHidden` is not modified).
///   4. Returns the count of views hidden (number of "TabBar" matches in
///      the whole tree).
///   5. Hides via `isHidden = true` ONLY — it must NOT touch any view's
///      `frame`.
///
/// A wrong-but-plausible impl that, say, only scans the direct subviews of
/// `root` (not the whole subtree) would pass the flat-tree test but fail
/// the nested / multi-depth tests. One that zeroed frames would pass the
/// hide/count tests but fail the frame-preservation test.
///
/// Memory + safety budget (per `feedback_test_memory_safety`): synthetic
/// `NSView` instances only — no `NSWindow`, no `MainWindowController`, no
/// PTY/shell. A handful of bare views per test; effectively free, no
/// runloop spins, < 1 ms each.

// MARK: - Synthetic view subclasses (control the runtime class name)

/// Class name contains "TabBar" → should be hidden.
private final class FakeTabBarView: NSView {}

/// Class name contains "TabBar" as a substring (not an exact match) →
/// proves substring, not equality, matching.
private final class MyTabBarStripThing: NSView {}

/// Another "TabBar"-bearing name, used to exercise multiple distinct
/// matching classes in one tree.
private final class TabBarAccessory: NSView {}

/// Class name does NOT contain "TabBar" → must be left alone.
private final class PlainContentView: NSView {}

/// A second plain container, for building nesting that has no matches.
private final class PlainBoxView: NSView {}

final class NativeTabStripHiderTests: XCTestCase {

    // Helper: a fresh plain view, asserted to start visible so each test's
    // pre-state is unambiguous.
    private func makePlain(_ file: StaticString = #file, _ line: UInt = #line) -> PlainContentView {
        let v = PlainContentView()
        XCTAssertFalse(v.isHidden, "Precondition: plain views start visible", file: file, line: line)
        return v
    }

    // MARK: - Flat tree

    func testFlatTreeHidesOnlyTabBarNamedSiblings() {
        let root = makePlain()

        let tab1 = FakeTabBarView()
        let tab2 = MyTabBarStripThing()
        let plainA = makePlain()
        let plainB = makePlain()

        // Mixed siblings directly under root.
        root.addSubview(plainA)
        root.addSubview(tab1)
        root.addSubview(plainB)
        root.addSubview(tab2)

        let hidden = NativeTabStripHider.hide(in: root)

        XCTAssertEqual(hidden, 2, "Exactly the two TabBar-named siblings should be hidden")

        XCTAssertTrue(tab1.isHidden, "FakeTabBarView (contains \"TabBar\") must be hidden")
        XCTAssertTrue(tab2.isHidden, "MyTabBarStripThing (contains \"TabBar\") must be hidden")

        XCTAssertFalse(plainA.isHidden, "PlainContentView must not be hidden")
        XCTAssertFalse(plainB.isHidden, "PlainContentView must not be hidden")
        XCTAssertFalse(root.isHidden, "Plain root must not be hidden")
    }

    // MARK: - Nested tree (match buried deep)

    func testDeeplyNestedTabBarIsFoundAndHidden() {
        // root -> a -> b -> c -> (deep TabBar), all containers plain.
        let root = makePlain()
        let a = makePlain()
        let b = makePlain()
        let c = makePlain()
        let deepTab = FakeTabBarView()

        root.addSubview(a)
        a.addSubview(b)
        b.addSubview(c)
        c.addSubview(deepTab)

        let hidden = NativeTabStripHider.hide(in: root)

        XCTAssertEqual(hidden, 1, "The single deeply-nested TabBar view should be counted")
        XCTAssertTrue(deepTab.isHidden, "A TabBar view buried 4 levels deep must still be hidden")

        for (name, v) in [("root", root), ("a", a), ("b", b), ("c", c)] {
            XCTAssertFalse(v.isHidden, "Plain container \(name) must not be hidden")
        }
    }

    // MARK: - Multiple matches at different depths

    func testMultipleMatchesAcrossDepthsAllHidden() {
        let root = makePlain()

        // Depth 1 match.
        let shallowTab = FakeTabBarView()
        root.addSubview(shallowTab)

        // Depth 2 match under a plain container.
        let mid = makePlain()
        root.addSubview(mid)
        let midTab = MyTabBarStripThing()
        mid.addSubview(midTab)

        // Depth 3 match under two plain containers, plus a plain sibling.
        let branch = makePlain()
        mid.addSubview(branch)
        let plainLeaf = makePlain()
        branch.addSubview(plainLeaf)
        let deepTab = TabBarAccessory()
        branch.addSubview(deepTab)

        let hidden = NativeTabStripHider.hide(in: root)

        XCTAssertEqual(hidden, 3, "All three TabBar matches across depths 1/2/3 should be counted")
        XCTAssertTrue(shallowTab.isHidden, "Depth-1 TabBar match must be hidden")
        XCTAssertTrue(midTab.isHidden, "Depth-2 TabBar match must be hidden")
        XCTAssertTrue(deepTab.isHidden, "Depth-3 TabBar match must be hidden")

        XCTAssertFalse(plainLeaf.isHidden, "Plain leaf must not be hidden")
        XCTAssertFalse(mid.isHidden, "Plain container must not be hidden")
        XCTAssertFalse(branch.isHidden, "Plain container must not be hidden")
        XCTAssertFalse(root.isHidden, "Plain root must not be hidden")
    }

    // MARK: - Zero matches

    func testTreeWithNoTabBarMatchesHidesNothing() {
        let root = makePlain()
        let a = makePlain()
        let b = PlainBoxView()
        let c = makePlain()

        root.addSubview(a)
        a.addSubview(b)
        b.addSubview(c)

        let hidden = NativeTabStripHider.hide(in: root)

        XCTAssertEqual(hidden, 0, "A tree of only plain views should hide nothing")
        for (name, v) in [("root", root), ("a", a), ("b", b), ("c", c)] {
            XCTAssertFalse(v.isHidden, "Plain view \(name) must remain visible")
        }
    }

    // MARK: - Root itself is a TabBar view

    func testRootItselfIsTabBarNamedGetsHiddenAndCounted() {
        // Traversal must include `root` itself.
        let root = FakeTabBarView()
        let plainChild = makePlain()
        root.addSubview(plainChild)

        let hidden = NativeTabStripHider.hide(in: root)

        XCTAssertEqual(hidden, 1, "A TabBar-named root must itself be counted")
        XCTAssertTrue(root.isHidden, "The root view must be hidden when its class name contains \"TabBar\"")
        XCTAssertFalse(plainChild.isHidden, "Plain child of a TabBar root must not be hidden")
    }

    func testRootTabBarPlusNestedTabBarBothCounted() {
        // Root match AND a deeper match — confirms root isn't special-cased
        // out of the count.
        let root = FakeTabBarView()
        let plain = makePlain()
        root.addSubview(plain)
        let nestedTab = MyTabBarStripThing()
        plain.addSubview(nestedTab)

        let hidden = NativeTabStripHider.hide(in: root)

        XCTAssertEqual(hidden, 2, "Both the TabBar root and the nested TabBar should be counted")
        XCTAssertTrue(root.isHidden, "TabBar root must be hidden")
        XCTAssertTrue(nestedTab.isHidden, "Nested TabBar must be hidden")
        XCTAssertFalse(plain.isHidden, "Intervening plain view must not be hidden")
    }

    // MARK: - Frame preservation

    func testHideDoesNotModifyFrame() {
        let root = makePlain()
        let tab = FakeTabBarView()
        let originalFrame = NSRect(x: 1, y: 2, width: 3, height: 4)
        tab.frame = originalFrame
        root.addSubview(tab)

        let hidden = NativeTabStripHider.hide(in: root)

        XCTAssertEqual(hidden, 1, "The single TabBar view should be hidden")
        XCTAssertTrue(tab.isHidden, "The TabBar view must be hidden")
        XCTAssertEqual(
            tab.frame, originalFrame,
            "hide(in:) must hide via isHidden only and must NOT modify the view's frame"
        )
    }

    func testHideDoesNotMutatePlainViewFrames() {
        let root = makePlain()
        let plain = makePlain()
        let plainFrame = NSRect(x: 10, y: 20, width: 30, height: 40)
        plain.frame = plainFrame
        root.addSubview(plain)

        _ = NativeTabStripHider.hide(in: root)

        XCTAssertFalse(plain.isHidden, "Plain view must stay visible")
        XCTAssertEqual(plain.frame, plainFrame, "Plain view's frame must be untouched")
    }

    // MARK: - Idempotence / return-value sanity

    func testHideCalledTwiceReturnsSameCount() {
        let root = makePlain()
        let tab1 = FakeTabBarView()
        let tab2 = TabBarAccessory()
        let plain = makePlain()
        let nested = makePlain()
        let deepTab = MyTabBarStripThing()

        root.addSubview(tab1)
        root.addSubview(plain)
        plain.addSubview(nested)
        nested.addSubview(deepTab)
        root.addSubview(tab2)

        let first = NativeTabStripHider.hide(in: root)
        let second = NativeTabStripHider.hide(in: root)

        XCTAssertEqual(first, 3, "Three TabBar views should be counted on the first call")
        XCTAssertEqual(second, first, "A second call returns the same count (idempotent re-hide)")

        XCTAssertTrue(tab1.isHidden, "All matches should remain hidden after a second call")
        XCTAssertTrue(tab2.isHidden, "All matches should remain hidden after a second call")
        XCTAssertTrue(deepTab.isHidden, "All matches should remain hidden after a second call")
    }
}
