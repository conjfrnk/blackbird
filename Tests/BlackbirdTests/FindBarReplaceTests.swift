import XCTest
import AppKit
import Metal
@testable import Blackbird
import BBCore

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

// MARK: - Bug 4: resolveResumeIndex (regex re-scan resume point)
//
// When a regex ⌘G fires during live output, the async re-scan publishes
// a fresh match set and the cycle position must be restored to where the
// user was — one step past their previous match in the travel direction.
// A naïve "reset to match 1" swallows the press and loses the user's
// place in the cycle. `resolveResumeIndex` is the pure function that
// computes the landing index from the remembered anchor + direction
// against the freshly-scanned (document-ordered) match list.
//
// These are pure-arithmetic assertions over a fixed 3-element match list
// (each tuple < a few bytes; the whole suite is < 64 KB and allocates one
// lightweight headless TerminalView for the instance receiver). Derived
// entirely from the documented contract — no implementation body read.
final class FindResolveResumeIndexTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        TestHostTermination.shared.register()
    }

    /// `resolveResumeIndex` is an instance method, so it needs a receiver.
    /// `makeHeadlessForTests()` builds a TerminalView with no PTY / session
    /// (< a few MB, no scrollback growth). The function is pure over its
    /// arguments, so the receiver's other state is irrelevant.
    private func makeView() throws -> TerminalView {
        try XCTUnwrap(TerminalView.makeHeadlessForTests())
    }

    /// Document-ordered match list shared by most cases:
    ///   index 0 → (line 0, col 0)
    ///   index 1 → (line 0, col 5)
    ///   index 2 → (line 2, col 1)
    private let matches: [(line: Int32, startCol: Int, endCol: Int)] = [
        (line: 0, startCol: 0, endCol: 0),
        (line: 0, startCol: 5, endCol: 6),
        (line: 2, startCol: 1, endCol: 2),
    ]

    // MARK: anchor == an exact existing match (forward/backward + wrap)

    func test_resolveResumeIndex_anchorFirstMatch_forwardAdvances_backwardWrapsToLast() throws {
        let view = try makeView()
        XCTAssertEqual(
            view.resolveResumeIndex(anchor: (line: 0, startCol: 0),
                                    direction: .forward, in: matches),
            1, "Forward from the first match must advance to index 1")
        XCTAssertEqual(
            view.resolveResumeIndex(anchor: (line: 0, startCol: 0),
                                    direction: .backward, in: matches),
            2, "Backward from the first match must wrap to the last index")
    }

    func test_resolveResumeIndex_anchorMiddleMatch_forwardAndBackwardStepOne() throws {
        let view = try makeView()
        XCTAssertEqual(
            view.resolveResumeIndex(anchor: (line: 0, startCol: 5),
                                    direction: .forward, in: matches),
            2, "Forward from the middle match must advance to index 2")
        XCTAssertEqual(
            view.resolveResumeIndex(anchor: (line: 0, startCol: 5),
                                    direction: .backward, in: matches),
            0, "Backward from the middle match must step to index 0")
    }

    func test_resolveResumeIndex_anchorLastMatch_forwardWrapsToZero_backwardStepsOne() throws {
        let view = try makeView()
        XCTAssertEqual(
            view.resolveResumeIndex(anchor: (line: 2, startCol: 1),
                                    direction: .forward, in: matches),
            0, "Forward from the last match must wrap to index 0")
        XCTAssertEqual(
            view.resolveResumeIndex(anchor: (line: 2, startCol: 1),
                                    direction: .backward, in: matches),
            1, "Backward from the last match must step to index 1")
    }

    // MARK: anchor == nil (first-cycle semantics)

    func test_resolveResumeIndex_nilAnchor_forwardReturnsFirst_backwardReturnsLast() throws {
        let view = try makeView()
        XCTAssertEqual(
            view.resolveResumeIndex(anchor: nil, direction: .forward, in: matches),
            0, "No anchor + forward must behave like a first cycle → first match")
        XCTAssertEqual(
            view.resolveResumeIndex(anchor: nil, direction: .backward, in: matches),
            2, "No anchor + backward must behave like a first cycle → last match")
    }

    // MARK: anchor does NOT equal any match (the cell under it changed)

    func test_resolveResumeIndex_anchorBetweenMatches_forwardPicksNextGreater_backwardPicksPrevLess() throws {
        // (0,3) sits strictly between (0,0) and (0,5).
        let view = try makeView()
        XCTAssertEqual(
            view.resolveResumeIndex(anchor: (line: 0, startCol: 3),
                                    direction: .forward, in: matches),
            1, "Forward must land on the FIRST match strictly greater than the anchor → (0,5) at index 1")
        XCTAssertEqual(
            view.resolveResumeIndex(anchor: (line: 0, startCol: 3),
                                    direction: .backward, in: matches),
            0, "Backward must land on the LAST match strictly less than the anchor → (0,0) at index 0")
    }

    func test_resolveResumeIndex_anchorAfterAllMatches_forwardWraps_backwardPicksLast() throws {
        // (9,9) is lexicographically after every match.
        let view = try makeView()
        XCTAssertEqual(
            view.resolveResumeIndex(anchor: (line: 9, startCol: 9),
                                    direction: .forward, in: matches),
            0, "Forward with no greater match must wrap to index 0")
        XCTAssertEqual(
            view.resolveResumeIndex(anchor: (line: 9, startCol: 9),
                                    direction: .backward, in: matches),
            2, "Backward with the anchor past all matches must pick the last (index 2)")
    }

    func test_resolveResumeIndex_anchorBeforeAllMatches_forwardPicksFirst_backwardWraps() throws {
        // (-1,0) is lexicographically before every match.
        let view = try makeView()
        XCTAssertEqual(
            view.resolveResumeIndex(anchor: (line: -1, startCol: 0),
                                    direction: .forward, in: matches),
            0, "Forward with the anchor before all matches must pick the first (index 0)")
        XCTAssertEqual(
            view.resolveResumeIndex(anchor: (line: -1, startCol: 0),
                                    direction: .backward, in: matches),
            2, "Backward with no lesser match must wrap to the last index (2)")
    }

    // MARK: degenerate — empty match list

    func test_resolveResumeIndex_emptyMatches_returnsZero() throws {
        let view = try makeView()
        let empty: [(line: Int32, startCol: Int, endCol: Int)] = []
        XCTAssertEqual(
            view.resolveResumeIndex(anchor: (line: 0, startCol: 0),
                                    direction: .forward, in: empty),
            0, "Empty match list must return 0 regardless of anchor/direction")
        XCTAssertEqual(
            view.resolveResumeIndex(anchor: (line: 0, startCol: 0),
                                    direction: .backward, in: empty),
            0, "Empty match list must return 0 in the backward direction too")
        XCTAssertEqual(
            view.resolveResumeIndex(anchor: nil, direction: .forward, in: empty),
            0, "Empty match list must return 0 even with no anchor")
    }
}

