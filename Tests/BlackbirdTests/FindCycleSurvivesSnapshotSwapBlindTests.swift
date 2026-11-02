import XCTest
import AppKit
import Metal
@testable import Blackbird
import BBCore

/// Blind behaviour tests for the find bar's cycle position surviving the
/// snapshot swaps it (or the user, or the child process) causes. Spec, not
/// implementation:
///
///  With the find bar open and a live query, the user's position in the match
///  cycle (`findCurrentIndex`, the "k / N" label, the highlighted match) and
///  the viewport are THE USER'S STATE. They may only change because the user
///  did something find-related (typed a query, pressed Cmd-G / Cmd-Shift-G,
///  closed the bar) - never because time passed, because the viewport moved,
///  or because unrelated output arrived and the match set was refreshed:
///
///   - Cmd-G to a match that lives far away in scrollback scrolls the
///     viewport there. That scroll publishes a new snapshot. The position
///     ("2 / 3") and the viewport must survive the debounced refresh that
///     follows (`FindController.refreshCoalesceInterval` is 100 ms), so that
///     the NEXT Cmd-G continues from match 2 to match 3, wraps to match 1,
///     and Cmd-Shift-G walks backwards likewise.
///   - A wheel / trackpad scroll that moves the highlighted match off-screen
///     is the user looking elsewhere; the view must not be yanked back to the
///     match 100 ms later.
///   - Output arriving while the bar is open (scrolling or not) refreshes the
///     match set, but when no matches were added or removed the cycle must
///     still be on the same match and the viewport must stay pinned to the
///     live bottom.
///   - Regex mode behaves identically (its refresh is an async scan).
///
/// Matches that all fit on one screen and need no scroll never swap a
/// snapshot, so the pre-existing cycling tests pass trivially; every test
/// here either scrolls between matches or publishes output, which is what
/// makes the refresh window observable.
///
/// Fixture: headless `TerminalView` + headless `TerminalSession` (real BBTerm,
/// no PTY, no window, no MainWindowController), grid 40x6. The scrollback
/// fixture is 34 short lines (~29 history rows) with "needle" matches on
/// buffer lines 0, 12 and 24 - each pair more than a screen (6 rows) apart.
/// Cost: a few KB of cells; each test pumps the main runloop for between
/// ~1 s and ~3 s of wall time (the refresh debounce is 100 ms; we wait
/// several multiples of it after every action). No shell, no child process.
final class FindCycleSurvivesSnapshotSwapBlindTests: XCTestCase {

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

