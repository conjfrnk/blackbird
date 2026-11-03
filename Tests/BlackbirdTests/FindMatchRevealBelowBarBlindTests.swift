import XCTest
import AppKit
import Metal
@testable import Blackbird
import BBCore

/// Blind behaviour tests for WHERE the find bar puts the highlighted match.
/// Spec, not implementation:
///
///  The find bar is an opaque 32 pt strip pinned to the top of the terminal
///  grid. It paints over the first viewport rows (rows 0 and 1 entirely and
///  a slice of row 2 at typical font sizes). A match that the user is asked
///  to look at (the first match of a new query, or the target of Cmd-G /
///  Cmd-Shift-G) is useless if it sits under that strip: the label says
///  "k / N" and the viewport scrolls, but the highlighted text cannot be
///  seen. So after every find navigation the highlighted match's viewport
///  row must lie entirely BELOW the bar's bottom edge.
///
///  This needs the buffer to have lines ABOVE the match to scroll down
///  into view, so every fixture puts at least 10 filler lines above the
///  first match. (The very oldest line of the whole buffer can never be
///  shown below row 0, and nothing can be asserted about it.)
///
///  Three situations are covered:
///   - a new query whose first match lives in scrollback (the viewport is
///     at the live bottom, so the find must scroll to reveal it);
///   - Cmd-G / Cmd-Shift-G stepping to other scrollback matches;
///   - a first match that is ALREADY on screen, but on viewport row 0 or 1,
///     i.e. visible to the grid and hidden under the bar. It must still be
///     moved clear of the bar, not left where it is because it was "on
///     screen".
///
/// Geometry is measured, not assumed: the bar's frame comes from the live
/// `FindBar` view, the row's position from `TerminalView.cellOriginPx`, the
/// production grid-to-view mapping (both in the view's coordinate space; the
/// bar's bottom edge is converted to the same top-down measure).
///
/// Fixture: headless `TerminalView` + headless `TerminalSession` (real BBTerm,
/// no PTY, no window, no MainWindowController), grid 40x12. 55 short lines
/// with "needle" on buffer lines 10, 25 and 40 (about 44 history rows).
/// Cost: a few KB of cells; each test pumps the main runloop for ~1-4 s of
/// wall time. No shell, no child process.
@MainActor
final class FindMatchRevealBelowBarBlindTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        TestHostTermination.shared.register()
    }

    // The bar is a fixed 32 pt tall but the grid's row height follows the
    // user's font preference (a 32 pt font makes ONE row taller than the
    // whole bar, which would hide the bug). Pin a typical 13 pt Menlo for
    // the suite and restore the user's preference afterwards.
    private var savedFontSize: Double = 13
    private var savedFontName: String = "Menlo"

    override func setUp() {
        super.setUp()
        savedFontSize = Preferences.shared.fontSize
        savedFontName = Preferences.shared.fontName
        Preferences.shared.fontSize = 13
        Preferences.shared.fontName = "Menlo"
        pump(until: 0.1) { false }
    }

    override func tearDown() {
        Preferences.shared.fontSize = savedFontSize
        Preferences.shared.fontName = savedFontName
        pump(until: 0.1) { false }
        super.tearDown()
    }

    // MARK: - Fixture

    private struct Rig {
        let view: TerminalView
        let session: TerminalSession
        var fc: FindController { view.findController }
    }

    private static let gridRows = 12

    private func makeRig(file: StaticString = #filePath, line: UInt = #line) throws -> Rig {
        let view = try XCTUnwrap(TerminalView.makeHeadlessForTests(), "Metal device required", file: file, line: line)
        let session = TerminalSession.makeHeadlessForTests()
        session.resize(to: .init(cols: 40, rows: UInt16(Self.gridRows)))
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

    /// Unconditionally run the main runloop for `seconds` (the find refresh
    /// debounce is 100 ms; the default is several multiples of it).
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

    /// 10 head lines, then three "needle" matches 15 lines apart, with 14
    /// fillers between and after. Match 1 is on buffer line 10 (10 rows of
    /// history above it, so it CAN be shown on any viewport row 0...10).
    private static let lines: [String] = {
        var l = (1...10).map { "head h\($0)" }
        l += ["needle one"]
        l += (1...14).map { "filler a\($0)" }
        l += ["needle two"]
        l += (1...14).map { "filler b\($0)" }
        l += ["needle three"]
        l += (1...14).map { "filler c\($0)" }
        return l
    }()

    private func displayOffset(_ rig: Rig) -> Int {
        rig.view.currentSnapshot?.displayOffset ?? -1
    }

    private func label(_ rig: Rig) -> String {
        rig.fc.findBar?._matchLabelStringForTests() ?? "<no bar>"
    }

    /// Feed the fixture and check the buffer really has the scrollback the
    /// scenarios need, so the tests cannot pass or fail for lack of room.
    private func makeFedRig(file: StaticString = #filePath, line: UInt = #line) throws -> Rig {
        let rig = try makeRig(file: file, line: line)
        feed(rig, lines: Self.lines, file: file, line: line)
        XCTAssertEqual(rig.view.currentSnapshot?.rows, Self.gridRows,
                       "fixture: the grid must be \(Self.gridRows) rows tall", file: file, line: line)
        XCTAssertGreaterThanOrEqual(rig.view.currentSnapshot?.historySize ?? 0, 40,
                                    "fixture: all three matches must be in scrollback", file: file, line: line)
        XCTAssertEqual(displayOffset(rig), 0, "fixture: the viewport starts at the live bottom", file: file, line: line)
        return rig
    }

    // MARK: - Geometry

    /// The bar's vertical extent in the view's TOP-DOWN measure (distance
    /// from the view's top edge), the same measure `cellOriginPx` uses.
    private func barExtentTopDown(_ rig: Rig, bar: FindBar,
                                  file: StaticString = #filePath, line: UInt = #line) throws -> (top: CGFloat, bottom: CGFloat) {
        let parent = try XCTUnwrap(bar.superview, "the find bar must be installed in a view hierarchy", file: file, line: line)
        let r = rig.view.convert(bar.frame, from: parent)
        if rig.view.isFlipped { return (r.minY, r.maxY) }
        let h = rig.view.bounds.height
        return (h - r.maxY, h - r.minY)
    }

    /// Assert the match the controller is currently on: (1) really sits on a
    /// viewport row showing `expectedRowPrefix` (proves the row arithmetic
    /// and that the viewport actually moved to it), and (2) that row lies
    /// entirely below the bar's bottom edge.
    private func assertCurrentMatchClearsBar(_ rig: Rig, bar: FindBar, expectedRowPrefix: String, step: String,
                                             file: StaticString = #filePath, line: UInt = #line) throws {
        let fc = rig.fc
        let snap = try XCTUnwrap(rig.view.currentSnapshot, "\(step): a snapshot must exist", file: file, line: line)
        let idx = fc.findCurrentIndex
        guard idx >= 0, idx < fc.findMatches.count else {
            XCTFail("\(step): findCurrentIndex \(idx) out of range for \(fc.findMatches.count) matches", file: file, line: line)
            return
        }
        let viewportRow = Int(fc.findMatches[idx].line) + snap.displayOffset
        guard viewportRow >= 0, viewportRow < snap.rows else {
            XCTFail("\(step): the current match (index \(idx)) must be on screen; it is at viewport row \(viewportRow) "
                    + "of \(snap.rows) (displayOffset \(snap.displayOffset))", file: file, line: line)
            return
        }
        let rowText = snap.visibleRowsAsText()[viewportRow]
        XCTAssertTrue(rowText.hasPrefix(expectedRowPrefix),
                      "\(step): viewport row \(viewportRow) should show '\(expectedRowPrefix)'; shows '\(rowText)'",
                      file: file, line: line)

        let extent = try barExtentTopDown(rig, bar: bar, file: file, line: line)
        let rowTop = rig.view.cellOriginPx(row: viewportRow, col: 0).y
        let rowBottom = rowTop + rig.view.metrics.cellHeight
        let hiddenPoints = max(0, extent.bottom - rowTop)
        // 0.5 pt tolerance for pixel rounding only.
        XCTAssertGreaterThanOrEqual(
            rowTop, extent.bottom - 0.5,
            "\(step): the highlighted match ('\(expectedRowPrefix)', label '\(label(rig))') is on viewport row \(viewportRow) "
            + "spanning y \(rowTop)..\(rowBottom) (cellHeight \(rig.view.metrics.cellHeight)), but the opaque find bar covers "
            + "y \(extent.top)..\(extent.bottom): \(hiddenPoints) pt of the match row are hidden under the bar. "
            + "displayOffset \(snap.displayOffset)",
            file: file, line: line)
    }

    /// Open the bar, type `query`, and wait for the matches and the
    /// post-search refresh window. Does NOT assert where the viewport is.
    @discardableResult
    private func openFindAndType(_ rig: Rig, query: String,
                                 file: StaticString = #filePath, line: UInt = #line) throws -> FindBar {
        let fc = rig.fc
        fc.installFindBar()
        let bar = try XCTUnwrap(fc.findBar, "find bar must open", file: file, line: line)
        // Precondition: at this text size the bar really does cover viewport
        // rows 0 and 1 (row 1 starts above the bar's bottom edge), so "a match
        // on row 1 is hidden" is a real scenario and not a vacuous one.
        let extent = try barExtentTopDown(rig, bar: bar, file: file, line: line)
        let row1Top = rig.view.cellOriginPx(row: 1, col: 0).y
        XCTAssertLessThan(row1Top, extent.bottom,
                          "fixture: the bar (y \(extent.top)..\(extent.bottom)) must cover viewport row 1 (top y \(row1Top), "
                          + "cellHeight \(rig.view.metrics.cellHeight)); the font pin did not take effect",
                          file: file, line: line)
        bar.setQuery(query)
        let found = pump(until: 3.0) { fc.findMatches.count == 3 }
        XCTAssertTrue(found, "fixture: query '\(query)' must find exactly 3 matches; got \(fc.findMatches.count)",
                      file: file, line: line)
        // Several multiples of the 100 ms refresh debounce, so any reveal
        // scroll (immediate or deferred) has landed and been refreshed.
        settle(0.6)
        let fresh = pump(until: 3.0) { fc.findMatchesSeq == rig.view.currentSnapshot?.sequenceID }
        XCTAssertTrue(fresh, "fixture: matches must be fresh vs the live snapshot", file: file, line: line)
        XCTAssertEqual(fc.findMatches.count, 3, "fixture: 3 matches after settling", file: file, line: line)
        XCTAssertEqual(fc.findCurrentIndex, 0, "fixture: a new query starts on match 1", file: file, line: line)
        XCTAssertEqual(label(rig), "1 / 3", "fixture: label after a new query", file: file, line: line)
        return bar
    }

    // MARK: - Tests

    /// Headline: the viewport is at the live bottom, the first match is in
    /// scrollback. Typing the query scrolls it into view, but it must not
    /// land under the bar.
    func test_newQuery_firstMatchInScrollback_isRevealedBelowTheBar() throws {
        let rig = try makeFedRig()
        let bar = try openFindAndType(rig, query: "needle")
        XCTAssertGreaterThan(displayOffset(rig), 0,
                             "precondition: the first match is in scrollback, so the find must have scrolled the viewport (displayOffset \(displayOffset(rig)))")

        try assertCurrentMatchClearsBar(rig, bar: bar, expectedRowPrefix: "needle one", step: "new query, match 1/3")
        withExtendedLifetime(rig) {}
    }

    /// Cmd-Shift-G walks to older matches: 1/3 wraps to 3/3, then 2/3. Each
    /// stop is a scroll into history; none may land under the bar.
    func test_cmdShiftG_toOlderScrollbackMatches_isRevealedBelowTheBar() throws {
        let rig = try makeFedRig()
        let bar = try openFindAndType(rig, query: "needle")
        let fc = rig.fc

        rig.view.performFindPreviousAction(nil)   // 1/3 wraps to 3/3
        settle(0.6)
        XCTAssertEqual(fc.findCurrentIndex, 2, "precondition: Cmd-Shift-G from 1/3 wraps to 3/3; label '\(label(rig))'")
        try assertCurrentMatchClearsBar(rig, bar: bar, expectedRowPrefix: "needle three", step: "Cmd-Shift-G to 3/3")

        rig.view.performFindPreviousAction(nil)   // 3/3 to 2/3 (an older match)
        settle(0.6)
        XCTAssertEqual(fc.findCurrentIndex, 1, "precondition: Cmd-Shift-G from 3/3 steps back to 2/3; label '\(label(rig))'")
        try assertCurrentMatchClearsBar(rig, bar: bar, expectedRowPrefix: "needle two", step: "Cmd-Shift-G to 2/3")

        rig.view.performFindPreviousAction(nil)   // 2/3 to 1/3 (oldest)
        settle(0.6)
        XCTAssertEqual(fc.findCurrentIndex, 0, "precondition: Cmd-Shift-G from 2/3 steps back to 1/3; label '\(label(rig))'")
        try assertCurrentMatchClearsBar(rig, bar: bar, expectedRowPrefix: "needle one", step: "Cmd-Shift-G back to 1/3")
        withExtendedLifetime(rig) {}
    }

    /// Cmd-G walks forward through the same scrollback matches.
    func test_cmdG_throughScrollbackMatches_isRevealedBelowTheBar() throws {
        let rig = try makeFedRig()
        let bar = try openFindAndType(rig, query: "needle")
        let fc = rig.fc

        rig.view.performFindNextAction(nil)   // 1/3 to 2/3
        settle(0.6)
        XCTAssertEqual(fc.findCurrentIndex, 1, "precondition: Cmd-G from 1/3 advances to 2/3; label '\(label(rig))'")
        try assertCurrentMatchClearsBar(rig, bar: bar, expectedRowPrefix: "needle two", step: "Cmd-G to 2/3")

        rig.view.performFindNextAction(nil)   // 2/3 to 3/3
        settle(0.6)
        XCTAssertEqual(fc.findCurrentIndex, 2, "precondition: Cmd-G from 2/3 advances to 3/3; label '\(label(rig))'")
        try assertCurrentMatchClearsBar(rig, bar: bar, expectedRowPrefix: "needle three", step: "Cmd-G to 3/3")

        rig.view.performFindNextAction(nil)   // 3/3 wraps to 1/3
        settle(0.6)
        XCTAssertEqual(fc.findCurrentIndex, 0, "precondition: Cmd-G from 3/3 wraps to 1/3; label '\(label(rig))'")
        try assertCurrentMatchClearsBar(rig, bar: bar, expectedRowPrefix: "needle one", step: "Cmd-G wrapping to 1/3")
        withExtendedLifetime(rig) {}
    }

    /// The first match is already on screen but sits on viewport row
    /// `startRow` (0 or 1), i.e. under the bar. It is not "off-screen", yet
    /// it must still be moved clear of the bar (there are 10 lines above it
    /// in scrollback to scroll down into view).
    private func runMatchAlreadyOnViewportRow(_ startRow: Int, file: StaticString = #filePath, line: UInt = #line) throws {
        let rig = try makeFedRig(file: file, line: line)
        let snap0 = try XCTUnwrap(rig.view.currentSnapshot, "fixture: snapshot", file: file, line: line)
        // "needle one" is on buffer line (10 - historySize); it shows on
        // viewport row `startRow` when displayOffset == startRow - line.
        let target = startRow - (10 - snap0.historySize)
        XCTAssertGreaterThan(target, 0, "fixture: target displayOffset", file: file, line: line)
        XCTAssertLessThanOrEqual(target, snap0.historySize, "fixture: target within scrollback", file: file, line: line)
        rig.session.scroll(delta: Int32(target))
        let scrolled = pump(until: 3.0) { self.displayOffset(rig) == target }
        XCTAssertTrue(scrolled, "fixture: the viewport must reach displayOffset \(target); at \(displayOffset(rig))", file: file, line: line)
        let rowsBefore = rig.view.currentSnapshot?.visibleRowsAsText() ?? []
        XCTAssertTrue(startRow < rowsBefore.count && rowsBefore[startRow].hasPrefix("needle one"),
                      "fixture: 'needle one' must be on viewport row \(startRow) before the search; rows: \(rowsBefore)",
                      file: file, line: line)

        let bar = try openFindAndType(rig, query: "needle", file: file, line: line)
        try assertCurrentMatchClearsBar(rig, bar: bar, expectedRowPrefix: "needle one",
                                        step: "match 1/3 was already on viewport row \(startRow) (displayOffset \(target) before the search)",
                                        file: file, line: line)
        withExtendedLifetime(rig) {}
    }

    func test_newQuery_firstMatchAlreadyOnViewportRow0_isMovedBelowTheBar() throws {
        try runMatchAlreadyOnViewportRow(0)
    }

    func test_newQuery_firstMatchAlreadyOnViewportRow1_isMovedBelowTheBar() throws {
        try runMatchAlreadyOnViewportRow(1)
    }

    // MARK: - Bar height changes (added with the review fix; not blind-authored)

    /// The replace row grows the bar from 32 pt to 60 pt. A match that was
    /// placed just below the short bar must be moved clear of the tall one:
    /// the label still says "1 / 3" but the match must not end up hidden.
    func test_cmdOptE_expandingReplaceRow_keepsCurrentMatchBelowTheTallerBar() throws {
        let rig = try makeFedRig()
        let bar = try openFindAndType(rig, query: "needle")
        XCTAssertEqual(bar.frame.height, 32, "fixture: the collapsed bar is 32 pt")
        try assertCurrentMatchClearsBar(rig, bar: bar, expectedRowPrefix: "needle one", step: "before expanding the replace row")
        let snap = try XCTUnwrap(rig.view.currentSnapshot, "fixture: snapshot")
        let rowBefore = Int(rig.fc.findMatches[0].line) + snap.displayOffset

        rig.view.performReplaceCurrent(nil)   // Cmd-Opt-E on an open bar with the replace row collapsed
        XCTAssertTrue(bar.isReplaceVisible, "Cmd-Opt-E expands the replace row")
        XCTAssertEqual(bar.frame.height, bar.preferredHeight,
                       "the bar's real height must agree with preferredHeight (\(bar.preferredHeight))")
        // Non-vacuous: the taller bar reaches over the row the match sat on.
        let tall = try barExtentTopDown(rig, bar: bar)
        let oldRowTop = rig.view.cellOriginPx(row: rowBefore, col: 0).y
        XCTAssertGreaterThan(tall.bottom, oldRowTop + 0.5,
                             "fixture: the 60 pt bar (bottom y \(tall.bottom)) must cover the row the match was on (top y \(oldRowTop))")

        settle(0.6)
        XCTAssertEqual(rig.fc.findCurrentIndex, 0, "the expand must not change which match is current")
        try assertCurrentMatchClearsBar(rig, bar: bar, expectedRowPrefix: "needle one", step: "after expanding the replace row")
        withExtendedLifetime(rig) {}
    }

    /// Same, through the path the caret button takes (`setReplaceVisible`).
    func test_setReplaceVisible_afterReveal_keepsCurrentMatchBelowTheTallerBar() throws {
        let rig = try makeFedRig()
        let bar = try openFindAndType(rig, query: "needle")
        bar.setReplaceVisible(true)
        XCTAssertEqual(bar.frame.height, 60, "the expanded bar is 60 pt")
        settle(0.6)
        try assertCurrentMatchClearsBar(rig, bar: bar, expectedRowPrefix: "needle one", step: "after setReplaceVisible(true)")
        withExtendedLifetime(rig) {}
    }

    /// Cmd-Opt-E with no bar open installs the bar AND expands it; the frame
    /// must be the expanded height, not left at the collapsed 32 pt.
    func test_cmdOptE_withNoBarOpen_installsAnExpandedHeightBar() throws {
        let rig = try makeFedRig()
        rig.view.performReplaceCurrent(nil)
        let bar = try XCTUnwrap(rig.fc.findBar, "Cmd-Opt-E must open the bar")
        XCTAssertTrue(bar.isReplaceVisible)
        XCTAssertEqual(bar.frame.height, bar.preferredHeight,
                       "the bar's real height must agree with preferredHeight (\(bar.preferredHeight))")
        withExtendedLifetime(rig) {}
    }

    /// The bar growing only rescues a match hidden under it. A match the user
    /// deliberately scrolled out of view must not drag the viewport back.
    func test_expandingReplaceRow_doesNotYankAViewportScrolledAwayFromTheMatch() throws {
        let rig = try makeFedRig()
        let bar = try openFindAndType(rig, query: "needle")
        let fc = rig.fc
        rig.session.scroll(delta: -Int32(displayOffset(rig)))   // back to the live bottom
        XCTAssertTrue(pump(until: 3.0) { self.displayOffset(rig) == 0 }, "fixture: viewport back at the live bottom")
        settle(0.6)
        XCTAssertEqual(fc.findMatchesSeq, rig.view.currentSnapshot?.sequenceID,
                       "fixture: matches must be fresh, or the resize reveal is skipped for the wrong reason")

        bar.setReplaceVisible(true)
        settle(0.6)
        XCTAssertEqual(displayOffset(rig), 0, "expanding the replace row must not scroll a viewport the user moved away")
        withExtendedLifetime(rig) {}
    }
}

