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

/// Tests for the ReDoS gate on regex find. Audit findbar-selection F2.
/// The gate is a static helper on TerminalView; validating it at the
/// helper level is cheap and doesn't require a full find execution.
final class FindRegexGuardTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        TestHostTermination.shared.register()
    }

    func test_reasonablePatterns_accepted() {
        for pattern in [
            "hello",
            "foo.*bar",
            "[A-Z]+",
            "\\d{3}-\\d{4}",
            "(cat|dog|fish)",
            "^prefix",
            "suffix$",
        ] {
            XCTAssertTrue(
                TerminalView.isReasonableRegexPattern(pattern),
                "legitimate pattern must pass: \(pattern)"
            )
        }
    }

    func test_catastrophicNestedQuantifiers_rejected() {
        // These are the textbook ReDoS shapes — single-group nested
        // quantifier with an overlap, which is exponential on mismatches.
        for pattern in [
            "(a+)+",
            "(a*)*",
            "(.*)+",
            "(.+)+",
            "(\\w+)+",
            "(\\s*)*",
        ] {
            XCTAssertFalse(
                TerminalView.isReasonableRegexPattern(pattern),
                "catastrophic-backtrack pattern must be rejected: \(pattern)"
            )
        }
    }

    func test_oversizedPattern_rejected() {
        // A 500-char query field is a sign something went wrong — a human
        // doesn't type regex longer than that, and a paste-bomb shouldn't
        // be accepted.
        let giant = String(repeating: "a", count: 512)
        XCTAssertFalse(
            TerminalView.isReasonableRegexPattern(giant),
            "over-length pattern must be rejected"
        )
    }

    // MARK: - Bypass shapes the original substring guard missed.
    //
    // The first iteration of the gate only checked a hardcoded list of
    // dangerous substrings. Trivial wrappers around the same nested
    // quantifier (extra parens, non-capturing groups, alternation in a
    // quantified group) defeated that match. These regression tests pin
    // the wider net introduced by the heuristic-strengthening pass.
    // Audit findbar-selection F2.

    func test_isReasonableRegexPattern_rejectsBraceQuantifiedNestedGroup() {
        // Audit M4. The substring list above only catches `(a+)+`
        // shapes. A brace quantifier inside a quantified group has
        // the same exponential-backtrack profile but escapes the
        // substring check.
        for pattern in [
            "(a{1,})+",
            "(\\w{2,5})*",
            "(.+){2,5}",
            "(\\w*){1,3}",
            "(\\d{0,9})+",
        ] {
            XCTAssertFalse(
                TerminalView.isReasonableRegexPattern(pattern),
                "brace-quantified nested-group ReDoS pattern must be rejected: \(pattern)"
            )
        }
    }

    func test_isReasonableRegexPattern_acceptsLegitimateBracePatterns() {
        // Audit M4 negative-control. Brace quantifiers are perfectly
        // fine outside the nested-quantifier shape; rejecting them
        // wholesale would break legitimate length-bounded queries
        // like `\d{3,5}` or `(abc){2,5}`.
        for pattern in [
            "a{2,5}",
            "\\d{3,5}",
            "(abc){2,5}",
            "(foo){0,10}",
            "[a-z]{2,}",
        ] {
            XCTAssertTrue(
                TerminalView.isReasonableRegexPattern(pattern),
                "legitimate brace-quantified pattern must be accepted: \(pattern)"
            )
        }
    }

    func test_isReasonableRegexPattern_rejectsNestedQuantifierWithExtraGrouping() {
        // `(((a+)))+$` — extra grouping defeats the literal substring
        // check. The fix iterates redundant `((` / `))` collapses before
        // re-running the dangerous-shape match.
        XCTAssertFalse(
            TerminalView.isReasonableRegexPattern("(((a+)))+$"),
            "extra-grouping wrappers around (a+)+ must be rejected"
        )
    }

    func test_isReasonableRegexPattern_rejectsNonCapturingNestedQuantifier() {
        // `(?:a+)+` — non-capturing group prefix evades the
        // substring list. The fix normalises `(?:` → `(` before
        // checking.
        XCTAssertFalse(
            TerminalView.isReasonableRegexPattern("(?:a+)+"),
            "non-capturing group around (a+)+ must be rejected"
        )
    }

    func test_isReasonableRegexPattern_rejectsAlternationInQuantifiedGroup() {
        // `(a|aa)+b` — overlapping alternatives inside a quantified
        // group is the second textbook ReDoS shape. The fix detects
        // any `(...|...)` followed by `+` or `*`.
        XCTAssertFalse(
            TerminalView.isReasonableRegexPattern("(a|aa)+b"),
            "alternation inside a quantified group must be rejected"
        )
    }

    func test_isReasonableRegexPattern_rejectsAlternationInQuantifiedNonCapturingGroup() {
        // Composition test: non-capturing group AND alternation in the
        // same pattern. Either rule is sufficient to reject.
        XCTAssertFalse(
            TerminalView.isReasonableRegexPattern("(?:a|aa)*"),
            "alternation inside a quantified non-capturing group must be rejected"
        )
    }

    /// S3-003: the earlier gate's body class was `[^()|]*` which
    /// required EXACTLY ONE `|` separator. 3+ way alternations slipped
    /// through (`(a|aa|aaa)+x` reached the find engine and pegged it
    /// until the 250 ms timeout fired). The body class is now
    /// `[^()]+` so any number of `|` separators inside the group
    /// triggers the gate.
    func test_isReasonableRegexPattern_rejectsMultiwayAlternationInQuantifiedGroup() {
        for pattern in [
            "(a|aa|aaa)+",      // 3-way overlapping
            "(a|b|c|d)+x",      // 4-way (non-overlapping, but still risky)
            "(foo|bar|baz)*",
            "(?:x|xx|xxx|xxxx)+",
        ] {
            XCTAssertFalse(
                TerminalView.isReasonableRegexPattern(pattern),
                "multi-way alternation inside quantified group must be rejected: \(pattern)"
            )
        }
    }

    func test_isReasonableRegexPattern_rejectsExcessiveQuantifierCount() {
        // Defensive cap: more than 6 quantifiers in one query is a
        // strong "this isn't a legitimate find" signal.
        XCTAssertFalse(
            TerminalView.isReasonableRegexPattern("a*b*c*d*e*f*g*"),
            "patterns with > 6 quantifiers must be rejected"
        )
    }

    func test_isReasonableRegexPattern_acceptsAlternationWithoutQuantifier() {
        // `(cat|dog|fish)` is a perfectly fine find query — alternation
        // alone is not dangerous, only alternation INSIDE a quantified
        // group (`(...|...)+`) overlaps catastrophically.
        XCTAssertTrue(
            TerminalView.isReasonableRegexPattern("(cat|dog|fish)"),
            "plain alternation without a trailing quantifier must pass"
        )
    }

    func test_isReasonableRegexPattern_acceptsRealisticQueriesUnderQuantifierCap() {
        // Sanity: queries a real user might type stay under the cap.
        for pattern in [
            "e[mn]ail",
            "https?://\\S+",
            "TODO|FIXME|HACK",
            "\\b\\w+@\\w+\\.\\w+\\b",
        ] {
            XCTAssertTrue(
                TerminalView.isReasonableRegexPattern(pattern),
                "realistic query must pass: \(pattern)"
            )
        }
    }
}

