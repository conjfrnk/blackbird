import XCTest
import AppKit
import Metal
@testable import Blackbird
import BBCore

/// Blind regression tests for BUG F4b: Find across soft-wrapped rows has no
/// bound on a merged run, pays an 8-byte-per-UTF-16-unit column map even for
/// scrollback-only runs, loses cancellation granularity, and scrolls a
/// cross-wrap match into view by looking only at its START row.
///
/// Spec (observable behaviour, independent of how the fix is built):
///
///  1. BOUNDED RUNS. A soft-wrapped logical line is one searchable unit so a
///     match can straddle the right edge. That must not mean "one unbounded
///     string": the output of `cat` on a 10 MB single-line file is ~100k
///     wrapped rows. The haystack builder (`captureRows(joinSoftWrapped:
///     true)`) must hand the scan bounded pieces, so a cancelled scan stops
///     promptly (the cancel flag is only looked at between pieces), and the
///     bookkeeping that maps string offsets back to grid columns must not
///     cost 8 bytes per character of the whole run. Scrollback rows are laid
///     out one-cell-per-character, so a scrollback-only run needs no
///     per-character map at all.
///  2. NOTHING IS LOST BY BOUNDING. Every character of the run is still
///     searched, a match that straddles a wrap boundary inside a piece is
///     still found and reported as (start row, start col .. end col counted
///     on from column 0 of the start row), and a plain match anywhere in the
///     tail of the run is still found.
///  3. REVEAL. `findMatches` documents that a match across a soft wrap ends
///     on row `line + endCol / cols`. Scrolling the match into view must
///     bring the WHOLE match on screen when it fits: start row AND end row.
///     Both when the match starts on the bottom visible row (the continuation
///     is just below the edge) and when the match is entirely below the
///     viewport (scrolled back far away). A match that is already fully
///     visible, a one-row match on the bottom row, and a match above the
///     viewport behave as before (controls - they pass before and after).
///
/// Fixtures: headless `TerminalView` + headless `TerminalSession` (real BBTerm,
/// no PTY, no shell, no window), 40x6 grid, default 100k-line scrollback.
///
/// Cost (computed up front): the huge-run tests build ONE terminal each with
/// a 1,200,417-cell logical line = 30,011 wrapped rows (about 1.2 MB of input
/// fed in 64 KiB pieces, ~30 MB of core cells, a ~1.2 MB Swift String and,
/// on the unfixed code, a ~9.6 MB column map), plus 14 filler lines. Four such
/// tests, built and freed one after another, a few seconds each. The scroll
/// tests feed ~27 short lines (a few KB) and pump the main runloop for about
/// 1-2 s each (the find refresh debounce is 100 ms; we wait several
/// multiples). One view + one session per test; no shell, no child process.
final class FindWrappedRunBoundBlindTests: XCTestCase {

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

    private typealias Match = (line: Int32, startCol: Int, endCol: Int)
    private typealias Captured = [(line: Int32, hay: String, utf16ToCol: [Int]?)]

    private let cols: UInt16 = 40
    private let rows: UInt16 = 6

