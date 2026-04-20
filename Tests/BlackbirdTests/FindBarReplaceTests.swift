import XCTest
import AppKit
@testable import Blackbird

/// Unit tests for FindBar's replace row: layout, height, and delegate dispatch.
/// These tests are purely structural — no PTY, no TerminalSession.
final class FindBarReplaceTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        TestHostTermination.shared.register()
    }

    // MARK: - Default state

    func test_replaceRow_hiddenByDefault() {
        let bar = FindBar(frame: NSRect(x: 0, y: 0, width: 400, height: 60))
        XCTAssertFalse(bar.isReplaceVisible,
                       "Replace row must be hidden on init")
    }

    func test_preferredHeight_collapsed_is32() {
        let bar = FindBar(frame: NSRect(x: 0, y: 0, width: 400, height: 60))
        XCTAssertEqual(bar.preferredHeight, 32,
                       "Collapsed bar height must be 32 pt")
    }

    // MARK: - Expanded state

    func test_setReplaceVisible_true_showsReplaceRow() {
        let bar = FindBar(frame: NSRect(x: 0, y: 0, width: 400, height: 60))
        bar.setReplaceVisible(true)
        XCTAssertTrue(bar.isReplaceVisible,
                      "isReplaceVisible must become true after setReplaceVisible(true)")
    }

    func test_preferredHeight_expanded_is60() {
        let bar = FindBar(frame: NSRect(x: 0, y: 0, width: 400, height: 60))
        bar.setReplaceVisible(true)
        XCTAssertEqual(bar.preferredHeight, 60,
                       "Expanded bar height must be 60 pt")
    }

    func test_setReplaceVisible_false_collapsesRow() {
        let bar = FindBar(frame: NSRect(x: 0, y: 0, width: 400, height: 60))
        bar.setReplaceVisible(true)
        bar.setReplaceVisible(false)
        XCTAssertFalse(bar.isReplaceVisible,
                       "Replace row must collapse after setReplaceVisible(false)")
        XCTAssertEqual(bar.preferredHeight, 32)
    }

    // MARK: - Delegate dispatch — replace current

    func test_clickReplaceCurrent_firesDelegateWithCurrentKind() {
        let bar = FindBar(frame: NSRect(x: 0, y: 0, width: 400, height: 60))
        let recorder = ReplaceDelegateRecorder()
        bar.delegate = recorder

        bar._setReplaceFieldStringForTests("baz")
        bar._clickReplaceCurrentForTests()

        XCTAssertEqual(recorder.capturedKind, .current,
                       "Replace button must dispatch .current kind")
        XCTAssertEqual(recorder.capturedReplacement, "baz",
                       "Replace button must pass the replacement string")
    }

    func test_clickReplaceCurrent_emptyReplacement_stillFires() {
        let bar = FindBar(frame: NSRect(x: 0, y: 0, width: 400, height: 60))
        let recorder = ReplaceDelegateRecorder()
        bar.delegate = recorder

        bar._setReplaceFieldStringForTests("")
        bar._clickReplaceCurrentForTests()

        XCTAssertNotNil(recorder.capturedKind,
                        "Delegate must fire even with empty replacement text")
        XCTAssertEqual(recorder.capturedReplacement, "")
    }

    // MARK: - Delegate dispatch — replace all

    func test_clickReplaceAll_firesDelegateWithAllKind() {
        let bar = FindBar(frame: NSRect(x: 0, y: 0, width: 400, height: 60))
        let recorder = ReplaceDelegateRecorder()
        bar.delegate = recorder

        bar._setReplaceFieldStringForTests("qux")
        bar._clickReplaceAllForTests()

        XCTAssertEqual(recorder.capturedKind, .all,
                       "Replace All button must dispatch .all kind")
        XCTAssertEqual(recorder.capturedReplacement, "qux",
                       "Replace All button must pass the replacement string")
    }

    func test_clickReplaceAll_multiWord_passesExactString() {
        let bar = FindBar(frame: NSRect(x: 0, y: 0, width: 400, height: 60))
        let recorder = ReplaceDelegateRecorder()
        bar.delegate = recorder

        bar._setReplaceFieldStringForTests("hello world")
        bar._clickReplaceAllForTests()

        XCTAssertEqual(recorder.capturedReplacement, "hello world")
    }

    // MARK: - Disclosure caret toggle

    func test_toggle_expandsAndCollapses() {
        let bar = FindBar(frame: NSRect(x: 0, y: 0, width: 400, height: 60))
        XCTAssertFalse(bar.isReplaceVisible)
        bar.setReplaceVisible(true)
        XCTAssertTrue(bar.isReplaceVisible)
        XCTAssertEqual(bar.preferredHeight, 60)
        bar.setReplaceVisible(false)
        XCTAssertFalse(bar.isReplaceVisible)
        XCTAssertEqual(bar.preferredHeight, 32)
    }

    // MARK: - Independent delegate invocations do not bleed state

    func test_multipleDelegateInvocations_lastWins() {
        let bar = FindBar(frame: NSRect(x: 0, y: 0, width: 400, height: 60))
        let recorder = ReplaceDelegateRecorder()
        bar.delegate = recorder

        bar._setReplaceFieldStringForTests("first")
        bar._clickReplaceCurrentForTests()

        bar._setReplaceFieldStringForTests("second")
        bar._clickReplaceAllForTests()

        // The last dispatch wins.
        XCTAssertEqual(recorder.capturedKind, .all)
        XCTAssertEqual(recorder.capturedReplacement, "second")
    }
}

// MARK: - Test helper

/// Captures the most recent `findBar(_:didRequestReplace:with:)` invocation.
private final class ReplaceDelegateRecorder: FindBarDelegate {
    var capturedKind: FindBar.ReplaceKind?
    var capturedReplacement: String?

    func findBar(_ bar: FindBar, didChangeQuery query: String) {}
    func findBar(_ bar: FindBar, didAdvance direction: FindBar.Direction) {}
    func findBarDidClose(_ bar: FindBar) {}
    func findBar(_ bar: FindBar, didRequestReplace kind: FindBar.ReplaceKind, with replacement: String) {
        capturedKind = kind
        capturedReplacement = replacement
    }
}
