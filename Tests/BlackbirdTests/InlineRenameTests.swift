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
        strip.perform(NSSelectorFromString("setEditTextForTesting:"), with: "  My Tab  ")
        strip.perform(NSSelectorFromString("commitEditForTesting"))

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
        strip.perform(NSSelectorFromString("setEditTextForTesting:"), with: "   ")
        strip.perform(NSSelectorFromString("commitEditForTesting"))

        XCTAssertEqual(captured?.0, windows[0])
        XCTAssertEqual(captured?.1, "")
    }

    func test_cancel_does_not_forward() {
        let (strip, _) = makeStripView(titles: ["a"])
        var called = false
        strip.onCommitRename = { _, _ in called = true }

        strip.beginEditing(pillIndex: 0)
        strip.perform(NSSelectorFromString("setEditTextForTesting:"), with: "will-be-cancelled")
        strip.perform(NSSelectorFromString("cancelEditForTesting"))

        XCTAssertFalse(called, "cancel must not publish a rename")
    }

    func test_second_beginEditing_commits_first() {
        let (strip, windows) = makeStripView(titles: ["a", "b"])
        var commits: [(NSWindow, String)] = []
        strip.onCommitRename = { commits.append(($0, $1)) }

        strip.beginEditing(pillIndex: 0)
        strip.perform(NSSelectorFromString("setEditTextForTesting:"), with: "first")
        strip.beginEditing(pillIndex: 1)
        strip.perform(NSSelectorFromString("setEditTextForTesting:"), with: "second")
        strip.perform(NSSelectorFromString("commitEditForTesting"))

        XCTAssertEqual(commits.count, 2)
        XCTAssertEqual(commits[0].0, windows[0])
        XCTAssertEqual(commits[0].1, "first")
        XCTAssertEqual(commits[1].0, windows[1])
        XCTAssertEqual(commits[1].1, "second")
    }

    func test_applyInlineRename_onController_maps_empty_to_nil() {
        // Contract between strip and MainWindowController: trimmed-empty
        // → override cleared, non-empty → override set.
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
    }
}