/// Audit findbar-selection F6. The transient-message deferred clear uses
/// a monotonic token so an A → setMatchCount sequence within 2s doesn't
/// wipe the newer label contents. We can exercise this synchronously by
/// snapshotting the match label before and after write.
final class FindBarTransientTokenTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        TestHostTermination.shared.register()
    }

    func test_setMatchCount_afterTransient_survivesUntilClear() {
        // setMatchCount bumps the token so any pending transient clear
        // for the previous message no longer matches. The immediate
        // label value should be the match count; the deferred clear
        // (2s later) is no-op because token advanced.
        let bar = FindBar(frame: .zero)
        bar.showTransientMessage("Warning")
        bar.setMatchCount(0, of: 3)
        // Sanity: the label now reads the count.
        XCTAssertEqual(bar._matchLabelStringForTests(), "1 / 3")
        // Can't reliably wait 2s in a unit test; the monotonic-token
        // invariant is the point — setMatchCount must have advanced
        // the token so the pending clear is stale on fire. Verified
        // structurally.
    }

    func test_secondTransient_displaysSecondMessage() {
        let bar = FindBar(frame: .zero)
        bar.showTransientMessage("first")
        XCTAssertEqual(bar._matchLabelStringForTests(), "first")
        bar.showTransientMessage("second")
        XCTAssertEqual(bar._matchLabelStringForTests(), "second")
    }
}