/// Pure geometry behind the reveal: no view, no session.
final class FindRevealGeometryTests: XCTestCase {

    func test_rowsHidden_countsRowsTheBarReachesInto() {
        XCTAssertEqual(FindController.rowsHidden(byOverlap: 32, cellHeight: 15), 3, "32 pt reaches 2 pt into row index 2, so rows 0-2 are hidden")
        XCTAssertEqual(FindController.rowsHidden(byOverlap: 60, cellHeight: 15), 4)
        XCTAssertEqual(FindController.rowsHidden(byOverlap: 45, cellHeight: 15), 3, "an edge exactly on a row boundary hides no part of the next row")
        XCTAssertEqual(FindController.rowsHidden(byOverlap: 45.4, cellHeight: 15), 3, "pixel-rounding slack")
        XCTAssertEqual(FindController.rowsHidden(byOverlap: 46, cellHeight: 15), 4, "1 pt into the next row hides it")
        XCTAssertEqual(FindController.rowsHidden(byOverlap: 0, cellHeight: 15), 0)
        XCTAssertEqual(FindController.rowsHidden(byOverlap: -10, cellHeight: 15), 0, "a bar above the grid hides nothing")
    }

    func test_rowsHidden_degenerateInputsHideNothing() {
        XCTAssertEqual(FindController.rowsHidden(byOverlap: 32, cellHeight: 0), 0)
        XCTAssertEqual(FindController.rowsHidden(byOverlap: 32, cellHeight: -1), 0)
        XCTAssertEqual(FindController.rowsHidden(byOverlap: .nan, cellHeight: 15), 0)
        XCTAssertEqual(FindController.rowsHidden(byOverlap: .infinity, cellHeight: 15), 0)
        XCTAssertEqual(FindController.rowsHidden(byOverlap: 32, cellHeight: .nan), 0)
        XCTAssertLessThanOrEqual(FindController.rowsHidden(byOverlap: 1e300, cellHeight: 1e-300), 1_000_000, "must not trap on absurd ratios")
    }

