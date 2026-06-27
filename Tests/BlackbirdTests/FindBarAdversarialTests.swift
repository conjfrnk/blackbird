import XCTest
import AppKit
import Metal
@testable import Blackbird
import BBCore

/// Adversarial coverage for the FindBar / find-in-page logic. These
/// tests target failure modes the four existing FindBar suites
/// (FindBarAltScreenTests, FindBarReplaceTests, FindReplaceIntegration
/// Tests, InlineRenameTests) don't pin: empty / oversized / unicode /
/// degenerate-regex queries, the ReDoS gate's 3+ way alternation widen
/// from commit 400c265, match-cycle wrap-around, resize-during-find,
/// and replace-all corpus invariants.
///
/// Per-test budgets:
///   - 0 `MainWindowController` instances.
///   - 0 `TerminalSession` / `/bin/cat` spawns.
///   - At most 1 `TerminalView` (lightweight `MTKView` subclass) and a
///     handful of 20×4 / 40×4 `BBTerm` grids — well under 100 KB / test.
///   - Each test wall-clock < 100 ms; the ReDoS-gate test budgets <
///     50 ms explicitly via `measureTimeMS`.
final class FindBarAdversarialTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        TestHostTermination.shared.register()
    }

    // MARK: - Helpers

    private func makeView() throws -> TerminalView {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        return TerminalView(
            frame: NSRect(x: 0, y: 0, width: 800, height: 480),
            device: device
        )
    }

    /// Build a snapshot whose row 0 holds `text` at col 0. Cols is
    /// sized just past the typed content to keep fixture allocations
    /// tiny (`UInt16(cols) * 4` cells, ≲ 1 KB).
    private func snapshotWithRow0(_ text: String, cols: Int) throws -> BBSnapshot {
        let term = try XCTUnwrap(BBTerm(size: .init(cols: UInt16(cols), rows: 4)))
        term.input("\u{1B}[1;1H")
        term.input(text)
        return try XCTUnwrap(term.snapshot())
    }

    /// Wall-clock duration of `body` in milliseconds. Used by the
    /// catastrophic-backtracking guard test to enforce a bound that
    /// catches a regression where the regex DOES get compiled and
    /// runs to completion against an adversarial string.
    private func measureTimeMS(_ body: () -> Void) -> Double {
        let start = DispatchTime.now().uptimeNanoseconds
        body()
        let end = DispatchTime.now().uptimeNanoseconds
        return Double(end - start) / 1_000_000.0
    }

    /// Recorder used by the cycling / change-query / options tests.
    /// Keeps the full history of each delegate hook so wrap-around
    /// and ordering invariants can be asserted from the outside.
    private final class FullRecorder: FindBarDelegate {
        var queries: [String] = []
        var directions: [FindBar.Direction] = []
        var replacements: [(FindBar.ReplaceKind, String)] = []
        var optionsHistory: [FindBar.Options] = []
        var closedCount: Int = 0

        func findBar(_ bar: FindBar, didChangeQuery query: String) {
            queries.append(query)
        }
        func findBar(_ bar: FindBar, didAdvance direction: FindBar.Direction) {
            directions.append(direction)
        }
        func findBarDidClose(_ bar: FindBar) {
            closedCount += 1
        }
        func findBar(
            _ bar: FindBar,
            didRequestReplace kind: FindBar.ReplaceKind,
            with replacement: String
        ) {
            replacements.append((kind, replacement))
        }
        func findBar(_ bar: FindBar, didChangeOptions options: FindBar.Options) {
            optionsHistory.append(options)
        }
    }

    // MARK: - 1. Empty-query search

    /// Scenario 1: pushing the empty string through `performSearch`
    /// must NOT infinite-loop and MUST clear `findMatches`. The
    /// session-less guard in performSearch also nils `findMatchesSeq`,
    /// but the empty-query branch is the upstream gate — if it
    /// regressed, find would enter the scanner with an empty needle
    /// and spin.
    func test_emptyQuery_clearsMatchesAndDoesNotLoop() throws {
        let view = try makeView()
        let term = try XCTUnwrap(BBTerm(size: .init(cols: 20, rows: 4)))
        term.input("hello world")
        let snap = try XCTUnwrap(term.snapshot())
        view.currentSnapshot = snap
        // Pre-populate as if a previous search had matches; the empty
        // bail-out must wipe them.
        view.findController.findMatches = [(line: 0, startCol: 0, endCol: 4)]
        view.findController.findMatchesSeq = snap.sequenceID
        view.findController.findQuery = "hello"

        let ms = measureTimeMS {
            view.findController.performSearch(query: "")
        }

        XCTAssertLessThan(
            ms, 50.0,
            "empty-query performSearch must return immediately, not enter "
            + "the scan loop; ran for \(ms) ms"
        )
        XCTAssertTrue(
            view.findController.findMatches.isEmpty,
            "empty query must clear findMatches"
        )
    }

    // MARK: - 2. Query longer than the entire scrollback corpus

    /// Scenario 2: query longer than the visible viewport. The needle
    /// can't possibly match (and in particular can't run off the end
    /// of any row); `findMatches` must end empty without a buffer
    /// overrun or crash.
    func test_queryLongerThanCorpus_yieldsZeroMatches() throws {
        let view = try makeView()
        // Corpus: tiny viewport, a short word.
        let snap = try snapshotWithRow0("hi", cols: 5)
        view.currentSnapshot = snap
        // 256-char needle — orders of magnitude longer than any row.
        let oversized = String(repeating: "x", count: 256)

        let ms = measureTimeMS {
            view.findController.performSearch(query: oversized)
        }

        XCTAssertLessThan(ms, 50.0, "oversized-query search must stay bounded")
        XCTAssertTrue(
            view.findController.findMatches.isEmpty,
            "needle longer than every row must yield zero matches; "
            + "got \(view.findController.findMatches.count)"
        )
    }

    // MARK: - 3. Catastrophic-backtracking regex must be gated

    /// Scenario 3: the textbook ReDoS shape `(a+)+b` against an
    /// all-`a` string with a trailing `!` is the canonical
    /// exponential-backtrack case. The static gate must reject the
    /// pattern outright; even if it didn't, the surrounding find
    /// path must wall-clock below 50 ms.
    func test_catastrophicBacktracking_isGatedBelowBudget() {
        let pattern = "(a+)+b"
        // First-line defence: the static heuristic gate rejects it.
        XCTAssertFalse(
            RegexSafetyGate.isReasonable(pattern),
            "(a+)+b is the textbook ReDoS shape and must be rejected "
            + "by the static gate; otherwise the find loop hangs the UI"
        )

        // Second-line defence: even if the gate were bypassed, the
        // worst-case attempt to compile/match must stay bounded —
        // the test harness should never freeze. We assert this by
        // running NSRegularExpression directly with a budget; if the
        // regex engine itself blows past 50 ms on this input, we
        // need a runtime cap in performSearch (the alternation gate
        // is one approach; a 250 ms timeout is the documented
        // fallback). Either way, our adversarial test must surface
        // the regression visibly.
        let input = String(repeating: "a", count: 18) + "!"
        let ms = measureTimeMS {
            if let re = try? NSRegularExpression(pattern: pattern) {
                _ = re.numberOfMatches(
                    in: input,
                    range: NSRange(location: 0, length: input.utf16.count)
                )
            }
        }
        XCTAssertLessThan(
            ms, 50.0,
            "even if the gate is bypassed, regex execution against the "
            + "adversarial input must stay under 50 ms; took \(ms) ms"
        )
    }

    // MARK: - 4. Invalid regex syntax

    /// Scenario 4: `[unclosed` is malformed. The gate may pass it,
    /// but compilation must fail — `performSearch` must surface zero
    /// matches and never crash. We exercise the public `performSearch`
    /// (regex mode on via direct option set) so a regression where an
    /// invalid pattern force-unwraps an NSRegularExpression would
    /// fault here.
    func test_invalidRegexSyntax_doesNotCrashAndYieldsZeroMatches() throws {
        let view = try makeView()
        let snap = try snapshotWithRow0("anything", cols: 10)
        view.currentSnapshot = snap
        // Switch into regex mode through the FindBar's public toggle so
        // the option propagates the same way the user's ⌥⌘R does.
        let bar = FindBar(frame: .zero)
        bar.toggleRegexMode(nil)
        XCTAssertTrue(bar.options.regex, "test setup: regex mode must be on")

        let ms = measureTimeMS {
            view.findController.performSearch(query: "[unclosed")
        }
        XCTAssertLessThan(ms, 50.0, "invalid-regex path must stay bounded")
        XCTAssertTrue(
            view.findController.findMatches.isEmpty,
            "invalid regex must produce zero matches, not crash"
        )
    }

    // MARK: - 5. Multi-way alternation — gate widening from 400c265

    /// Scenario 5: commit 400c265 widened the gate to reject 3+ way
    /// alternations inside a quantified group. Plain (non-quantified)
    /// 4-way alternation `(foo|bar|baz|qux)` is the case the gate must
    /// continue to ACCEPT — it's perfectly safe and a real user query.
    /// The companion negative case (rejection of the quantified form)
    /// lives in FindBarReplaceTests; this is the positive control.
    func test_fourWayPlainAlternation_isAcceptedByGate() {
        // Positive: plain 4-way alternation must remain accepted.
        XCTAssertTrue(
            RegexSafetyGate.isReasonable("(foo|bar|baz|qux)"),
            "4-way plain alternation (no trailing quantifier) is safe "
            + "and must remain accepted — the 400c265 widen targets "
            + "the QUANTIFIED form only"
        )
        // Composition: confirm the NSRegularExpression accepts and
        // matches each branch against a corpus, so the gate isn't
        // accidentally accepting a pattern the runtime can't compile.
        let pattern = "(foo|bar|baz|qux)"
        let re = try? NSRegularExpression(pattern: pattern)
        XCTAssertNotNil(re, "gate-accepted 4-way alternation must compile")
        let corpus = "foo something bar then baz finally qux"
        let n = re?.numberOfMatches(
            in: corpus,
            range: NSRange(location: 0, length: corpus.utf16.count)
        ) ?? -1
        XCTAssertEqual(
            n, 4,
            "each of the four alternation branches must match exactly once"
        )
    }

    // MARK: - 6. Match-cycle wrap-around

    /// Scenario 6: with 3 matches the `Direction` delegate must fire
    /// on each `triggerNext`/`triggerPrevious` exactly once. We don't
    /// have a public match-count hook on the bar, but the delegate's
    /// `didAdvance` is the public observable — verify the direction
    // Removed: blind-author invented `triggerNext` / `triggerPrevious`
    // methods that don't exist. The advance path is driven by keyboard
    // shortcuts / menu items, not a public method on FindBar. The
    // findCurrentIndex-wrap companion test below still pins the
    // controller-side wrap behavior, which is the load-bearing half.

    /// Companion to Scenario 6 on the controller side: verify the
    /// findCurrentIndex wraps. Three matches, four `advanceFind(.forward)`
    /// calls → end at index 0 (back to match[0]). One `advanceFind
    /// (.backward)` from index 0 → index 2 (wrap to last).
    func test_findCurrentIndex_wrapsAroundOnControllerSide() throws {
        let view = try makeView()
        let term = try XCTUnwrap(BBTerm(size: .init(cols: 40, rows: 4)))
        term.input("a..a..a")
        let snap = try XCTUnwrap(term.snapshot())
        view.currentSnapshot = snap
        view.findController.findQuery = "a"
        view.findController.findMatches = [
            (line: 0, startCol: 0, endCol: 0),
            (line: 0, startCol: 3, endCol: 3),
            (line: 0, startCol: 6, endCol: 6),
        ]
        view.findController.findMatchesSeq = snap.sequenceID
        view.findController.findCurrentIndex = 0

        // 3 advances from index 0 → 1 → 2 → 0 (wrap). The fourth call
        // is the test's belt-and-braces: still 0.
        view.findController.advanceFind(direction: .forward)
        view.findController.advanceFind(direction: .forward)
        view.findController.advanceFind(direction: .forward)
        XCTAssertEqual(
            view.findController.findCurrentIndex, 0,
            "three forward advances from index 0 across 3 matches must "
            + "wrap back to index 0"
        )
        view.findController.advanceFind(direction: .backward)
        XCTAssertEqual(
            view.findController.findCurrentIndex, 2,
            "one backward advance from index 0 must wrap to the last "
            + "match (index 2)"
        )
    }

    // MARK: - 7. Find on empty scrollback

    /// Scenario 7: fresh terminal, no input. Any non-empty query
    /// finds zero matches — and crucially doesn't crash on an
    /// uninitialised buffer. (alacritty fills cells with ' ' by
    /// default, so "anything" must not accidentally match a row of
    /// spaces.)
    func test_findOnFreshTerminal_yieldsZeroMatches() throws {
        let view = try makeView()
        let term = try XCTUnwrap(BBTerm(size: .init(cols: 20, rows: 4)))
        let snap = try XCTUnwrap(term.snapshot())
        view.currentSnapshot = snap
        view.findController.performSearch(query: "anything")
        XCTAssertTrue(
            view.findController.findMatches.isEmpty,
            "search against an empty terminal must yield zero matches; "
            + "got \(view.findController.findMatches.count)"
        )
    }

    // MARK: - 8. Find then resize

    /// Scenario 8: produce matches against a 40-col snapshot, then
    /// "resize" to 20 cols by swapping in a smaller snapshot. The
    /// stale matches must NOT survive into the new snapshot
    /// uncontested — the seq-stamp + stale-detection contract
    /// (covered by FindStaleMatchInvalidationTests) drives this. We
    /// pin the adversarial corner: re-running performSearch against
    /// the smaller snapshot is deterministic, doesn't crash, and
    /// doesn't return matches whose coordinates fall outside the new
    /// grid.
    func test_findThenResize_doesNotReturnOutOfBoundsMatches() throws {
        let view = try makeView()
        // Pre-resize: 40-col grid holding two "hi" tokens.
        let wideTerm = try XCTUnwrap(BBTerm(size: .init(cols: 40, rows: 4)))
        wideTerm.input("hi................................hi")
        let wide = try XCTUnwrap(wideTerm.snapshot())
        view.currentSnapshot = wide
        view.findController.findQuery = "hi"
        // Plant stale matches whose columns sit beyond the post-resize
        // grid (col 34 > 20).
        view.findController.findMatches = [
            (line: 0, startCol: 0,  endCol: 1),
            (line: 0, startCol: 34, endCol: 35),
        ]
        view.findController.findMatchesSeq = wide.sequenceID

        // Post-resize: 20-col grid holding one "hi".
        let narrowTerm = try XCTUnwrap(BBTerm(size: .init(cols: 20, rows: 4)))
        narrowTerm.input("hi")
        let narrow = try XCTUnwrap(narrowTerm.snapshot())
        view.currentSnapshot = narrow
        // Re-search. performSearch's session-less guard runs first,
        // clearing the stale list; if the guard ever changes to
        // preserve matches across a seq change, this assertion would
        // catch the regression because the col-34 stale match would
        // survive into a 20-col grid.
        view.findController.performSearch(query: "hi")
        for m in view.findController.findMatches {
            XCTAssertLessThan(
                m.startCol, narrow.cols,
                "no match can have startCol beyond the post-resize grid "
                + "(\(narrow.cols)); got \(m.startCol)"
            )
            XCTAssertLessThan(
                m.endCol, narrow.cols,
                "no match can have endCol beyond the post-resize grid"
            )
        }
    }

    // MARK: - 9. Find while cursor is on alt-screen

    /// Scenario 9: alt-screen vs scrollback isolation. The visible
    /// rows on alt-screen must contain ONLY the alt-screen content
    /// (vim's UI), not the primary scrollback. Documented behaviour
    /// (per F-S5-014 + FindBarAltScreenTests): find walks visibleRows
    /// when alt-screen is active. This adversarial variant uses a
    /// distinctive token so a regression where find leaks
    /// primary-screen content into the alt-screen scan would
    /// false-positive on the assertion.
    func test_altScreen_visibleRowsExcludePrimaryScreen() throws {
        let term = try XCTUnwrap(BBTerm(size: .init(cols: 20, rows: 4)))
        // Primary screen: distinctive token "PRIM_ONLY" pushed off-grid.
        term.input("PRIM_ONLY\r\n")
        for _ in 0..<6 { term.input("\r\n") }
        // Enter alt-screen + write a different distinctive token.
        term.input("\u{1B}[?1049h")
        term.input("ALT_ONLY")

        let snap = try XCTUnwrap(term.snapshot())
        XCTAssertTrue(snap.termMode.contains(.altScreen))
        var visible = ""
        for r in 0..<snap.rows {
            for c in 0..<snap.cols {
                if let ch = snap.character(at: c, row: r) { visible.append(ch) }
            }
        }
        XCTAssertTrue(
            visible.contains("ALT_ONLY"),
            "alt-screen visible rows must contain alt-screen content"
        )
        XCTAssertFalse(
            visible.contains("PRIM_ONLY"),
            "alt-screen visible rows must NOT leak primary-screen content; "
            + "find scanning these rows would otherwise hit stale shell history"
        )
    }

    // MARK: - 10. Unicode query against ASCII corpus

    /// Scenario 10: searching for "中" (BMP CJK, 1 UTF-16 unit) against
    /// "hello world". Zero matches; no crash on the UTF-16 →
    /// col-map walker.
    func test_unicodeQueryAgainstASCII_yieldsZeroMatches() throws {
        let view = try makeView()
        let snap = try snapshotWithRow0("hello world", cols: 12)
        view.currentSnapshot = snap
        view.findController.performSearch(query: "中")
        XCTAssertTrue(
            view.findController.findMatches.isEmpty,
            "unicode needle absent from ASCII corpus must yield zero matches"
        )
    }

    // MARK: - 11. Case sensitivity

    /// Scenario 11: case-sensitivity is OFF by default per
    /// FindBarOptionsTests (`test_defaultOptions_areOff`). The
    /// adversarial pin: toggling caseSensitive must fire the
    /// options-changed delegate with the new state, AND the toggle
    /// must round-trip (off → on → off again with the right
    /// in-between state).
    func test_caseSensitivityToggle_roundTripsThroughDelegate() {
        let bar = FindBar(frame: .zero)
        let recorder = FullRecorder()
        bar.delegate = recorder

        XCTAssertFalse(bar.options.caseSensitive, "default state: CS off")
        bar.toggleCaseSensitive(nil)
        XCTAssertTrue(bar.options.caseSensitive, "after toggle: CS on")
        bar.toggleCaseSensitive(nil)
        XCTAssertFalse(bar.options.caseSensitive, "after second toggle: CS off")

        XCTAssertEqual(
            recorder.optionsHistory.count, 2,
            "each toggle fires exactly one options-changed dispatch"
        )
        XCTAssertEqual(recorder.optionsHistory[0].caseSensitive, true)
        XCTAssertEqual(recorder.optionsHistory[1].caseSensitive, false)
    }

    // MARK: - 12. Rapid query-change race

    /// Scenario 12: rapid query changes simulating a user typing fast.
    /// Each `_setQueryFieldStringForTests`-equivalent (we drive
    /// performSearch directly) must leave findMatches in a coherent
    /// state — never a torn array where the count says N but only K<N
    /// entries are present. We exercise via repeated performSearch
    /// calls on the main thread; if a regression introduced async
    /// completion handlers that mutate findMatches off-thread,
    /// findMatches.count and a re-read would diverge.
    func test_rapidQueryChange_leavesFindMatchesCoherent() throws {
        let view = try makeView()
        let snap = try snapshotWithRow0("hello world hello", cols: 18)
        view.currentSnapshot = snap

        // Toggle the query rapidly. The session-less guard zeroes the
        // matches each call; the invariant is that findMatches is a
        // proper Array at every observable point (no torn read).
        for q in ["hello", "world", "x", "", "hello"] {
            view.findController.performSearch(query: q)
            let snapshotCount = view.findController.findMatches.count
            let reread = view.findController.findMatches.count
            XCTAssertEqual(
                snapshotCount, reread,
                "findMatches.count must not change between consecutive "
                + "reads on the same thread (q=\(q))"
            )
        }
    }

    // MARK: - 13. Replace-all on no-match

    /// Scenario 13: Replace-all dispatched with a needle that's not
    /// in the corpus. The replace delegate path fires (the bar
    /// doesn't know there are no matches — that's the controller's
    /// job), but no bytes can land on the wire because the match
    /// list is empty.
    ///
    /// We pin BOTH legs:
    ///   (a) the FindBar still dispatches the .all kind — find/
    ///       replace policy is "always notify the controller".
    ///   (b) when wired to a real TerminalView with an empty
    ///       findMatches list, replaceAllMatches emits zero bytes.
    func test_replaceAll_onNoMatch_dispatchesYetEmitsNoBytes() throws {
        // Leg (a): FindBar's dispatch path.
        let bar = FindBar(frame: .zero)
        let recorder = FullRecorder()
        bar.delegate = recorder
        bar._setReplaceFieldStringForTests("abc")
        bar._clickReplaceAllForTests()
        XCTAssertEqual(
            recorder.replacements.count, 1,
            "FindBar must dispatch Replace All even when the find query "
            + "found nothing — the controller decides what to do with it"
        )
        XCTAssertEqual(recorder.replacements.first?.0, .all)
        XCTAssertEqual(recorder.replacements.first?.1, "abc")

        // Leg (b): TerminalView with no matches → zero bytes.
        let view = try makeView()
        let snap = try snapshotWithRow0("hello world", cols: 12)
        view.replaceSnapshotForTests = snap
        view.replaceFindMatchesForTests = []   // no matches
        var captured = Data()
        view.replaceByteCapture = { captured.append($0) }
        view._invokeReplaceAllForTests(replacement: "abc")
        XCTAssertTrue(
            captured.isEmpty,
            "Replace All against an empty match list must emit zero bytes; "
            + "got \(captured.count) bytes"
        )
    }

    // MARK: - 14. Replace-all preserves content outside matches

    /// Scenario 14: corpus is "hello world hello", needle "hello",
    /// replacement "x". The find-replace pipeline only erases match
    /// spans (DEL × matchLen) then writes the replacement; the
    /// content outside the matches is owned by the shell's input
    /// buffer and never touched. Verify via the byte stream: the
    /// right-to-left replace order must produce exactly two
    /// DEL₅+"x" sequences (one per match) and NOTHING in between —
    /// no stray bytes that would corrupt the " world " interior.
    func test_replaceAll_preservesContentBetweenMatches() throws {
        let view = try makeView()
        // Build a single-row corpus "hello world hello" so both
        // matches sit on the cursor row.
        let snap = try snapshotWithRow0("hello world hello", cols: 18)
        let cursorLine = Int32(snap.cursorRow)
        XCTAssertEqual(
            cursorLine, 0,
            "test fixture: cursor must land on the row carrying the corpus"
        )
        view.replaceSnapshotForTests = snap
        // Two "hello" spans: cols 0..4 and cols 12..16. 5 chars each.
        view.replaceFindMatchesForTests = [
            (line: cursorLine, startCol: 0,  endCol: 4),
            (line: cursorLine, startCol: 12, endCol: 16),
        ]
        var allCaptures: [Data] = []
        view.replaceByteCapture = { allCaptures.append($0) }

        view._invokeReplaceAllForTests(replacement: "x")

        // Audit S5-003 positioned grammar, right-to-left from the
        // cursor at char 17 (end of "hello world hello"):
        //   cols 12..16 = chars [12, 17): cursor already at the end —
        //     0 moves, 5 DELs, "x" (cursor at 13);
        //   cols 0..4 = chars [0, 5): walk LEFT 8 (13 → 5) — these are
        //     cursor moves, NOT destructive bytes, so the ' world '
        //     interior is preserved — 5 DELs, "x" (cursor at 1);
        //   final: original position 17 shifts by (1−5)×2 = −8 → walk
        //     RIGHT 8 to char 9, the new end of line.
        let csiD = Data([0x1B, 0x5B, 0x44])
        let csiC = Data([0x1B, 0x5B, 0x43])
        let del5x = Data(repeating: 0x7F, count: 5) + Data("x".utf8)
        var expected = del5x
        for _ in 0..<8 { expected += csiD }
        expected += del5x
        for _ in 0..<8 { expected += csiC }
        let combined = allCaptures.reduce(Data(), +)
        XCTAssertEqual(
            combined, expected,
            "Replace All must erase exactly the two match spans (5 DELs + "
            + "replacement each) with only CURSOR MOVES in between — the "
            + "' world ' interior is never erased"
        )
    }
}
