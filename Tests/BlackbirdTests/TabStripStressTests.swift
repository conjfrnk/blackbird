import XCTest
import AppKit
@testable import Blackbird

/// Stress tests for TabStripView after the drag-and-drop removal.
/// Exercises the paths that remain: rapid list/width churn, rapid
/// begin-edit swaps, and the commit-on-list-shape-change invariant.
///
/// Memory budget (per memory feedback_test_memory_safety):
///   - Each NSWindow stub is ~40 KB resident (titled style mask, no
///     backing store materialised on defer:true). We peak at 10 stub
///     windows per test = ~400 KB. Total across every test in this
///     file is <5 MB transient. Safe.
///   - No real MainWindowController instances — per memory
///     feedback_test_real_shell_controllers, only one real controller
///     is allowed per class and that slot already belongs to
///     InlineRenameTests. All windows below are bare NSWindows.
final class TabStripStressTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        TestHostTermination.shared.register()
    }

    private func makeStubWindows(_ count: Int, prefix: String = "t") -> [NSWindow] {
        (0..<count).map { i in
            let w = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
                styleMask: [.titled],
                backing: .buffered,
                defer: true
            )
            w.title = "\(prefix)-\(i)"
            return w
        }
    }

    private func makeStrip(width: CGFloat = 600) -> TabStripView {
        TabStripView(frame: NSRect(x: 0, y: 0, width: width, height: 28))
    }

    // MARK: - List churn

    /// Grow 1 → 10 tabs then shrink 10 → 1, asserting pill geometry
    /// tracks the tab list at every step.
    func test_listGrowThenShrink_pillFramesMatchTabCount() {
        let strip = makeStrip()
        var tabs = makeStubWindows(1)
        strip.update(tabs: tabs, selected: tabs[0], width: 600)
        XCTAssertEqual(strip.pillCountForTesting, 1)

        for i in 1..<10 {
            tabs.append(contentsOf: makeStubWindows(1, prefix: "g\(i)"))
            strip.update(tabs: tabs, selected: tabs[0], width: 600)
            XCTAssertEqual(
                strip.pillCountForTesting, tabs.count,
                "after grow to \(tabs.count), pill count must match"
            )
        }
        while tabs.count > 1 {
            tabs.removeLast()
            strip.update(tabs: tabs, selected: tabs[0], width: 600)
            XCTAssertEqual(
                strip.pillCountForTesting, tabs.count,
                "after shrink to \(tabs.count), pill count must match"
            )
        }
    }

    // MARK: - Width churn

    /// 50 width-only updates while a pill is being edited. In-flight
    /// edits must NOT be committed on width-only updates (pre-fix
    /// regression; main-window F6).
    func test_widthCycle_doesNotCommitInFlightEdit() {
        let strip = makeStrip()
        let tabs = makeStubWindows(3)
        strip.update(tabs: tabs, selected: tabs[0], width: 600)

        var commits = 0
        strip.onCommitRename = { _, _ in commits += 1 }

        strip.beginEditing(pillIndex: 1)
        strip.setEditTextForTesting("wip")

        for step in 0..<50 {
            let width: CGFloat = 200 + CGFloat(step) * 20
            strip.update(tabs: tabs, selected: tabs[0], width: width)
        }
        XCTAssertEqual(commits, 0,
            "50 width-only updates must not commit the in-flight edit")

        strip.commitEditForTesting()
        XCTAssertEqual(commits, 1, "explicit commit fires exactly once")
    }

    // MARK: - Begin-edit chain

    /// `beginEditing` on a different pill while one is already in
    /// flight commits the old one then opens the new one.
    func test_beginEditOnSecondPill_commitsFirst() {
        let strip = makeStrip()
        let tabs = makeStubWindows(3)
        strip.update(tabs: tabs, selected: tabs[0], width: 600)

        var commits: [(NSWindow, String)] = []
        strip.onCommitRename = { commits.append(($0, $1)) }

        strip.beginEditing(pillIndex: 0)
        strip.setEditTextForTesting("alpha")
        strip.beginEditing(pillIndex: 2)
        strip.setEditTextForTesting("gamma")
        strip.commitEditForTesting()

        XCTAssertEqual(commits.count, 2)
        XCTAssertEqual(commits[0].0, tabs[0])
        XCTAssertEqual(commits[0].1, "alpha")
        XCTAssertEqual(commits[1].0, tabs[2])
        XCTAssertEqual(commits[1].1, "gamma")
    }

    // MARK: - Identity-only list change

    /// Same-count list with DIFFERENT NSWindow instances is a
    /// list-shape change (stale-index hazard) and must commit the
    /// in-flight edit against the OLD tabs array. (main-window F6)
    func test_identityOnlyChange_commitsInFlightEdit() {
        let strip = makeStrip()
        let original = makeStubWindows(3, prefix: "orig")
        strip.update(tabs: original, selected: original[0], width: 600)

        var commits: [(NSWindow, String)] = []
        strip.onCommitRename = { commits.append(($0, $1)) }

        strip.beginEditing(pillIndex: 1)
        strip.setEditTextForTesting("middle")

        let replacement = makeStubWindows(3, prefix: "new")
        strip.update(tabs: replacement, selected: replacement[0], width: 600)

        XCTAssertEqual(commits.count, 1,
            "identity-only change must commit in-flight edit")
        XCTAssertEqual(commits[0].0, original[1],
            "commit target is the ORIGINAL window at the edit index")
        XCTAssertEqual(commits[0].1, "middle")
    }

    // MARK: - commitEditIfNeeded

    func test_commitEditIfNeeded_noOpWhenNotEditing() {
        let strip = makeStrip()
        let tabs = makeStubWindows(2)
        strip.update(tabs: tabs, selected: tabs[0], width: 600)

        var commits = 0
        strip.onCommitRename = { _, _ in commits += 1 }
        strip.commitEditIfNeeded()
        XCTAssertEqual(commits, 0)
    }

    func test_commitEditIfNeeded_publishesActiveEdit() {
        let strip = makeStrip()
        let tabs = makeStubWindows(2)
        strip.update(tabs: tabs, selected: tabs[0], width: 600)

        var commits: [(NSWindow, String)] = []
        strip.onCommitRename = { commits.append(($0, $1)) }

        strip.beginEditing(pillIndex: 1)
        strip.setEditTextForTesting("via-ifneeded")
        strip.commitEditIfNeeded()

        XCTAssertEqual(commits.count, 1)
        XCTAssertEqual(commits[0].1, "via-ifneeded")
    }

    // MARK: - Teardown loops (no subview leak)

    /// 20 cycles of `beginEditing` + `cancelEdit` must leave the strip
    /// with zero lingering subviews. Catches the class of bug where
    /// cancel forgets to remove the editField from the view hierarchy.
    func test_repeatedCancelEdit_noSubviewLeak() {
        let strip = makeStrip()
        let tabs = makeStubWindows(2)
        strip.update(tabs: tabs, selected: tabs[0], width: 600)

        for _ in 0..<20 {
            strip.beginEditing(pillIndex: 0)
            strip.cancelEditForTesting()
        }
        XCTAssertEqual(strip.subviews.count, 0,
            "20 beginEditing/cancel cycles must leave 0 subviews")
    }

    /// Same invariant for commit: the editField must be torn down
    /// after every commit, not just every cancel.
    func test_repeatedCommitEdit_noSubviewLeak() {
        let strip = makeStrip()
        let tabs = makeStubWindows(2)
        strip.update(tabs: tabs, selected: tabs[0], width: 600)
        strip.onCommitRename = { _, _ in }

        for i in 0..<20 {
            strip.beginEditing(pillIndex: 0)
            strip.setEditTextForTesting("t-\(i)")
            strip.commitEditForTesting()
        }
        XCTAssertEqual(strip.subviews.count, 0,
            "20 beginEditing/commit cycles must leave 0 subviews")
    }

    // MARK: - Accessibility close routes correctly

    /// Invoking the accessibility "Close Tab" action on pill index 1
    /// fires `onCloseWindow` with the matching window. Regression
    /// pin for the VoiceOver close path — the same closure the hover
    /// `×` click uses.
    func test_accessibilityClose_routesToCorrectWindow() {
        let strip = makeStrip()
        let tabs = makeStubWindows(3, prefix: "c")
        strip.update(tabs: tabs, selected: tabs[0], width: 600)

        var closed: [NSWindow] = []
        strip.onCloseWindow = { closed.append($0) }

        let children = strip.accessibilityChildren() ?? []
        XCTAssertGreaterThanOrEqual(children.count, 4,
            "expected 3 pills + 1 add-button accessibility children")
        guard let pill1 = children[1] as? BBTabPillAccessibilityElement else {
            return XCTFail("pill 1 accessibility element missing")
        }
        let actions = pill1.accessibilityCustomActions() ?? []
        guard let closeAction = actions.first(where: { $0.name == "Close Tab" }) else {
            return XCTFail("pill 1 has no Close Tab action")
        }
        _ = closeAction.handler?()

        XCTAssertEqual(closed, [tabs[1]])
    }

    // MARK: - Accessibility new-tab routes correctly

    /// The trailing `+` button exposes a single press action that
    /// fires `onAddTab`. Pins the VoiceOver new-tab path.
    func test_accessibilityAdd_firesOnAddTab() {
        let strip = makeStrip()
        let tabs = makeStubWindows(2)
        strip.update(tabs: tabs, selected: tabs[0], width: 600)

        var addCount = 0
        strip.onAddTab = { addCount += 1 }

        let children = strip.accessibilityChildren() ?? []
        guard let addButton = children.last as? BBAddTabAccessibilityElement else {
            return XCTFail("last accessibility child must be the + button")
        }
        XCTAssertTrue(addButton.accessibilityPerformPress())
        XCTAssertEqual(addCount, 1)
    }

    // MARK: - Keyboard close + synchronous tabs mutation (M7)

    /// `deleteBackward` routes through `onCloseWindow`, which in
    /// production calls `performClose` → `windowWillClose` →
    /// `refreshAllTabBars` synchronously. The refresh re-enters
    /// `update(tabs:selected:width:)` and shrinks `self.tabs` BEFORE
    /// `deleteBackward` returns. Reading `tabs.count` after the close
    /// (the pre-fix code) clamped against the post-mutation array,
    /// so a close at the rightmost pill could leave `focusedPill`
    /// pointing past the new tail. Pin: snapshot-then-clamp.
    func test_deleteBackward_synchronousTabsMutation_clampsAgainstPriorIndex() {
        let strip = makeStrip()
        let tabs = makeStubWindows(3, prefix: "k")
        strip.update(tabs: tabs, selected: tabs[0], width: 600)
        strip.focusedPillForTesting = 2

        // Simulate the production close path: the close handler
        // synchronously rewrites `tabs` to drop the closing window.
        var observed: [NSWindow] = []
        strip.onCloseWindow = { closing in
            observed.append(closing)
            let remaining = tabs.filter { $0 !== closing }
            strip.update(tabs: remaining, selected: remaining[0], width: 600)
        }

        strip.deleteBackwardForTesting()

        XCTAssertEqual(observed, [tabs[2]],
            "close handler must fire with the focused tab")
        XCTAssertEqual(strip.pillCountForTesting, 2,
            "synchronous refresh must have shrunk the pill array before deleteBackward returned")
        XCTAssertEqual(strip.focusedPillForTesting, 1,
            "focus must clamp to the new tail (index 1), not the pre-close index (2)")
    }

    /// Closing the only remaining tab leaves `focusedPill = nil` —
    /// the post-fix code's empty-tabs branch. (We can't observe a pill
    /// count of 0 directly because `layoutPills` floors at one pill
    /// frame; what we DO assert is that the empty-tabs branch was
    /// chosen, which is observable through `focusedPill = nil`.)
    func test_deleteBackward_lastTab_clearsFocus() {
        let strip = makeStrip()
        let tabs = makeStubWindows(1, prefix: "lone")
        strip.update(tabs: tabs, selected: tabs[0], width: 600)
        strip.focusedPillForTesting = 0

        // Use a sentinel-empty array; the close handler simulates
        // production's collapse-to-nothing case.
        let emptyHandler: (NSWindow) -> Void = { _ in
            strip.update(tabs: [], selected: tabs[0], width: 600)
        }
        strip.onCloseWindow = emptyHandler

        strip.deleteBackwardForTesting()

        XCTAssertNil(strip.focusedPillForTesting,
            "closing the last tab must drop keyboard focus")
    }

    // MARK: - truncatedString binary search measurement budget (M8)

    /// `truncatedString` used to drop one character at a time and
    /// re-measure, an O(N) measurement loop per pill per redraw. A
    /// hostile remote pushing a 2 KB OSC 0/2 title froze the tab bar.
    /// The fix binary-searches the prefix length, so the per-frame
    /// cost is O(log N) — pin the measurement count budget.
    func test_truncatedString_binarySearchMeasurementCount() {
        let n = 1024
        let title = String(repeating: "x", count: n)
        var measureCalls = 0
        // Each "x" is 7 pt at the title font; budget the pill at half
        // the natural width so a strict prefix is the only fit.
        let result = TabStripView.truncatedString(
            title,
            fitting: 200,
            measure: { _ in
                measureCalls += 1
                // Make every probe the same: full-string measurement
                // is a function of length.
                return CGFloat(2_000)
            }
        )
        XCTAssertTrue(result.hasSuffix("…"),
            "long-title path must produce an ellipsis-suffixed prefix")
        // Allow a small constant of slack for the early "does the full
        // string fit" probe and the lo=hi exit. log2(1024) = 10.
        XCTAssertLessThanOrEqual(measureCalls, 14,
            "binary search must not exceed log₂(N) + small constant measurements (got \(measureCalls))")
    }

    /// With a generous width the full title must fit untouched (the
    /// early-out path measure-once branch). Asserts no spurious
    /// truncation when there's room.
    func test_truncatedString_fitsUntouchedWhenRoomy() {
        var measureCalls = 0
        let title = "abc"
        let result = TabStripView.truncatedString(
            title,
            fitting: 10_000,
            measure: { _ in measureCalls += 1; return 10 }
        )
        XCTAssertEqual(result, title,
            "title that fits must round-trip unchanged")
        XCTAssertEqual(measureCalls, 1,
            "fits-cleanly path must measure exactly once")
    }

    // MARK: - Rapid update under active edit

    /// Mixed width + identity churn under an active edit: one
    /// width-only update (no commit), then an identity change
    /// (commit). Exercises the `listShapeChanged` detector boundary.
    func test_mixedChurn_underEdit_commitsExactlyOnce() {
        let strip = makeStrip()
        let original = makeStubWindows(3, prefix: "a")
        strip.update(tabs: original, selected: original[0], width: 600)

        var commits: [(NSWindow, String)] = []
        strip.onCommitRename = { commits.append(($0, $1)) }

        strip.beginEditing(pillIndex: 2)
        strip.setEditTextForTesting("pre-churn")

        // Width-only: no commit.
        strip.update(tabs: original, selected: original[0], width: 420)
        XCTAssertEqual(commits.count, 0)

        // Identity change: commit against original tabs[2].
        let replaced = makeStubWindows(3, prefix: "b")
        strip.update(tabs: replaced, selected: replaced[0], width: 420)
        XCTAssertEqual(commits.count, 1)
        XCTAssertEqual(commits[0].0, original[2])
        XCTAssertEqual(commits[0].1, "pre-churn")
    }
}
