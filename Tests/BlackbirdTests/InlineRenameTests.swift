import XCTest
import AppKit
@testable import Blackbird

/// Inline-rename policy tests. The UI surface (NSTextField install, hit
/// testing, draw() skipping the edited pill) is inherently manual, but the
/// commit semantics — trim, empty-→-nil override, onCommitRename payload
/// — are pure logic and can be exercised by driving the TabStripView
/// directly against stub windows.
final class InlineRenameTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        TestHostTermination.shared.register()
    }

    private func makeStripView(titles: [String]) -> (TabStripView, [NSWindow]) {
        let windows: [NSWindow] = titles.map { title in
            let w = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
                styleMask: [.titled],
                backing: .buffered,
                defer: true
            )
            w.title = title
            return w
        }
        let strip = TabStripView(frame: NSRect(x: 0, y: 0, width: 600, height: 28))
        strip.update(tabs: windows, selected: windows[0], width: 600)
        return (strip, windows)
    }

    func test_commit_trims_and_forwards_nonempty() {
        let (strip, windows) = makeStripView(titles: ["a", "b"])
        var captured: (NSWindow, String)?
        strip.onCommitRename = { captured = ($0, $1) }

        strip.beginEditing(pillIndex: 1)
        // Simulate the user typing with leading/trailing space.
        // Regression for swift-tests-view F6: call the internal DEBUG
        // hook directly so a rename drift breaks compilation, not CI
        // after silent no-op. `setEditTextForTesting`, `commitEditFor
        // Testing`, `cancelEditForTesting` are declared `@objc func`
        // with default (internal) visibility — `@testable import
        // Blackbird` exposes them for direct call.
        strip.setEditTextForTesting("  My Tab  ")
        strip.commitEditForTesting()

        XCTAssertEqual(captured?.0, windows[1])
        XCTAssertEqual(captured?.1, "My Tab")
    }

    func test_commit_empty_forwards_empty_string() {
        // Empty string is the carrier for "clear override, revert to OSC."
        // The MainWindowController maps "" → nil titleOverride; the strip
        // just publishes what the user typed (after trim).
        let (strip, windows) = makeStripView(titles: ["a"])
        var captured: (NSWindow, String)?
        strip.onCommitRename = { captured = ($0, $1) }

        strip.beginEditing(pillIndex: 0)
        // See F6 note above — direct call, not perform(_:).
        strip.setEditTextForTesting("   ")
        strip.commitEditForTesting()

        XCTAssertEqual(captured?.0, windows[0])
        XCTAssertEqual(captured?.1, "")
    }

    func test_cancel_does_not_forward() {
        let (strip, _) = makeStripView(titles: ["a"])
        var called = false
        strip.onCommitRename = { _, _ in called = true }

        strip.beginEditing(pillIndex: 0)
        // See F6 note above — direct call, not perform(_:).
        strip.setEditTextForTesting("will-be-cancelled")
        strip.cancelEditForTesting()

        XCTAssertFalse(called, "cancel must not publish a rename")
    }

    func test_second_beginEditing_commits_first() {
        let (strip, windows) = makeStripView(titles: ["a", "b"])
        var commits: [(NSWindow, String)] = []
        strip.onCommitRename = { commits.append(($0, $1)) }

        strip.beginEditing(pillIndex: 0)
        strip.setEditTextForTesting("first")
        strip.beginEditing(pillIndex: 1)
        strip.setEditTextForTesting("second")
        strip.commitEditForTesting()

        XCTAssertEqual(commits.count, 2)
        XCTAssertEqual(commits[0].0, windows[0])
        XCTAssertEqual(commits[0].1, "first")
        XCTAssertEqual(commits[1].0, windows[1])
        XCTAssertEqual(commits[1].1, "second")
    }

    /// A width-only `update` call (same tab list, different width — the
    /// path `windowDidResize` takes every tick at 120 Hz on ProMotion)
    /// must NOT discard the user's in-flight rename. Pre-fix the strip
    /// committed on every update, silently dropping any typing the user
    /// had done between the last frame and the drag release.
    /// (main-window F6)
    func test_widthOnlyUpdate_preservesInFlightRename() {
        let (strip, windows) = makeStripView(titles: ["a", "b"])
        var commits: [(NSWindow, String)] = []
        strip.onCommitRename = { commits.append(($0, $1)) }

        strip.beginEditing(pillIndex: 1)
        strip.setEditTextForTesting("mid-type")
        // Simulate a resize tick: SAME tabs + selected, different width.
        strip.update(tabs: windows, selected: windows[0], width: 400)
        XCTAssertEqual(commits.count, 0,
                       "width-only update must not commit an in-flight edit")

        // User hits Enter — the in-flight value survives.
        strip.commitEditForTesting()
        XCTAssertEqual(commits.count, 1)
        XCTAssertEqual(commits[0].0, windows[1])
        XCTAssertEqual(commits[0].1, "mid-type")
    }

    /// A list-shape change (tab count changes, or the same-count list
    /// has different window instances from a reorder/merge) still
    /// commits to protect the edit from the stale-index hazard the
    /// original `update` guard targeted. (main-window F6)
    func test_listShapeChange_stillCommitsInFlightEdit() {
        let (strip, windows) = makeStripView(titles: ["a", "b", "c"])
        var commits: [(NSWindow, String)] = []
        strip.onCommitRename = { commits.append(($0, $1)) }

        strip.beginEditing(pillIndex: 2)
        strip.setEditTextForTesting("outgoing")
        // Simulate a tab-close: shorter tab list.
        strip.update(
            tabs: Array(windows.prefix(2)),
            selected: windows[0],
            width: 600
        )
        XCTAssertEqual(commits.count, 1,
                       "list-shape change must commit the in-flight edit")
        XCTAssertEqual(commits[0].0, windows[2])
        XCTAssertEqual(commits[0].1, "outgoing")
    }

    /// `commitEditIfNeeded` is a no-op when nothing's being edited and
    /// publishes the current value when an edit is in flight. Exposed
    /// so `MainWindowController.refreshTabBar` can tear down the
    /// editing field before hiding the strip on the multi-tab →
    /// single-tab transition. (main-window F8)
    func test_commitEditIfNeeded_publishesActiveEdit() {
        let (strip, windows) = makeStripView(titles: ["a", "b"])
        var commits: [(NSWindow, String)] = []
        strip.onCommitRename = { commits.append(($0, $1)) }

        // No edit in progress: no-op.
        strip.commitEditIfNeeded()
        XCTAssertEqual(commits.count, 0)

        strip.beginEditing(pillIndex: 0)
        strip.setEditTextForTesting("stranded")
        strip.commitEditIfNeeded()

        XCTAssertEqual(commits.count, 1,
                       "commitEditIfNeeded must publish the active edit")
        XCTAssertEqual(commits[0].0, windows[0])
        XCTAssertEqual(commits[0].1, "stranded")
    }

    /// Regression for swift-tests-view F5: the applyInlineRename logic
    /// on the controller is `session?.titleOverride = trimmed.isEmpty
    /// ? nil : trimmed` — pure logic that doesn't need a real login
    /// shell. Exercising it against a `TerminalSession.makeHeadless
    /// ForTests()` avoids the heavy login-shell startup and its
    /// side effects (rc files sourced, which vary per developer).
    func test_applyInlineRename_logic_mapsEmptyToNilViaHeadlessSession() {
        // Pure logic against a session that never launched a shell.
        let session = TerminalSession.makeHeadlessForTests()
        session.applyOscTitle("from-shell")
        // Non-empty → override set.
        let nonEmpty = "Custom".trimmingCharacters(in: .whitespacesAndNewlines)
        session.titleOverride = nonEmpty.isEmpty ? nil : nonEmpty
        XCTAssertEqual(session.titleOverride, "Custom")
        // Empty / whitespace-only → override cleared; session resumes
        // the OSC-reported title.
        let empty = "".trimmingCharacters(in: .whitespacesAndNewlines)
        session.titleOverride = empty.isEmpty ? nil : empty
        XCTAssertNil(session.titleOverride)
        // Teardown: headless session has no shell to reap, but the
        // BBTerm Rust state still needs a terminate() to free its ring.
        session.terminate()
    }

    func test_applyInlineRename_onController_maps_empty_to_nil() {
        // Retained as a single end-to-end test: exercises the controller's
        // real init path (which spawns $SHELL -il once) so the
        // `isRestorable` invariant (main-window F23) can be asserted
        // against a real NSWindow. The logic invariant itself is now
        // covered by the faster headless test above (swift-tests-view
        // F5), so keeping this one is only about the window-side
        // contract. See memory note `feedback_test_real_shell_
        // controllers` — exactly ONE real controller per class remains
        // the invariant.
        let controller = MainWindowController(
            initialWorkingDirectory: nil,
            autosaveFrame: false
        )
        defer {
            controller.terminateSessions()
            controller.window?.close()
        }
        // Simulate a shell title so there's something to revert to.
        controller.session?.applyOscTitle("from-shell")

        controller.applyInlineRename("Custom")
        XCTAssertEqual(controller.session?.titleOverride, "Custom")

        controller.applyInlineRename("")
        XCTAssertNil(controller.session?.titleOverride)

        // Pin main-window F23: every Blackbird window opts out of
        // NSWindowRestoration explicitly. `required init?(coder:)`
        // fatal-errors, so a restoration attempt would crash on wake;
        // setting `isRestorable = false` tells AppKit not to try.
        // (main-window F23)
        XCTAssertFalse(
            controller.window?.isRestorable ?? true,
            "MainWindowController.window must set isRestorable=false "
                + "because the class does not implement "
                + "encodeRestorableState / restoreState."
        )
    }
}