    private func makeRig(file: StaticString = #filePath, line: UInt = #line) throws -> Rig {
        let view = try XCTUnwrap(TerminalView.makeHeadlessForTests(), "Metal device required", file: file, line: line)
        let session = TerminalSession.makeHeadlessForTests()
        session.resize(to: .init(cols: cols, rows: rows))
        view.session = session
        view.findController.installFindBar()
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

    private func settle(_ seconds: TimeInterval) {
        pump(until: seconds) { () -> Bool in false }
    }

    private func fmt(_ ms: [Match]) -> String {
        "[" + ms.prefix(12).map { "(\($0.line),\($0.startCol)-\($0.endCol))" }.joined(separator: " ")
            + (ms.count > 12 ? " ...(\(ms.count) total)" : "") + "]"
    }

    // MARK: - Part 1: the huge soft-wrapped run

    /// 30,011 rows of 40 cells; the last row holds 17 cells (so it is not a
    /// full-width row and never ends in a pending wrap).
    private let runRows = 30_011
    private let lastRowCells = 17
    private var runCells: Int { (runRows - 1) * Int(cols) + lastRowCells }
    private let fillerLines = 14

    /// A generous ceiling for ONE merged entry, in UTF-16 units: 512 Ki. The
    /// whole run is ~1.2 M units, so a run that is split into bounded pieces
    /// passes with any cap up to 12,000 rows at this width; the unfixed code
    /// returns the run as a single ~1.2 M-unit entry.
    private let maxEntryUnits = 524_288

    private struct HugeRun {
        let rig: Rig
        let snap: BBSnapshot
        /// Buffer line of the run's first row (the oldest history line).
        let first: Int32
    }

    /// The run's cells: 'a' filler with three planted words.
    ///  - "needle" at row 2, col 37  -> straddles the row 2 / row 3 wrap, 37..42
    ///  - "gizmo"  at row R-50, col 38 -> straddles the wrap too, 38..42
    ///  - "zebra"  at row R-14, col 10 -> entirely inside one row, 10..14
    private func hugeRunBytes() -> [UInt8] {
        var bytes = [UInt8](repeating: UInt8(ascii: "a"), count: runCells)
        func plant(_ word: String, row: Int, col: Int) {
            let start = row * Int(cols) + col
            var i = start
            for b in word.utf8 {
                bytes[i] = b
                i += 1
            }
        }
        plant("needle", row: 2, col: 37)
        plant("gizmo", row: runRows - 50, col: 38)
        plant("zebra", row: runRows - 14, col: 10)
        return bytes
    }

    private func feedChunked(_ rig: Rig, _ bytes: [UInt8]) {
        let step = 64 * 1024
        var i = 0
        while i < bytes.count {
            let j = min(bytes.count, i + step)
            rig.session.feedBytesForTests(Data(bytes[i..<j]))
            i = j
        }
    }

    /// Feed the huge logical line, a CRLF, and filler lines that push the
    /// WHOLE run into scrollback. Asserts every precondition so a green run
    /// cannot mean "the fixture was not what the test thinks".
    private func makeHugeRun(file: StaticString = #filePath, line: UInt = #line) throws -> HugeRun {
        let rig = try makeRig(file: file, line: line)
        let bytes = hugeRunBytes()
        XCTAssertEqual(bytes.count, runCells, "fixture: run byte count", file: file, line: line)
        feedChunked(rig, bytes)
        var tail = "\r\n"
        for i in 0..<fillerLines { tail += String(format: "post %02d\r\n", i) }
        rig.session.feedBytesForTests(Data(tail.utf8))

        let snap = try XCTUnwrap(rig.session.takeSnapshotForTests(), "snapshot must be available", file: file, line: line)
        rig.view.currentSnapshot = snap
        XCTAssertEqual(snap.cols, Int(cols), "fixture: grid must be \(cols) columns wide", file: file, line: line)
        XCTAssertEqual(snap.rows, Int(rows), "fixture: grid must be \(rows) rows tall", file: file, line: line)
        XCTAssertEqual(snap.displayOffset, 0, "fixture: viewport is at the live bottom", file: file, line: line)
        // R run rows + 14 fillers + the empty cursor row, minus the 6 visible ones.
        XCTAssertEqual(snap.historySize, runRows + fillerLines + 1 - Int(rows),
                       "fixture: the whole run and the fillers must be retained in scrollback", file: file, line: line)

        let first = -Int32(snap.historySize)
        let lastRun = first + Int32(runRows) - 1
        XCTAssertLessThan(lastRun, 0, "fixture: the run's last row must be in scrollback, not the viewport", file: file, line: line)

        // The run starts at the oldest history line and rows 0-3 are what we planted.
        let head = FindController.trimmingTrailingSpaces(
            rig.session.textRange(from: BufferPoint(line: first, col: 0),
                                  to: BufferPoint(line: first + 3, col: Int(cols) - 1),
                                  rectangular: false))
        XCTAssertEqual(head, String(decoding: bytes[0..<(4 * Int(cols))], as: UTF8.self),
                       "fixture: the oldest history rows must be the soft-wrapped run, joined without a newline",
                       file: file, line: line)
        // ... and it ends where we think it does.
        let tailStart = (runRows - 2) * Int(cols)
        let tailText = FindController.trimmingTrailingSpaces(
            rig.session.textRange(from: BufferPoint(line: lastRun - 1, col: 0),
                                  to: BufferPoint(line: lastRun, col: Int(cols) - 1),
                                  rectangular: false))
        XCTAssertEqual(tailText, String(decoding: bytes[tailStart..<bytes.count], as: UTF8.self),
                       "fixture: the last two run rows must hold the last \(bytes.count - tailStart) cells",
                       file: file, line: line)
        return HugeRun(rig: rig, snap: snap, first: first)
    }

    private func capture(_ run: HugeRun, joined: Bool) -> Captured {
        run.rig.fc.captureRows(
            topLine: -Int32(run.snap.historySize),
            bottomLine: Int32(run.snap.rows - 1),
            cols: run.snap.cols,
            session: run.rig.session,
            snap: run.snap,
            joinSoftWrapped: joined
        )
    }

    /// The captured entries that belong to the run (its filler neighbours and
    /// the viewport rows are excluded), checked for the invariants every
    /// fixed design must keep: strictly ascending start rows, inside the run.
    private func runEntries(_ captured: Captured, _ run: HugeRun,
                            file: StaticString = #filePath, line: UInt = #line) -> Captured {
        let lo = run.first
        let hi = run.first + Int32(runRows) - 1
        let entries: Captured = captured.filter { $0.line >= lo && $0.line <= hi }
        var previous = Int32.min
        for e in entries {
            if e.line <= previous {
                XCTFail("entries must be in strictly ascending start-row order; \(previous) then \(e.line)",
                        file: file, line: line)
                break
            }
            previous = e.line
        }
        return entries
    }

    /// Precondition shared by the two capture tests: the un-joined capture
    /// sees every physical row (run rows + fillers), so the joined capture's
    /// numbers below are measured over the whole run.
    private func assertPhysicalCaptureIsComplete(_ run: HugeRun,
                                                 file: StaticString = #filePath, line: UInt = #line) {
        let physical = capture(run, joined: false)
        XCTAssertEqual(physical.count, runRows + fillerLines,
                       "fixture: un-joined capture must return one entry per physical row (\(runRows) run rows + \(fillerLines) fillers)",
                       file: file, line: line)
    }

    /// (1) A scan can only be cancelled between entries, so no entry may hold
    /// the whole run. Nothing may be dropped to get there.
    func test_hugeScrollbackRun_isHandedToTheScanInBoundedPieces() throws {
        let run = try makeHugeRun()
        assertPhysicalCaptureIsComplete(run)

        let entries = runEntries(capture(run, joined: true), run)
        var total = 0
        var biggest = 0
        for e in entries {
            let n = e.hay.utf16.count
            total += n
            biggest = max(biggest, n)
        }

        // Merging must still happen (a straddling match needs two rows in one
        // haystack): at least one entry is wider than a single 40-cell row.
        XCTAssertGreaterThan(biggest, Int(cols),
                             "joined capture must still merge soft-wrapped rows; largest entry = \(biggest) units over \(entries.count) entries")
        // Nothing may be silently dropped: every one of the run's cells is searched.
        XCTAssertGreaterThanOrEqual(total, runCells,
                                    "the pieces must together cover the whole run (\(runCells) cells); they hold \(total) units in \(entries.count) entries")
        XCTAssertLessThanOrEqual(biggest, maxEntryUnits,
                                 "one merged entry holds \(biggest) UTF-16 units (the whole run is \(runCells)); "
                                 + "an unbounded entry can only be cancelled after it has been fully scanned. "
                                 + "\(entries.count) entries cover the run; cap allowed = \(maxEntryUnits)")
        XCTAssertGreaterThanOrEqual(entries.count, 2,
                                    "a \(runCells)-unit run must be split into at least two pieces; got \(entries.count)")
    }

    /// (1) A scrollback-only run lays out one cell per character, so it must
    /// not carry an 8-byte-per-unit column map. We allow far less than one
    /// map word per 8 characters (< 1 byte per character), which any per-row
    /// or per-piece bookkeeping satisfies and a per-UTF-16-unit map does not.
    func test_hugeScrollbackRun_carriesNoPerCharacterColumnMap() throws {
        let run = try makeHugeRun()
        assertPhysicalCaptureIsComplete(run)

        let entries = runEntries(capture(run, joined: true), run)
        var total = 0
        var mapUnits = 0
        for e in entries {
            total += e.hay.utf16.count
            mapUnits += e.utf16ToCol?.count ?? 0
        }
        XCTAssertGreaterThanOrEqual(total, runCells,
                                    "precondition: the entries cover the whole run (\(runCells) cells); got \(total) units")
        XCTAssertLessThanOrEqual(mapUnits, total / 8,
                                 "a scrollback-only run of \(total) characters carries \(mapUnits) column-map entries "
                                 + "(= \(mapUnits * MemoryLayout<Int>.stride) bytes, \(mapUnits * MemoryLayout<Int>.stride / max(1, total)) bytes per character); "
                                 + "the map must be at most one word per 8 characters")
    }

    private func substringSearch(_ rig: Rig, _ query: String,
                                 file: StaticString = #filePath, line: UInt = #line) throws -> [Match] {
        let bar = try XCTUnwrap(rig.fc.findBar, file: file, line: line)
        XCTAssertFalse(bar.options.regex, "fixture: regex must be off for the substring path", file: file, line: line)
        XCTAssertFalse(bar.options.caseSensitive, "fixture: default is case-insensitive", file: file, line: line)
        rig.fc.performSearch(query: query)
        return rig.fc.findMatches
    }

    /// (2) Bounding must not lose matches: the straddling match near the
    /// start of the run, the straddling match near its end, and a plain match
    /// in the tail are each found exactly once, with the documented shape
    /// (start row, start col, end col counted on from the start row's col 0).
    func test_hugeScrollbackRun_straddlingAndTailMatchesAreStillFoundExactlyOnce() throws {
        let run = try makeHugeRun()
        let rig = run.rig
        let first = run.first

        let needle = try substringSearch(rig, "needle")
        XCTAssertEqual(needle.map { [Int($0.line), $0.startCol, $0.endCol] },
                       [[Int(first) + 2, 37, 42]],
                       "'needle' straddles the row 2 / row 3 wrap of the run: expected one match at (line first+2, 37..42); got \(fmt(needle)) (first=\(first))")

        let gizmo = try substringSearch(rig, "gizmo")
        XCTAssertEqual(gizmo.map { [Int($0.line), $0.startCol, $0.endCol] },
                       [[Int(first) + runRows - 50, 38, 42]],
                       "'gizmo' straddles a wrap 49 rows from the end of the run: expected one match at (line first+\(runRows - 50), 38..42); got \(fmt(gizmo)) (first=\(first))")

        let zebra = try substringSearch(rig, "zebra")
        XCTAssertEqual(zebra.map { [Int($0.line), $0.startCol, $0.endCol] },
                       [[Int(first) + runRows - 14, 10, 14]],
                       "'zebra' sits inside one row 13 rows from the end of the run: expected one match at (line first+\(runRows - 14), 10..14); got \(fmt(zebra)) (first=\(first))")
    }

    // MARK: - Part 2: revealing a cross-wrap match

    /// A scrollback fixture: 10 `pre NN` lines, the `logical` line (which wraps
    /// over `wrappedRows` rows of the 40-col grid), 14 `post NN` lines. Every
    /// row of the logical line is in history. `firstLine` is the buffer line of
    /// the logical line's first row.
    private struct ScrollFixture {
        let rig: Rig
        let firstLine: Int32
        let history: Int
        let rowTexts: [String]
    }

    private func makeScrollFixture(logical: String, wrappedRows: Int,
                                   file: StaticString = #filePath, line: UInt = #line) throws -> ScrollFixture {
        let rig = try makeRig(file: file, line: line)
        var lines: [String] = (0..<10).map { String(format: "pre %02d", $0) }
        lines.append(logical)
        lines += (0..<14).map { String(format: "post %02d", $0) }
        rig.session.feedBytesForTests(Data((lines.joined(separator: "\r\n") + "\r\n").utf8))
        let landed = pump(until: 3.0) { () -> Bool in
            guard let snap = rig.view.currentSnapshot else { return false }
            return snap.visibleRowsAsText().contains { (row: String) -> Bool in row.hasPrefix("post 13") }
        }
        XCTAssertTrue(landed, "fixture: a snapshot showing 'post 13' must reach the view within 3 s", file: file, line: line)
        let snap = try XCTUnwrap(rig.view.currentSnapshot, "view must have a snapshot", file: file, line: line)
        XCTAssertEqual(snap.cols, Int(cols), "fixture: grid must be \(cols) columns wide", file: file, line: line)
        XCTAssertEqual(snap.rows, Int(rows), "fixture: grid must be \(rows) rows tall", file: file, line: line)
        XCTAssertEqual(snap.displayOffset, 0, "fixture: viewport starts at the live bottom", file: file, line: line)
        // 10 pre + wrappedRows + 14 post + the empty cursor row, minus the 6 visible ones.
        XCTAssertEqual(snap.historySize, 10 + wrappedRows + 14 + 1 - Int(rows),
                       "fixture: scrollback size", file: file, line: line)

        let firstLine = -Int32(snap.historySize) + 10
        let joined = FindController.trimmingTrailingSpaces(
            rig.session.textRange(from: BufferPoint(line: firstLine, col: 0),
                                  to: BufferPoint(line: firstLine + Int32(wrappedRows) - 1, col: Int(cols) - 1),
                                  rectangular: false))
        XCTAssertEqual(joined, logical,
                       "fixture: the logical line must occupy \(wrappedRows) soft-wrapped rows starting at buffer line \(firstLine)",
                       file: file, line: line)
        XCTAssertLessThan(firstLine + Int32(wrappedRows) - 1, 0,
                          "fixture: every row of the logical line is in scrollback", file: file, line: line)

        var rowTexts: [String] = []
        let chars = Array(logical)
        var i = 0
        while i < chars.count {
            let j = min(chars.count, i + Int(cols))
            rowTexts.append(String(chars[i..<j]))
            i = j
        }
        XCTAssertEqual(rowTexts.count, wrappedRows, "fixture: row texts", file: file, line: line)
        return ScrollFixture(rig: rig, firstLine: firstLine, history: snap.historySize, rowTexts: rowTexts)
    }

    /// Scroll the viewport to `offset` lines above the live bottom and wait
    /// for the view to see it.
    private func scrollViewport(_ fx: ScrollFixture, toOffset offset: Int,
                                file: StaticString = #filePath, line: UInt = #line) {
        let rig = fx.rig
        if offset != 0 { rig.session.scroll(delta: Int32(offset)) }
        let landed = pump(until: 3.0) { () -> Bool in rig.view.currentSnapshot?.displayOffset == offset }
        XCTAssertTrue(landed,
                      "fixture: viewport must reach displayOffset \(offset); at \(String(describing: rig.view.currentSnapshot?.displayOffset)) (history \(fx.history))",
                      file: file, line: line)
    }

    private func trimmedVisibleRows(_ rig: Rig) -> [String] {
        (rig.view.currentSnapshot?.visibleRowsAsText() ?? []).map { FindController.trimmingTrailingSpaces($0) }
    }

    /// Type the query into the bar like the user would and wait for the
    /// single match (and the reveal scroll that goes with it) to settle.
    private func typeQuery(_ rig: Rig, _ query: String, regex: Bool,
                           file: StaticString = #filePath, line: UInt = #line) throws {
        let fc = rig.fc
        let bar = try XCTUnwrap(fc.findBar, "find bar must be installed", file: file, line: line)
        if regex {
            bar.toggleRegexMode(nil)
            XCTAssertTrue(bar.options.regex, "fixture: regex mode must be on", file: file, line: line)
        }
        bar.setQuery(query)
        let found = pump(until: 3.0) { () -> Bool in fc.findMatches.count == 1 }
        XCTAssertTrue(found, "fixture: query '\(query)' must produce exactly one match; got \(fmt(fc.findMatches))",
                      file: file, line: line)
        // The reveal scroll publishes a snapshot; wait several multiples of the 100 ms refresh debounce.
        settle(0.6)
    }

    /// The single match reports it spans `spanRows` rows, and after the reveal
    /// both its start row and its end row (and every row between) are on
    /// screen - checked against the match's coordinates AND the visible text.
    private func assertWholeMatchOnScreen(_ rig: Rig, spanRows: Int, rowTexts: [String], offsetBefore: Int,
                                          file: StaticString = #filePath, line: UInt = #line) {
        guard let snap = rig.view.currentSnapshot else {
            XCTFail("view must have a snapshot", file: file, line: line)
            return
        }
        let matches = rig.fc.findMatches
        guard matches.count == 1 else {
            XCTFail("expected exactly one match; got \(fmt(matches))", file: file, line: line)
            return
        }
        let m = matches[0]
        let rowsBelowStart = m.endCol / snap.cols
        XCTAssertEqual(rowsBelowStart + 1, spanRows,
                       "precondition: the match must report that it spans \(spanRows) rows (endCol / cols + 1); got \(fmt(matches))",
                       file: file, line: line)
        let topRow = Int(m.line) + snap.displayOffset
        let bottomRow = topRow + rowsBelowStart
        let visible = trimmedVisibleRows(rig)
        XCTAssertGreaterThanOrEqual(topRow, 0,
                                    "the match's start row must be on screen: start at screen row \(topRow) (displayOffset \(offsetBefore) -> \(snap.displayOffset)); visible=\(visible)",
                                    file: file, line: line)
        XCTAssertLessThanOrEqual(bottomRow, snap.rows - 1,
                                 "the match's END row must be on screen: it ends at screen row \(bottomRow) of 0..\(snap.rows - 1) "
                                 + "(displayOffset \(offsetBefore) -> \(snap.displayOffset), match \(fmt(matches))); visible=\(visible)",
                                 file: file, line: line)
        for (k, text) in rowTexts.enumerated() {
            XCTAssertTrue(visible.contains(text),
                          "row \(k) of the wrapped line ('\(text)') must be visible after the reveal; visible=\(visible)",
                          file: file, line: line)
        }
    }

    private static let needleLogical = String(repeating: "a", count: 37) + "needle"
    /// 100 cells, three rows; "w007-...-w016" is cells 35..83 (rows 0, 1 and 2).
    private static let tokensLogical = (0..<20).map { String(format: "w%03d-", $0) }.joined()
    private static let tokensQuery = (7...16).map { String(format: "w%03d", $0) }.joined(separator: "-")

    // MARK: Start row on the bottom visible row, continuation just below the edge

    func test_reveal_matchStartsOnBottomRow_continuationBelow_bothRowsBecomeVisible() throws {
        let fx = try makeScrollFixture(logical: Self.needleLogical, wrappedRows: 2)
        let offset = 5 - Int(fx.firstLine)   // start row lands on screen row 5, the bottom row
        scrollViewport(fx, toOffset: offset)
        let before = trimmedVisibleRows(fx.rig)
        XCTAssertEqual(before.last, fx.rowTexts[0],
                       "precondition: the match's first row is the bottom visible row; visible=\(before)")
        XCTAssertFalse(before.contains(fx.rowTexts[1]),
                       "precondition: the continuation row is below the viewport; visible=\(before)")

        try typeQuery(fx.rig, "needle", regex: false)

        assertWholeMatchOnScreen(fx.rig, spanRows: 2, rowTexts: fx.rowTexts, offsetBefore: offset)
        withExtendedLifetime(fx.rig) {}
    }

    func test_reveal_threeRowMatchStartsOnBottomRow_allThreeRowsBecomeVisible() throws {
        let fx = try makeScrollFixture(logical: Self.tokensLogical, wrappedRows: 3)
        let offset = 5 - Int(fx.firstLine)
        scrollViewport(fx, toOffset: offset)
        let before = trimmedVisibleRows(fx.rig)
        XCTAssertEqual(before.last, fx.rowTexts[0], "precondition: first row is the bottom visible row; visible=\(before)")
        XCTAssertFalse(before.contains(fx.rowTexts[1]) || before.contains(fx.rowTexts[2]),
                       "precondition: the continuation rows are below the viewport; visible=\(before)")

        try typeQuery(fx.rig, Self.tokensQuery, regex: false)

        assertWholeMatchOnScreen(fx.rig, spanRows: 3, rowTexts: fx.rowTexts, offsetBefore: offset)
        withExtendedLifetime(fx.rig) {}
    }

    // MARK: Whole match below the viewport (user scrolled far back)

    func test_reveal_matchBelowViewport_bothRowsBecomeVisible() throws {
        let fx = try makeScrollFixture(logical: Self.needleLogical, wrappedRows: 2)
        scrollViewport(fx, toOffset: fx.history)   // as far back as the buffer goes
        let before = trimmedVisibleRows(fx.rig)
        XCTAssertFalse(before.contains(fx.rowTexts[0]) || before.contains(fx.rowTexts[1]),
                       "precondition: the match is entirely below the viewport; visible=\(before)")

        try typeQuery(fx.rig, "needle", regex: false)

        assertWholeMatchOnScreen(fx.rig, spanRows: 2, rowTexts: fx.rowTexts, offsetBefore: fx.history)
        withExtendedLifetime(fx.rig) {}
    }

    func test_reveal_threeRowMatchBelowViewport_allThreeRowsBecomeVisible() throws {
        let fx = try makeScrollFixture(logical: Self.tokensLogical, wrappedRows: 3)
        scrollViewport(fx, toOffset: fx.history)
        let before = trimmedVisibleRows(fx.rig)
        XCTAssertFalse(fx.rowTexts.contains { (text: String) -> Bool in before.contains(text) },
                       "precondition: the match is entirely below the viewport; visible=\(before)")

        try typeQuery(fx.rig, Self.tokensQuery, regex: false)

        assertWholeMatchOnScreen(fx.rig, spanRows: 3, rowTexts: fx.rowTexts, offsetBefore: fx.history)
        withExtendedLifetime(fx.rig) {}
    }

    // MARK: Regex path reveals the same way (async publish)

    func test_reveal_regex_matchStartsOnBottomRow_continuationBelow_bothRowsBecomeVisible() throws {
        let fx = try makeScrollFixture(logical: Self.needleLogical, wrappedRows: 2)
        let offset = 5 - Int(fx.firstLine)
        scrollViewport(fx, toOffset: offset)
        let before = trimmedVisibleRows(fx.rig)
        XCTAssertEqual(before.last, fx.rowTexts[0], "precondition: first row is the bottom visible row; visible=\(before)")
        XCTAssertFalse(before.contains(fx.rowTexts[1]), "precondition: continuation below the viewport; visible=\(before)")

        try typeQuery(fx.rig, "needle", regex: true)

        assertWholeMatchOnScreen(fx.rig, spanRows: 2, rowTexts: fx.rowTexts, offsetBefore: offset)
        withExtendedLifetime(fx.rig) {}
    }

    func test_reveal_regex_matchBelowViewport_bothRowsBecomeVisible() throws {
        let fx = try makeScrollFixture(logical: Self.needleLogical, wrappedRows: 2)
        scrollViewport(fx, toOffset: fx.history)
        let before = trimmedVisibleRows(fx.rig)
        XCTAssertFalse(before.contains(fx.rowTexts[0]) || before.contains(fx.rowTexts[1]),
                       "precondition: the match is entirely below the viewport; visible=\(before)")

        try typeQuery(fx.rig, "needle", regex: true)

        assertWholeMatchOnScreen(fx.rig, spanRows: 2, rowTexts: fx.rowTexts, offsetBefore: fx.history)
        withExtendedLifetime(fx.rig) {}
    }

    // MARK: Controls - behaviour that must not change (pass before AND after the fix)

    /// Match above the viewport (viewport at the live bottom): the existing
    /// reveal puts the start row at the top, so the continuation is visible too.
    func test_control_matchAboveViewport_bothRowsBecomeVisible() throws {
        let fx = try makeScrollFixture(logical: Self.needleLogical, wrappedRows: 2)
        scrollViewport(fx, toOffset: 0)
        let before = trimmedVisibleRows(fx.rig)
        XCTAssertFalse(before.contains(fx.rowTexts[0]) || before.contains(fx.rowTexts[1]),
                       "precondition: the match is entirely above the viewport; visible=\(before)")

        try typeQuery(fx.rig, "needle", regex: false)

        assertWholeMatchOnScreen(fx.rig, spanRows: 2, rowTexts: fx.rowTexts, offsetBefore: 0)
        withExtendedLifetime(fx.rig) {}
    }

    /// A match that is already fully visible must not move the viewport.
    func test_control_matchAlreadyFullyVisible_viewportDoesNotMove() throws {
        let fx = try makeScrollFixture(logical: Self.needleLogical, wrappedRows: 2)
        // Start row on screen row 3, continuation on row 4: the find bar paints
        // over the top rows of this 6-row grid (up to three, depending on the
        // host's cell height), and a match under it is not "fully visible".
        let offset = 3 - Int(fx.firstLine)
        scrollViewport(fx, toOffset: offset)
        let before = trimmedVisibleRows(fx.rig)
        XCTAssertEqual(Array(before.dropFirst(3).prefix(2)), fx.rowTexts,
                       "precondition: both rows of the wrapped line are visible on screen rows 3-4; visible=\(before)")

        try typeQuery(fx.rig, "needle", regex: false)

        XCTAssertEqual(fx.rig.view.currentSnapshot?.displayOffset, offset,
                       "a fully visible match must not scroll the viewport; displayOffset \(offset) -> \(String(describing: fx.rig.view.currentSnapshot?.displayOffset))")
        withExtendedLifetime(fx.rig) {}
    }

    /// A match confined to ONE row that sits on the bottom visible row is
    /// fully visible: the viewport must not move (a fix must not scroll just
    /// because a match touches the bottom edge).
    func test_control_singleRowMatchOnBottomRow_viewportDoesNotMove() throws {
        let fx = try makeScrollFixture(logical: "plain needle here", wrappedRows: 1)
        let offset = 5 - Int(fx.firstLine)
        scrollViewport(fx, toOffset: offset)
        let before = trimmedVisibleRows(fx.rig)
        XCTAssertEqual(before.last, "plain needle here", "precondition: the line is the bottom visible row; visible=\(before)")

        try typeQuery(fx.rig, "needle", regex: false)

        XCTAssertEqual(fx.rig.view.currentSnapshot?.displayOffset, offset,
                       "a one-row match on the bottom row is already visible; displayOffset \(offset) -> \(String(describing: fx.rig.view.currentSnapshot?.displayOffset))")
        withExtendedLifetime(fx.rig) {}
    }
}
