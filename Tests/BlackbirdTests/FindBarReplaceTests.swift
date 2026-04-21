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

    // MARK: - TUI-guard (F3)
    //
    // When the delegate reports `findBarShouldAllowReplace == false` (e.g.
    // alt-screen / mouse-reporting / bracketed-paste active in TerminalView),
    // Replace must refuse to fire the replace delegate and must instead show
    // the transient TUI banner in the match label.

    func test_tuiGuard_refusesReplaceCurrent_whenDelegateDenies() {
        let bar = FindBar(frame: NSRect(x: 0, y: 0, width: 400, height: 60))
        let recorder = GuardableReplaceDelegateRecorder()
        recorder.allowReplace = false
        bar.delegate = recorder

        bar._setReplaceFieldStringForTests("bar")
        bar._clickReplaceCurrentForTests()

        XCTAssertNil(recorder.capturedKind,
                     "Replace must not fire while the TUI-guard denies the operation")
        XCTAssertEqual(bar._matchLabelStringForTests(), FindBar.tuiActiveMessage,
                       "Match label must surface the TUI-active banner")
    }

    func test_tuiGuard_refusesReplaceAll_whenDelegateDenies() {
        let bar = FindBar(frame: NSRect(x: 0, y: 0, width: 400, height: 60))
        let recorder = GuardableReplaceDelegateRecorder()
        recorder.allowReplace = false
        bar.delegate = recorder

        bar._setReplaceFieldStringForTests("bar")
        bar._clickReplaceAllForTests()

        XCTAssertNil(recorder.capturedKind,
                     "Replace All must not fire while the TUI-guard denies the operation")
        XCTAssertEqual(bar._matchLabelStringForTests(), FindBar.tuiActiveMessage,
                       "Match label must surface the TUI-active banner")
    }

    func test_tuiGuard_refusesTriggerReplaceCurrent_whenDelegateDenies() {
        let bar = FindBar(frame: NSRect(x: 0, y: 0, width: 400, height: 60))
        let recorder = GuardableReplaceDelegateRecorder()
        recorder.allowReplace = false
        bar.delegate = recorder

        bar._setReplaceFieldStringForTests("bar")
        // triggerReplaceCurrent is the ⌘⌥E path — must also honour the guard.
        bar.triggerReplaceCurrent()

        XCTAssertNil(recorder.capturedKind,
                     "⌘⌥E path must not fire while the TUI-guard denies the operation")
        XCTAssertEqual(bar._matchLabelStringForTests(), FindBar.tuiActiveMessage)
    }

    func test_tuiGuard_allowsReplace_whenDelegateAllows() {
        let bar = FindBar(frame: NSRect(x: 0, y: 0, width: 400, height: 60))
        let recorder = GuardableReplaceDelegateRecorder()
        recorder.allowReplace = true
        bar.delegate = recorder

        bar._setReplaceFieldStringForTests("bar")
        bar._clickReplaceCurrentForTests()

        XCTAssertEqual(recorder.capturedKind, .current,
                       "Replace must fire normally when the TUI-guard allows")
        XCTAssertEqual(recorder.capturedReplacement, "bar")
        // No banner should have been shown.
        XCTAssertNotEqual(bar._matchLabelStringForTests(), FindBar.tuiActiveMessage)
    }

    func test_tuiGuard_defaultImplementation_allowsReplace() {
        // The plain ReplaceDelegateRecorder does not override the guard, so
        // the default `true` implementation must keep the legacy behaviour.
        let bar = FindBar(frame: NSRect(x: 0, y: 0, width: 400, height: 60))
        let recorder = ReplaceDelegateRecorder()
        bar.delegate = recorder

        bar._setReplaceFieldStringForTests("ok")
        bar._clickReplaceCurrentForTests()

        XCTAssertEqual(recorder.capturedKind, .current,
                       "Delegates that don't override the guard must default to allowing replace")
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

/// Same as `ReplaceDelegateRecorder` but also overrides the TUI-guard so
/// individual tests can flip the gate to exercise the refuse path.
private final class GuardableReplaceDelegateRecorder: FindBarDelegate {
    var capturedKind: FindBar.ReplaceKind?
    var capturedReplacement: String?
    var allowReplace: Bool = true

    func findBar(_ bar: FindBar, didChangeQuery query: String) {}
    func findBar(_ bar: FindBar, didAdvance direction: FindBar.Direction) {}
    func findBarDidClose(_ bar: FindBar) {}
    func findBar(_ bar: FindBar, didRequestReplace kind: FindBar.ReplaceKind, with replacement: String) {
        capturedKind = kind
        capturedReplacement = replacement
    }
    func findBarShouldAllowReplace(_ bar: FindBar) -> Bool { allowReplace }
}

/// Tests for FindBar.Options (case-sensitive + regex). Verifies the
/// options-changed delegate hook fires with the right state and that the
/// public toggles round-trip through the field's placeholder so the user
/// always sees the active flags.
final class FindBarOptionsTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        TestHostTermination.shared.register()
    }

    private final class OptionsRecorder: FindBarDelegate {
        var history: [FindBar.Options] = []
        func findBar(_ bar: FindBar, didChangeQuery query: String) {}
        func findBar(_ bar: FindBar, didAdvance direction: FindBar.Direction) {}
        func findBarDidClose(_ bar: FindBar) {}
        func findBar(_ bar: FindBar, didRequestReplace kind: FindBar.ReplaceKind, with replacement: String) {}
        func findBar(_ bar: FindBar, didChangeOptions options: FindBar.Options) {
            history.append(options)
        }
    }

    func test_defaultOptions_areOff() {
        let bar = FindBar(frame: .zero)
        XCTAssertFalse(bar.options.caseSensitive)
        XCTAssertFalse(bar.options.regex)
    }

    func test_toggleCaseSensitive_firesDelegateWithNewState() {
        let bar = FindBar(frame: .zero)
        let recorder = OptionsRecorder()
        bar.delegate = recorder
        bar.toggleCaseSensitive(nil)
        XCTAssertEqual(recorder.history.count, 1)
        XCTAssertTrue(recorder.history.first?.caseSensitive ?? false)
        XCTAssertFalse(recorder.history.first?.regex ?? true)
    }

    func test_toggleRegexMode_firesDelegateWithNewState() {
        let bar = FindBar(frame: .zero)
        let recorder = OptionsRecorder()
        bar.delegate = recorder
        bar.toggleRegexMode(nil)
        XCTAssertEqual(recorder.history.count, 1)
        XCTAssertTrue(recorder.history.first?.regex ?? false)
    }

    func test_toggleBoth_coalescesInDelegateOrder() {
        let bar = FindBar(frame: .zero)
        let recorder = OptionsRecorder()
        bar.delegate = recorder
        bar.toggleCaseSensitive(nil)
        bar.toggleRegexMode(nil)
        XCTAssertEqual(recorder.history.count, 2)
        let final = recorder.history.last
        XCTAssertTrue(final?.caseSensitive == true && final?.regex == true)
    }

    func test_sameOptionToggleTwice_returnsToOffAndFiresTwice() {
        let bar = FindBar(frame: .zero)
        let recorder = OptionsRecorder()
        bar.delegate = recorder
        bar.toggleCaseSensitive(nil)
        bar.toggleCaseSensitive(nil)
        XCTAssertEqual(recorder.history.count, 2)
        XCTAssertFalse(bar.options.caseSensitive)
    }
}
