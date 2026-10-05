import XCTest
import AppKit
import Metal
@testable import Blackbird
import BBCore

/// Blind behaviour tests for the find bar's ASYNC regex scan lifecycle
/// (spec, not implementation):
///
///  A regex search runs off-main and publishes its results back on the main
///  queue later. Anything the user does in between that makes the scan's
///  query no longer the live one must make the late publish a no-op:
///
///   - closing the find bar        -> no matches, no selection, no scroll
///   - clearing the query          -> same
///   - editing to an invalid regex -> same (query is the invalid text)
///   - toggling regex mode OFF     -> the synchronous substring results win
///   - the view's session being reset to nil (drops query + pending ⌘G)
///
///  A newer VALID regex query must still win over an older in-flight one, a
///  ⌘G / ⌘⇧G pressed while a stale regex rescan is in flight must still be
///  deferred (not swallowed, not reset to match 1), and closing the bar after
///  a scan has published must still preserve the on-screen selection.
///
/// Determinism: the publish hops through `DispatchQueue.main.async`, so any
/// code the test runs synchronously after kicking a scan runs BEFORE the
/// publish; the publish only lands when the test pumps the runloop. The
/// tests therefore interleave "start scan -> mutate -> pump" with no races.
///
/// Fixture: headless `TerminalView` + headless `TerminalSession` (real BBTerm,
/// no PTY), grid 40x6. Cost: a few dozen short lines, scan sets of < 30 rows,
/// ~0.5 s of runloop pumping per test; memory trivial. No real window, no
/// MainWindowController, no PTY.
final class FindStaleRegexScanBlindTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        TestHostTermination.shared.register()
    }

    // MARK: - Fixture

    private struct Rig {
        let view: TerminalView
        let session: TerminalSession
        var fc: FindController { view.findController }
    }

    private func makeRig(file: StaticString = #filePath, line: UInt = #line) throws -> Rig {
        let view = try XCTUnwrap(TerminalView.makeHeadlessForTests(), "Metal device required", file: file, line: line)
        let session = TerminalSession.makeHeadlessForTests()
        session.resize(to: .init(cols: 40, rows: 6))
        view.session = session
        return Rig(view: view, session: session)
    }

    @discardableResult
    private func pump(until timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date(timeIntervalSinceNow: timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.005))
        }
        return condition()
    }

    /// Unconditionally run the main runloop for `seconds` (long enough for any
    /// in-flight scan to publish and for the 250 ms regex timeout to fire).
    private func settle(_ seconds: TimeInterval = 0.5) {
        pump(until: seconds) { false }
    }

    /// Feed lines and wait until the view's snapshot SHOWS the last one.
    private func feed(_ rig: Rig, lines: [String],
                      file: StaticString = #filePath, line: UInt = #line) {
        guard let last = lines.last else { return }
        rig.session.feedBytesForTests(Data((lines.joined(separator: "\r\n") + "\r\n").utf8))
        let landed = pump(until: 3.0) {
            guard let snap = rig.view.currentSnapshot else { return false }
            return snap.visibleRowsAsText().contains { $0.hasPrefix(last) }
        }
        XCTAssertTrue(landed, "publish showing '\(last)' must reach the view within 3 s", file: file, line: line)
    }

    /// Open the bar in regex mode (no query yet, so no search runs) and start
    /// an async regex scan for `query` WITHOUT yielding to the runloop. On
    /// return the scan is in flight: nothing has been published.
    private func startRegexScan(_ rig: Rig, query: String,
                                file: StaticString = #filePath, line: UInt = #line) throws -> FindBar {
        let fc = rig.fc
        if fc.findBar == nil { fc.installFindBar() }
        let bar = try XCTUnwrap(fc.findBar, file: file, line: line)
        if !bar.options.regex { bar.toggleRegexMode(nil) }
        XCTAssertTrue(bar.options.regex, "fixture: regex mode must be on", file: file, line: line)
        bar.setQuery(query)
        XCTAssertTrue(fc.findMatches.isEmpty && fc.findMatchesSeq == nil,
                      "fixture: the regex scan must still be in flight (nothing published yet)",
                      file: file, line: line)
        return bar
    }

    /// Start a scan and let it publish.
    private func completeRegexScan(_ rig: Rig, query: String,
                                   file: StaticString = #filePath, line: UInt = #line) throws -> FindBar {
        let bar = try startRegexScan(rig, query: query, file: file, line: line)
        let published = pump(until: 3.0) { rig.fc.findMatchesSeq != nil }
        XCTAssertTrue(published, "fixture: regex scan for '\(query)' must publish within 3 s", file: file, line: line)
        return bar
    }

    /// Assert the find state is fully quiescent/empty after a stale publish
    /// should have been dropped.
    private func assertNothingPublished(_ rig: Rig, context: String,
                                        file: StaticString = #filePath, line: UInt = #line) {
        let fc = rig.fc
        XCTAssertEqual(fc.findMatches.count, 0,
                       "\(context): a stale regex scan must not repopulate findMatches", file: file, line: line)
        XCTAssertNil(fc.findMatchesSeq,
                     "\(context): a stale regex scan must not stamp findMatchesSeq", file: file, line: line)
        XCTAssertEqual(fc.findCurrentIndex, 0, file: file, line: line)
        XCTAssertNil(rig.view.selection,
                     "\(context): a stale regex scan must not select a match", file: file, line: line)
    }

    // MARK: - Baselines (pass before and after the change)

    func test_baseline_regexScanPublishesAndSelectsFirstMatch() throws {
        let rig = try makeRig()
        feed(rig, lines: ["alpha one", "beta", "alpha two"])
        _ = try completeRegexScan(rig, query: "alpha")
        let fc = rig.fc
        XCTAssertEqual(fc.findMatches.map { $0.line }, [0, 2])
        XCTAssertEqual(fc.findCurrentIndex, 0)
        let sel = try XCTUnwrap(rig.view.selection)
        XCTAssertEqual(sel.anchor.line, 0)
        XCTAssertEqual(sel.anchor.col, 0)
        XCTAssertEqual(sel.cursor.col, 4)
    }

    func test_baseline_scrollbackMatchScrollsViewportWhenPublished() throws {
        let rig = try makeRig()
        feed(rig, lines: ["alpha top"] + (1...14).map { "filler \($0)" })
        XCTAssertEqual(rig.view.currentSnapshot?.displayOffset, 0, "fixture: viewport starts at the live bottom")
        _ = try completeRegexScan(rig, query: "alpha")
        let sel = try XCTUnwrap(rig.view.selection)
        XCTAssertLessThan(sel.anchor.line, 0, "fixture: the only match lives in scrollback")
        let scrolled = pump(until: 3.0) { (rig.view.currentSnapshot?.displayOffset ?? 0) > 0 }
        XCTAssertTrue(scrolled, "publishing a scrollback match must scroll the viewport up to it")
    }

    func test_newerValidRegexQueryStillWinsOverOlderInFlightScan() throws {
        let rig = try makeRig()
        feed(rig, lines: ["alpha one", "beta", "alpha two"])
        let bar = try startRegexScan(rig, query: "alpha")
        bar.setQuery("two")   // supersedes the first scan before it publishes
        let published = pump(until: 3.0) { rig.fc.findMatchesSeq != nil }
        XCTAssertTrue(published)
        settle(0.4)
        let fc = rig.fc
        XCTAssertEqual(fc.findQuery, "two")
        XCTAssertEqual(fc.findMatches.map { $0.line }, [2],
                       "only the newest query's results may be live; the older scan's results must not leak in")
        let sel = try XCTUnwrap(rig.view.selection)
        XCTAssertEqual(sel.anchor.line, 2)
    }

    func test_closeBarAfterPublish_preservesSelectionButWipesMatches() throws {
        let rig = try makeRig()
        feed(rig, lines: ["alpha one", "beta", "alpha two"])
        let bar = try completeRegexScan(rig, query: "alpha")
        let before = try XCTUnwrap(rig.view.selection)
        rig.view.findBarDidClose(bar)
        settle(0.4)
        let fc = rig.fc
        XCTAssertNil(fc.findBar)
        XCTAssertEqual(fc.findMatches.count, 0)
        XCTAssertNil(fc.findMatchesSeq)
        XCTAssertEqual(fc.findCurrentIndex, 0)
        XCTAssertEqual(fc.findQuery, "")
        let after = try XCTUnwrap(rig.view.selection, "closing the bar preserves the selection so Esc then Cmd-C copies it")
        XCTAssertEqual(after.anchor.line, before.anchor.line)
        XCTAssertEqual(after.anchor.col, before.anchor.col)
        XCTAssertEqual(after.cursor.col, before.cursor.col)
    }

    // MARK: - ⌘G during a stale rescan: deferred, not swallowed / reset / stranded (pass before and after)

    /// Seeds three matches (lines 0, 2, 3), publishes a scan, then makes the
    /// cached matches stale WITHOUT relying on what is visible in the
    /// viewport: waits on the snapshot sequence id changing.
    private func staleRescanFixture() throws -> Rig {
        let rig = try makeRig()
        feed(rig, lines: ["alpha one", "beta", "alpha two"])
        _ = try completeRegexScan(rig, query: "alpha")
        XCTAssertEqual(rig.fc.findMatches.count, 2, "fixture: two matches before the new output")
        XCTAssertEqual(rig.fc.findCurrentIndex, 0)
        let seqBefore = try XCTUnwrap(rig.view.currentSnapshot?.sequenceID)
        rig.session.feedBytesForTests(Data("alpha three\r\n".utf8))
        let advanced = pump(until: 3.0) {
            guard let s = rig.view.currentSnapshot?.sequenceID else { return false }
            return s != seqBefore
        }
        XCTAssertTrue(advanced, "fixture: a newer snapshot must reach the view")
        XCTAssertNotEqual(rig.fc.findMatchesSeq, rig.view.currentSnapshot?.sequenceID,
                          "fixture: cached matches are now stale vs the live snapshot")
        // Make sure the new row has actually been parsed into the live snapshot
        // before we rely on it: wait until it is visible OR history grew.
        let seen = pump(until: 3.0) {
            guard let snap = rig.view.currentSnapshot else { return false }
            return snap.visibleRowsAsText().contains { $0.hasPrefix("alpha three") } || snap.historySize > 0
        }
        XCTAssertTrue(seen, "fixture: the new line must be in the live snapshot")
        return rig
    }

    func test_nextMatchDuringStaleRescan_forward_resumesFromAnchorAfterPublish() throws {
        let rig = try staleRescanFixture()
        let fc = rig.fc
        fc.advanceFind(direction: .forward)
        // Not swallowed + not reset to match 1: once the rescan publishes, the
        // cycle lands one past the match the user was on (index 0 -> 1).
        let republished = pump(until: 3.0) { fc.findMatchesSeq == rig.view.currentSnapshot?.sequenceID && !fc.findMatches.isEmpty }
        XCTAssertTrue(republished, "the stale rescan must publish")
        XCTAssertEqual(fc.findMatches.count, 3)
        XCTAssertEqual(fc.findCurrentIndex, 1, "Cmd-G pressed mid-rescan must advance from match 1 to match 2, not be swallowed or reset")
        XCTAssertFalse(fc.pendingRegexAdvance != nil, "the deferred advance must be consumed by the publish")
        let sel = try XCTUnwrap(rig.view.selection)
        XCTAssertEqual(sel.anchor.line, fc.findMatches[1].line)
    }

    func test_nextMatchDuringStaleRescan_backward_wrapsFromAnchorAfterPublish() throws {
        let rig = try staleRescanFixture()
        let fc = rig.fc
        fc.advanceFind(direction: .backward)
        let republished = pump(until: 3.0) { fc.findMatchesSeq == rig.view.currentSnapshot?.sequenceID && !fc.findMatches.isEmpty }
        XCTAssertTrue(republished, "the stale rescan must publish")
        XCTAssertEqual(fc.findMatches.count, 3)
        XCTAssertEqual(fc.findCurrentIndex, 2, "Cmd-Shift-G from match 1 mid-rescan must wrap to the last match")
        XCTAssertFalse(fc.pendingRegexAdvance != nil)
    }

    // MARK: - Stale scan must not publish (FAIL on the old behaviour)

    func test_closeBarDuringScan_dropsStalePublish() throws {
        let rig = try makeRig()
        feed(rig, lines: ["alpha one", "beta", "alpha two"])
        let bar = try startRegexScan(rig, query: "alpha")
        rig.view.findBarDidClose(bar)
        settle()
        XCTAssertNil(rig.fc.findBar)
        XCTAssertEqual(rig.fc.findQuery, "")
        assertNothingPublished(rig, context: "close bar mid-scan")
    }

    func test_closeBarDuringScan_scrollbackMatch_doesNotScrollViewport() throws {
        let rig = try makeRig()
        feed(rig, lines: ["alpha top"] + (1...14).map { "filler \($0)" })
        XCTAssertEqual(rig.view.currentSnapshot?.displayOffset, 0)
        let bar = try startRegexScan(rig, query: "alpha")
        rig.view.findBarDidClose(bar)
        settle()
        assertNothingPublished(rig, context: "close bar mid-scan (scrollback match)")
        XCTAssertEqual(rig.view.currentSnapshot?.displayOffset, 0,
                       "a dropped scan must not scroll the viewport to a match for a closed find bar")
    }

    func test_clearQueryDuringScan_dropsStalePublish() throws {
        let rig = try makeRig()
        feed(rig, lines: ["alpha one", "beta", "alpha two"])
        let bar = try startRegexScan(rig, query: "alpha")
        bar.setQuery("")
        settle()
        XCTAssertEqual(rig.fc.findQuery, "")
        assertNothingPublished(rig, context: "clear query mid-scan")
    }

    func test_invalidRegexEditDuringScan_dropsStalePublish() throws {
        let rig = try makeRig()
        feed(rig, lines: ["alpha one", "beta", "alpha two"])
        let bar = try startRegexScan(rig, query: "alpha")
        bar.setQuery("(")   // unbalanced paren: invalid regex
        settle()
        XCTAssertEqual(rig.fc.findQuery, "(")
        assertNothingPublished(rig, context: "invalid-regex edit mid-scan")
    }

    func test_toggleRegexOffDuringScan_substringResultsWin() throws {
        let rig = try makeRig()
        feed(rig, lines: ["alpha one", "beta", "alpha two"])
        // "al.ha" matches "alpha" as a regex but matches nothing as a literal.
        let bar = try startRegexScan(rig, query: "al.ha")
        bar.toggleRegexMode(nil)   // re-runs the query as a synchronous substring search
        XCTAssertFalse(bar.options.regex)
        XCTAssertEqual(rig.fc.findMatches.count, 0, "fixture: literal 'al.ha' has no matches")
        settle()
        XCTAssertEqual(rig.fc.findQuery, "al.ha")
        XCTAssertEqual(rig.fc.findMatches.count, 0,
                       "the superseded regex scan must not overwrite the literal search's (empty) results")
        XCTAssertNil(rig.view.selection, "no literal match -> no selection")
    }

    func test_sessionResetDuringPendingAdvance_dropsEverything() throws {
        let rig = try staleRescanFixture()
        let fc = rig.fc
        fc.advanceFind(direction: .forward)   // starts a rescan and defers the advance
        _ = try XCTUnwrap(fc.pendingRegexAdvance, "fixture: the advance must be pending behind the in-flight rescan")
        rig.view.session = nil                // resets find state
        XCTAssertEqual(fc.findQuery, "")
        XCTAssertFalse(fc.pendingRegexAdvance != nil,
                       "resetting the view's session must also drop a deferred Cmd-G")
        settle()
        XCTAssertFalse(fc.pendingRegexAdvance != nil)
        assertNothingPublished(rig, context: "session reset mid-rescan")
    }

    func test_closeBarDuringSecondScan_keepsPriorSelection() throws {
        let rig = try makeRig()
        feed(rig, lines: ["alpha one", "beta", "alpha two"])
        let bar = try completeRegexScan(rig, query: "alpha")
        let before = try XCTUnwrap(rig.view.selection)
        XCTAssertEqual(before.anchor.line, 0)
        bar.setQuery("two")                    // second scan in flight; first match would be line 2
        rig.view.findBarDidClose(bar)
        settle()
        let fc = rig.fc
        XCTAssertEqual(fc.findMatches.count, 0)
        XCTAssertNil(fc.findMatchesSeq)
        let after = try XCTUnwrap(rig.view.selection, "closing the bar preserves the selection")
        XCTAssertEqual(after.anchor.line, 0,
                       "the selection from before the close must not be replaced by a dropped scan's match")
        XCTAssertEqual(after.anchor.col, before.anchor.col)
        XCTAssertEqual(after.cursor.col, before.cursor.col)
    }
}