    private func delta(row: Int, hidden: Int = 3, rows: Int = 12, history: Int = 100, follow: Bool = true) -> Int {
        FindController.revealScrollDelta(matchRow: row, hiddenRows: hidden, rows: rows,
                                         scrollableHistory: history, followOffscreen: follow)
    }

    func test_revealScrollDelta_landsOnTheFirstRowBelowTheBar() {
        XCTAssertEqual(delta(row: 0), 3)
        XCTAssertEqual(delta(row: 2), 1, "a partly covered row still moves")
        XCTAssertEqual(delta(row: -4), 7, "an off-screen match lands on the first visible row, not row 0")
    }

    func test_revealScrollDelta_leavesVisibleMatchesAlone() {
        XCTAssertEqual(delta(row: 3), 0, "the first clear row stays put")
        XCTAssertEqual(delta(row: 7), 0)
        XCTAssertEqual(delta(row: 11), 0, "the last row stays put")
    }

    func test_revealScrollDelta_matchBelowTheGridScrollsOntoTheLastRow() {
        XCTAssertEqual(delta(row: 14), -3)
        XCTAssertEqual(delta(row: 12), -1)
    }

    func test_revealScrollDelta_neverAsksForMoreHistoryThanExists() {
        XCTAssertEqual(delta(row: 1, history: 0), 0, "nothing above: no scroll at all")
        XCTAssertEqual(delta(row: 1, history: 1), 1, "partial: as far as the history allows")
        XCTAssertEqual(delta(row: 0, history: -5), 0, "a bogus negative budget is no budget")
    }

    func test_revealScrollDelta_shortGridKeepsATargetRow() {
        XCTAssertEqual(delta(row: 0, hidden: 5, rows: 2), 1, "target is capped to the last row of a 2-row grid")
        XCTAssertEqual(delta(row: 0, hidden: 5, rows: 1), 0, "a 1-row grid has only row 0")
    }

    func test_revealScrollDelta_barResizeOnlyRescuesAMatchUnderTheBar() {
        XCTAssertEqual(delta(row: 1, follow: false), 2, "under the bar: moved")
        XCTAssertEqual(delta(row: 0, follow: false), 3)
        XCTAssertEqual(delta(row: -2, follow: false), 0, "scrolled off the top on purpose: left alone")
        XCTAssertEqual(delta(row: 14, follow: false), 0, "scrolled off the bottom on purpose: left alone")
    }
}