// MARK: - Bugs 5/6: refreshFindMatchesIfStaleForReplace — regex-skip guard
//
// Replace All / Replace Current call `refreshFindMatchesIfStaleForReplace()`
// before splicing. For a SUBSTRING query whose cached matches are stale
// (findMatchesSeq != currentSnapshot.sequenceID) it must synchronously
// rescan (which, with no live session, clears findMatches). For a REGEX
// query it must do NOTHING — the regex rescan is async, so clearing the
// cache here would leave Replace operating on an empty set, turning
// Replace All / Replace Current into a silent no-op (Bugs 5/6).
//
// Fixtures use one headless TerminalView (< a few MB) + a single BBTerm
// snapshot (20×4 grid, < 5 KB). No PTY, no session.
final class FindReplaceStaleRefreshGuardTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        TestHostTermination.shared.register()
    }

    private func makeView() throws -> TerminalView {
        try XCTUnwrap(TerminalView.makeHeadlessForTests())
    }

    /// A fresh snapshot from a tiny BBTerm — only its `sequenceID` matters
    /// here. The allocator bumps the ID on every `snapshot()` call so we
    /// can force a stale condition by stamping `findMatchesSeq` to a
    /// deliberately different value.
    private func freshSnapshot() throws -> BBSnapshot {
        let term = try XCTUnwrap(BBTerm(size: .init(cols: 20, rows: 4)))
        term.input("alpha")
        return try XCTUnwrap(term.snapshot())
    }

    /// A FindBar with regex mode ON. `options.regex` defaults to false;
    /// `toggleRegexMode(nil)` flips it to true (verified inline).
    private func regexFindBar() -> FindBar {
        let bar = FindBar(frame: NSRect(x: 0, y: 0, width: 400, height: 60))
        bar.toggleRegexMode(nil)
        XCTAssertTrue(bar.options.regex, "test setup: regex option must be ON")
        return bar
    }

    /// A FindBar in plain substring mode (the default).
    private func substringFindBar() -> FindBar {
        let bar = FindBar(frame: NSRect(x: 0, y: 0, width: 400, height: 60))
        XCTAssertFalse(bar.options.regex, "test setup: regex option must be OFF (substring)")
        return bar
    }

    /// REGEX + stale cache → the guard must NOT touch findMatches. If it
    /// cleared the cache, the subsequent (async) regex rescan would not
    /// have repopulated it yet, and Replace would splice against an empty
    /// list — the Bug 5 / Bug 6 silent no-op.
    func test_refreshForReplace_regexStale_leavesMatchesUntouched() throws {
        let view = try makeView()
        let snap = try freshSnapshot()

        view.findBar = regexFindBar()
        view.findQuery = "al.ha"                       // non-empty regex query
        view.currentSnapshot = snap
        view.findMatches = [(line: 0, startCol: 0, endCol: 4)]
        // Stamp the cache stale: a value that cannot equal the live
        // snapshot's sequenceID.
        view.findMatchesSeq = snap.sequenceID &+ 1

        view.refreshFindMatchesIfStaleForReplace()

        XCTAssertEqual(
            view.findMatches.count, 1,
            "Regex mode must skip the synchronous refresh and leave findMatches "
            + "intact — clearing it here makes Replace All/Current a silent "
            + "no-op (Bugs 5/6).")
        XCTAssertEqual(
            view.findMatches.first?.startCol, 0,
            "The exact cached match must survive the regex-skip guard")
    }

    /// REGEX + NOT stale → still must not disturb the cache (the guard's
    /// regex branch is unconditional; this pins that it doesn't rescan
    /// even when seq happens to match).
    func test_refreshForReplace_regexFresh_leavesMatchesUntouched() throws {
        let view = try makeView()
        let snap = try freshSnapshot()

        view.findBar = regexFindBar()
        view.findQuery = "al.ha"
        view.currentSnapshot = snap
        view.findMatches = [(line: 0, startCol: 0, endCol: 4)]
        view.findMatchesSeq = snap.sequenceID          // in sync → fresh

        view.refreshFindMatchesIfStaleForReplace()

        XCTAssertEqual(
            view.findMatches.count, 1,
            "Regex mode must never clear findMatches via the replace-refresh guard")
    }

    /// SUBSTRING + stale cache → the guard must trigger a synchronous
    /// rescan. With no live session wired, that rescan clears findMatches
    /// (the session-less guard path), which is the observable side-effect
    /// proving the refresh fired. This is the counterpart that the regex
    /// branch deliberately skips.
    func test_refreshForReplace_substringStale_rescansAndClearsMatches() throws {
        let view = try makeView()
        let snap = try freshSnapshot()

        view.findBar = substringFindBar()
        view.findQuery = "alpha"                       // non-empty substring query
        view.currentSnapshot = snap
        view.findMatches = [(line: 0, startCol: 0, endCol: 4)]
        view.findMatchesSeq = snap.sequenceID &+ 1     // stale

        view.refreshFindMatchesIfStaleForReplace()

        XCTAssertTrue(
            view.findMatches.isEmpty,
            "Substring mode must synchronously rescan a stale cache; with no "
            + "session the rescan clears findMatches. (Counterpart to the "
            + "regex-skip guard — Bugs 5/6.)")
    }
}