    /// Pump the main runloop in 5 ms slices until `condition` holds or
    /// `timeout` elapses. Returns whether the condition was met.
    @discardableResult
    private func pump(until timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date(timeIntervalSinceNow: timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.005))
        }
        return condition()
    }

    /// Unconditionally run the main runloop for `seconds`. The refresh
    /// debounce is 100 ms; the default is several multiples of it plus room
    /// for an async regex scan to publish.
    private func settle(_ seconds: TimeInterval = 0.45) {
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

    /// Three "needle" matches, each separated from the next by 11 filler
    /// lines (about two screens), and 9 trailing fillers, so on a 6-row grid
    /// ALL three live in scrollback and every Cmd-G must scroll.
    private static let farLines: [String] = {
        var l = ["needle one"]
        l += (1...11).map { "filler a\($0)" }
        l += ["needle two"]
        l += (1...11).map { "filler b\($0)" }
        l += ["needle three"]
        l += (1...9).map { "filler c\($0)" }
        return l
    }()

    /// Three matches that fit on one 6-row screen with the cursor on the last
    /// row, so no history exists yet and Cmd-G never needs to scroll.
    private static let nearLines = ["needle a", "x1", "needle b", "x2", "needle c"]

    private func displayOffset(_ rig: Rig) -> Int {
        rig.view.currentSnapshot?.displayOffset ?? -1
    }

    /// Screen row (0 = top of the viewport) of the match at cycle `index`
    /// per the controller's CURRENT match set, or nil when out of range.
    private func screenRow(_ rig: Rig, matchIndex index: Int) -> Int? {
        guard let snap = rig.view.currentSnapshot, index >= 0, index < rig.fc.findMatches.count else { return nil }
        return Int(rig.fc.findMatches[index].line) + snap.displayOffset
    }

    private func isOnScreen(_ rig: Rig, matchIndex index: Int) -> Bool {
        guard let row = screenRow(rig, matchIndex: index), let rows = rig.view.currentSnapshot?.rows else { return false }
        return row >= 0 && row < rows
    }

    private func label(_ rig: Rig) -> String {
        rig.fc.findBar?._matchLabelStringForTests() ?? "<no bar>"
    }

    /// First 10 characters of the viewport row the selection's anchor sits on.
    private func selectedRowPrefix(_ rig: Rig) -> String? {
        guard let sel = rig.view.selection, let snap = rig.view.currentSnapshot else { return nil }
        let row = Int(sel.anchor.line) + snap.displayOffset
        let rows = snap.visibleRowsAsText()
        guard row >= 0, row < rows.count else { return "<selection row \(row) off-screen>" }
        return String(rows[row].prefix(10))
    }

    /// Open the bar and type `query` like the user would. Then wait for the
    /// first match to be scrolled into view (if it needs to be) and for the
    /// post-search refresh window to elapse, and assert the baseline: three
    /// fresh matches, on match 1 / 3, with match 1 on screen.
    @discardableResult
    private func openFindAndSettle(_ rig: Rig, query: String, regex: Bool = false,
                                   file: StaticString = #filePath, line: UInt = #line) throws -> FindBar {
        let fc = rig.fc
        fc.installFindBar()
        let bar = try XCTUnwrap(fc.findBar, "find bar must open", file: file, line: line)
        if regex {
            bar.toggleRegexMode(nil)
            XCTAssertTrue(bar.options.regex, "fixture: regex mode must be on", file: file, line: line)
        }
        bar.setQuery(query)
        let found = pump(until: 3.0) { fc.findMatches.count == 3 }
        XCTAssertTrue(found, "fixture: query '\(query)' must find exactly 3 matches; got \(fc.findMatches.count)",
                      file: file, line: line)
        let onScreen = pump(until: 3.0) { self.isOnScreen(rig, matchIndex: 0) }
        XCTAssertTrue(onScreen, "fixture: the first search must reveal match 1 (screen row \(String(describing: screenRow(rig, matchIndex: 0))), "
                      + "displayOffset \(displayOffset(rig)))", file: file, line: line)
        settle()
        let fresh = pump(until: 3.0) { fc.findMatchesSeq == rig.view.currentSnapshot?.sequenceID }
        XCTAssertTrue(fresh, "fixture: matches must be fresh vs the live snapshot before the test acts",
                      file: file, line: line)
        XCTAssertEqual(fc.findMatches.count, 3, "fixture: 3 matches after settling", file: file, line: line)
        XCTAssertEqual(fc.findCurrentIndex, 0, "fixture: a new query starts on match 1", file: file, line: line)
        XCTAssertEqual(label(rig), "1 / 3", "fixture: label after a new query", file: file, line: line)
        XCTAssertTrue(isOnScreen(rig, matchIndex: 0), "fixture: match 1 is on screen after settling", file: file, line: line)
        return bar
    }

    // MARK: - Cmd-G / Cmd-Shift-G to a far scrollback match

    /// The headline bug: Cmd-G scrolls to match 2 (publishing a snapshot);
    /// 100 ms later the refresh must not snap back to "1 / 3" and re-scroll
    /// the viewport to match 1.
    func test_cmdG_toFarScrollbackMatch_positionAndViewportSurviveRefreshWindow() throws {
        let rig = try makeRig()
        let fc = rig.fc
        feed(rig, lines: Self.farLines)
        XCTAssertGreaterThanOrEqual(rig.view.currentSnapshot?.historySize ?? 0, 24,
                                    "fixture: all three matches must be in scrollback")
        try openFindAndSettle(rig, query: "needle")
        let offsetAtMatch1 = displayOffset(rig)

        rig.view.performFindNextAction(nil)   // Cmd-G
        XCTAssertEqual(fc.findCurrentIndex, 1, "precondition: Cmd-G advances synchronously from match 1 to match 2")
        XCTAssertEqual(label(rig), "2 / 3", "precondition: label shows 2 / 3 right after Cmd-G")
        let landed = pump(until: 3.0) { self.isOnScreen(rig, matchIndex: 1) }
        XCTAssertTrue(landed, "precondition: Cmd-G must scroll the viewport to match 2 (displayOffset \(displayOffset(rig)))")
        let offsetAtMatch2 = displayOffset(rig)
        XCTAssertNotEqual(offsetAtMatch2, offsetAtMatch1,
                          "precondition: match 2 is far from match 1, so the viewport had to scroll (both at displayOffset \(offsetAtMatch1))")

        // Several multiples of the 100 ms refresh debounce.
        settle(0.5)

        XCTAssertEqual(fc.findCurrentIndex, 1,
                       "cycle position must stay on match 2 after the refresh window; findCurrentIndex=\(fc.findCurrentIndex)")
        XCTAssertEqual(label(rig), "2 / 3",
                       "label must still read 2 / 3 after the refresh window; got '\(label(rig))'")
        XCTAssertEqual(displayOffset(rig), offsetAtMatch2,
                       "viewport must stay on match 2 (displayOffset \(offsetAtMatch2)), not be yanked back to match 1 (displayOffset \(offsetAtMatch1)); "
                       + "got \(displayOffset(rig))")
        XCTAssertEqual(selectedRowPrefix(rig), "needle two",
                       "the highlighted selection must still be match 2's row")
        XCTAssertEqual(fc.findMatches.count, 3, "no matches were added or removed")
        withExtendedLifetime(rig) {}
    }

    /// "It never gets past match 2": repeated Cmd-G with a pause between
    /// presses must walk 2, 3, wrap to 1.
    func test_cmdG_repeated_walksThroughAllScrollbackMatchesAndWraps() throws {
        let rig = try makeRig()
        let fc = rig.fc
        feed(rig, lines: Self.farLines)
        try openFindAndSettle(rig, query: "needle")

        var indices: [Int] = []
        var labels: [String] = []
        var rowsOfCurrentMatch: [String] = []
        for _ in 0..<3 {
            rig.view.performFindNextAction(nil)
            settle(0.45)
            indices.append(fc.findCurrentIndex)
            labels.append(label(rig))
            rowsOfCurrentMatch.append(selectedRowPrefix(rig) ?? "<nil>")
        }
        XCTAssertEqual(indices, [1, 2, 0],
                       "three Cmd-G presses (0.45 s apart) from match 1 must land on match 2, 3, then wrap to 1; "
                       + "measured indices \(indices), labels \(labels)")
        XCTAssertEqual(labels, ["2 / 3", "3 / 3", "1 / 3"], "measured labels \(labels)")
        XCTAssertEqual(rowsOfCurrentMatch, ["needle two", "needle thr", "needle one"],
                       "the selection must sit on each successive match; measured \(rowsOfCurrentMatch)")
        withExtendedLifetime(rig) {}
    }

    /// Same in reverse: Cmd-Shift-G from match 1 wraps to the LAST match and
    /// then keeps walking backwards.
    func test_cmdShiftG_repeated_walksBackwardsThroughScrollbackMatches() throws {
        let rig = try makeRig()
        let fc = rig.fc
        feed(rig, lines: Self.farLines)
        try openFindAndSettle(rig, query: "needle")

        var indices: [Int] = []
        var labels: [String] = []
        var rowsOfCurrentMatch: [String] = []
        for _ in 0..<2 {
            rig.view.performFindPreviousAction(nil)
            settle(0.45)
            indices.append(fc.findCurrentIndex)
            labels.append(label(rig))
            rowsOfCurrentMatch.append(selectedRowPrefix(rig) ?? "<nil>")
        }
        XCTAssertEqual(indices, [2, 1],
                       "two Cmd-Shift-G presses from match 1 must wrap to match 3 then step back to match 2; "
                       + "measured indices \(indices), labels \(labels)")
        XCTAssertEqual(labels, ["3 / 3", "2 / 3"], "measured labels \(labels)")
        XCTAssertEqual(rowsOfCurrentMatch, ["needle thr", "needle two"],
                       "the selection must sit on each successive match; measured \(rowsOfCurrentMatch)")
        withExtendedLifetime(rig) {}
    }

    // MARK: - Wheel / trackpad scroll away from the highlighted match

    /// `TerminalView.scrollWheel` ends in `session.scroll(delta:)`. Scrolling
    /// toward the live bottom so the highlighted match leaves the viewport is
    /// the user looking elsewhere; the view must stay where the user put it.
    func test_wheelScrollAwayFromHighlightedMatch_viewIsNotYankedBack() throws {
        let rig = try makeRig()
        let fc = rig.fc
        feed(rig, lines: Self.farLines)
        try openFindAndSettle(rig, query: "needle")
        let start = displayOffset(rig)
        XCTAssertGreaterThanOrEqual(start, 12, "fixture: match 1 is at the very top of scrollback (displayOffset \(start))")

        var offsets: [Int] = []
        for step in 1...3 {
            let before = displayOffset(rig)
            rig.session.scroll(delta: -4)   // negative = toward newer content / live bottom
            let landed = pump(until: 3.0) { self.displayOffset(rig) == before - 4 }
            XCTAssertTrue(landed, "precondition: wheel step \(step) must move the viewport from displayOffset \(before) to \(before - 4); "
                          + "at \(displayOffset(rig))")
            if step == 1 {
                XCTAssertFalse(isOnScreen(rig, matchIndex: 0),
                               "precondition: the first wheel step moved the highlighted match 1 off-screen")
            }
            settle(0.35)   // > the 100 ms refresh debounce
            offsets.append(displayOffset(rig))
        }

        XCTAssertEqual(offsets, [start - 4, start - 8, start - 12],
                       "each wheel step must stick: the view must not be re-scrolled to the highlighted match 100 ms later; "
                       + "measured displayOffsets after each step \(offsets) (started at \(start))")
        XCTAssertEqual(fc.findCurrentIndex, 0, "scrolling does not move the cycle position; findCurrentIndex=\(fc.findCurrentIndex)")
        XCTAssertEqual(label(rig), "1 / 3", "label unchanged by scrolling; got '\(label(rig))'")
        withExtendedLifetime(rig) {}
    }

    // MARK: - Output arriving while the bar is open

    /// Output that does NOT scroll the grid (typing on the cursor row):
    /// a new snapshot arrives, the match set is refreshed, and the cycle must
    /// stay on match 2.
    func test_nonScrollingOutput_doesNotResetCyclePosition() throws {
        let rig = try makeRig()
        let fc = rig.fc
        feed(rig, lines: Self.nearLines)
        try openFindAndSettle(rig, query: "needle")
        XCTAssertEqual(rig.view.currentSnapshot?.historySize, 0, "fixture: nothing in scrollback yet, so Cmd-G needs no scroll")

        rig.view.performFindNextAction(nil)
        XCTAssertEqual(fc.findCurrentIndex, 1, "precondition: Cmd-G moved to match 2")
        settle(0.3)
        XCTAssertEqual(fc.findCurrentIndex, 1, "precondition: with no scroll nothing disturbs match 2 (this passes even with the bug)")
        let seqBefore = rig.view.currentSnapshot?.sequenceID

        // Output on the cursor row, no newline: the grid does not scroll.
        rig.session.feedBytesForTests(Data("tick".utf8))
        let landed = pump(until: 3.0) {
            guard let snap = rig.view.currentSnapshot else { return false }
            return snap.visibleRowsAsText().contains { $0.hasPrefix("tick") }
        }
        XCTAssertTrue(landed, "precondition: the output must reach the view")
        XCTAssertNotEqual(rig.view.currentSnapshot?.sequenceID, seqBefore, "precondition: a new snapshot was published")
        XCTAssertEqual(rig.view.currentSnapshot?.historySize, 0, "precondition: the output did not scroll the grid")

        settle(0.45)

        XCTAssertEqual(fc.findCurrentIndex, 1,
                       "output arriving must not reset the cycle to match 1; findCurrentIndex=\(fc.findCurrentIndex)")
        XCTAssertEqual(label(rig), "2 / 3", "label after output arrived; got '\(label(rig))'")
        XCTAssertEqual(fc.findMatches.count, 3, "no matches were added or removed")
        XCTAssertEqual(displayOffset(rig), 0, "viewport must stay on the live bottom; displayOffset=\(displayOffset(rig))")
        withExtendedLifetime(rig) {}
    }

    /// Streaming output that scrolls the grid, tick after tick: the position
    /// on match 2 (or 3, once the user advances) must hold on every tick and
    /// the viewport must stay pinned to the live bottom.
    func test_streamingOutput_keepsCyclePositionEveryTick() throws {
        let rig = try makeRig()
        let fc = rig.fc
        feed(rig, lines: Self.nearLines)
        try openFindAndSettle(rig, query: "needle")

        rig.view.performFindNextAction(nil)
        XCTAssertEqual(fc.findCurrentIndex, 1, "precondition: Cmd-G moved to match 2")

        var indices: [Int] = []
        var labels: [String] = []
        var offsets: [Int] = []
        for tick in 1...3 {
            let text = "tick \(tick)"
            rig.session.feedBytesForTests(Data((text + "\r\n").utf8))
            // Each tick pushes exactly one more row into history. Keyed on
            // history growth, not on viewport text, so the wait is valid even
            // if a buggy re-highlight has scrolled the viewport into scrollback.
            let landed = pump(until: 3.0) { rig.view.currentSnapshot?.historySize == tick }
            XCTAssertTrue(landed, "precondition: '\(text)' must reach the view (historySize \(String(describing: rig.view.currentSnapshot?.historySize)), expected \(tick))")
            settle(0.35)   // > the 100 ms refresh debounce
            indices.append(fc.findCurrentIndex)
            labels.append(label(rig))
            offsets.append(displayOffset(rig))
        }
        XCTAssertEqual(indices, [1, 1, 1],
                       "three output ticks must not reset the cycle from match 2 to match 1; measured indices \(indices), labels \(labels)")
        XCTAssertEqual(labels, ["2 / 3", "2 / 3", "2 / 3"], "measured labels \(labels)")
        XCTAssertEqual(offsets, [0, 0, 0],
                       "streaming output must not pull the viewport up into scrollback to re-highlight a match; measured displayOffsets \(offsets)")
        XCTAssertEqual(fc.findMatches.count, 3, "no matches were added or removed")

        // And the cycle continues from where the user was, not from match 1.
        rig.view.performFindNextAction(nil)
        XCTAssertEqual(fc.findCurrentIndex, 2, "Cmd-G after the stream continues from match 2 to match 3; findCurrentIndex=\(fc.findCurrentIndex)")
        withExtendedLifetime(rig) {}
    }

    // MARK: - Regex mode

    /// Regex search is an async scan; its refresh after a scroll-causing
    /// Cmd-G must not reset the cycle either.
    func test_regexMode_cmdG_toFarScrollbackMatch_positionAndViewportSurviveRefreshWindow() throws {
        let rig = try makeRig()
        let fc = rig.fc
        feed(rig, lines: Self.farLines)
        let bar = try openFindAndSettle(rig, query: "needle", regex: true)
        XCTAssertTrue(bar.options.regex, "fixture: still in regex mode")
        let offsetAtMatch1 = displayOffset(rig)

        rig.view.performFindNextAction(nil)   // Cmd-G
        XCTAssertEqual(fc.findCurrentIndex, 1, "precondition: Cmd-G advances from match 1 to match 2 (matches are fresh, so no deferral)")
        let landed = pump(until: 3.0) { self.isOnScreen(rig, matchIndex: 1) }
        XCTAssertTrue(landed, "precondition: Cmd-G must scroll the viewport to match 2 (displayOffset \(displayOffset(rig)))")
        let offsetAtMatch2 = displayOffset(rig)
        XCTAssertNotEqual(offsetAtMatch2, offsetAtMatch1, "precondition: the viewport had to scroll")

        // 100 ms debounce + off-main scan + main-queue publish, with margin.
        settle(0.8)

        XCTAssertEqual(fc.findCurrentIndex, 1,
                       "regex mode: cycle position must stay on match 2 after the refresh window; findCurrentIndex=\(fc.findCurrentIndex)")
        XCTAssertEqual(label(rig), "2 / 3", "regex mode: label after the refresh window; got '\(label(rig))'")
        XCTAssertEqual(displayOffset(rig), offsetAtMatch2,
                       "regex mode: viewport must stay on match 2 (displayOffset \(offsetAtMatch2)), not be yanked back to match 1 "
                       + "(displayOffset \(offsetAtMatch1)); got \(displayOffset(rig))")
        XCTAssertEqual(selectedRowPrefix(rig), "needle two", "regex mode: the selection must still be match 2's row")
        withExtendedLifetime(rig) {}
    }

    // MARK: - Regex mode: a refresh scan lands while a user-started scan is in flight

    // Written from the review finding's scenario (not blind): the debounced
    // refresh fires after a regex scan started but before it published. The
    // newer scan supersedes the older one, and must still honour what the
    // older one was owed by the user.

    /// The user types a regex whose first match is in scrollback; the refresh
    /// scan starts before the typed query's scan publishes. The first match
    /// must still be selected as "1 / 3" AND scrolled into view.
    func test_regexMode_refreshScanSupersedingTypedQueryScan_stillRevealsFirstMatch() throws {
        let rig = try makeRig()
        let fc = rig.fc
        feed(rig, lines: Self.farLines)
        XCTAssertEqual(displayOffset(rig), 0, "fixture: the viewport starts at the live bottom, away from every match")
        fc.installFindBar()
        let bar = try XCTUnwrap(fc.findBar, "find bar must open")
        bar.toggleRegexMode(nil)
        XCTAssertTrue(bar.options.regex, "fixture: regex mode must be on")

        bar.setQuery("needle")   // the user's scan is now in flight
        XCTAssertTrue(fc.findMatches.isEmpty, "fixture: the typed query's scan has not published yet")
        // The debounced refresh lands before that publish.
        fc.performSearch(query: "needle", preservingPosition: true)
        XCTAssertTrue(fc.findMatches.isEmpty, "fixture: neither scan has published yet")

        let found = pump(until: 3.0) { fc.findMatches.count == 3 }
        XCTAssertTrue(found, "the surviving scan must publish all 3 matches; got \(fc.findMatches.count)")
        let revealed = pump(until: 3.0) { self.isOnScreen(rig, matchIndex: 0) }
        XCTAssertTrue(revealed, "the typed query's first match must be scrolled into view even though a refresh scan took over "
                      + "(screen row \(String(describing: screenRow(rig, matchIndex: 0))), displayOffset \(displayOffset(rig)))")
        XCTAssertEqual(fc.findCurrentIndex, 0, "a new query starts on match 1; findCurrentIndex=\(fc.findCurrentIndex)")
        XCTAssertEqual(label(rig), "1 / 3", "label after the superseded scan; got '\(label(rig))'")
        XCTAssertEqual(selectedRowPrefix(rig), "needle one", "the selection must sit on match 1's row")
        withExtendedLifetime(rig) {}
    }

    /// Cmd-G pressed while the cached regex matches are stale defers behind a
    /// rescan; the debounced refresh scan then takes over. The deferred Cmd-G
    /// must still advance from match 1 to match 2, not be swallowed.
    func test_regexMode_refreshScanSupersedingDeferredCmdG_stillAdvances() throws {
        let rig = try makeRig()
        let fc = rig.fc
        feed(rig, lines: Self.nearLines)
        try openFindAndSettle(rig, query: "needle", regex: true)

        // Non-scrolling output makes the cached matches stale vs the live snapshot.
        rig.session.feedBytesForTests(Data("tick".utf8))
        let landed = pump(until: 3.0) {
            guard let snap = rig.view.currentSnapshot else { return false }
            return snap.visibleRowsAsText().contains { $0.hasPrefix("tick") }
        }
        XCTAssertTrue(landed, "precondition: the output must reach the view")
        XCTAssertNotEqual(fc.findMatchesSeq, rig.view.currentSnapshot?.sequenceID, "precondition: cached matches are stale")

        rig.view.performFindNextAction(nil)   // Cmd-G: the regex rescan is async, the advance is deferred
        _ = try XCTUnwrap(fc.pendingRegexAdvance, "precondition: the advance is pending behind the in-flight rescan")
        // The debounced refresh lands before that rescan publishes.
        fc.performSearch(query: "needle", preservingPosition: true)

        let found = pump(until: 3.0) { fc.findMatches.count == 3 }
        XCTAssertTrue(found, "the surviving scan must publish all 3 matches; got \(fc.findMatches.count)")
        XCTAssertEqual(fc.findCurrentIndex, 1,
                       "the Cmd-G must advance from match 1 to match 2 even though a refresh scan took over; findCurrentIndex=\(fc.findCurrentIndex)")
        XCTAssertEqual(label(rig), "2 / 3", "label after the superseded scan; got '\(label(rig))'")
        XCTAssertFalse(fc.pendingRegexAdvance != nil, "the deferred advance must be consumed by the publish")
        withExtendedLifetime(rig) {}
    }
}
