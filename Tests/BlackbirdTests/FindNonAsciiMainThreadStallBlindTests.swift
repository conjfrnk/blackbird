import XCTest
import AppKit
import Metal
@testable import Blackbird
import BBCore

/// Blind behaviour tests for the find bar's cost on the MAIN thread when the
/// query contains non-ASCII text (accented letters, CJK, emoji).
///
/// Spec (observable behaviour, independent of how the scan is implemented):
///
///  - Typing a query into the find bar must not block the main thread for
///    time proportional to "scrollback size x a heavyweight per-row cost".
///    A query that happens to contain a non-ASCII character is, for the
///    overwhelming majority of rows (plain ASCII build output), a row that
///    cannot contain the query at all, so searching 30 000 such rows for it
///    must cost about the same as searching them for an ASCII query that
///    does not occur (the same rows are captured either way). The measured
///    stall is the extra time the non-ASCII query costs over that ASCII
///    control, per row of scrollback.
///  - The same holds for the snapshot-driven re-search that runs (debounced
///    to 100 ms) while output streams with the bar open: the longest single
///    main-runloop block must not grow by a per-row amount just because the
///    query is non-ASCII, otherwise streaming output plus an open find bar
///    is back-to-back UI hangs.
///  - Speed must not cost correctness: the planted accented / CJK / emoji
///    rows are still found, at their exact lines and grid columns (a wide
///    CJK character or emoji occupies two cells, so "日本" spans columns 0-3
///    and an emoji at column 5 spans 5-6), case-insensitively by default.
///    A fix that makes the scan asynchronous is accepted: results are
///    awaited by pumping the runloop.
///
/// Why a ratio against an ASCII control and not an absolute millisecond
/// budget: other builds on the same host change absolute speeds by several
/// x, but the control query pays the identical capture cost under the
/// identical load, so the per-row EXCESS is stable. The bar is 3 microseconds
/// per row; the defect costs 7+ us per row of excess on an idle machine and
/// a cure that skips rows which cannot contain the query is well under 1.
///
/// Fixture: headless `TerminalView` + headless `TerminalSession` (no PTY),
/// 40x6 grid, 30 000 distinct ASCII lines (~37 cells each, ~1.1 MB fed, about
/// 1.2 M grid cells in core, a few tens of MB), four planted non-ASCII rows
/// deep in scrollback. Default 100 K history, so nothing is evicted.
final class FindNonAsciiMainThreadStallBlindTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        TestHostTermination.shared.register()
    }

    // MARK: - Fixture

    private struct Rig {
        let view: TerminalView
        let session: TerminalSession
    }

    private typealias Match = (line: Int32, startCol: Int, endCol: Int)
    private typealias Row = (line: Int32, hay: String, utf16ToCol: [Int]?)

    private let cols: UInt16 = 40
    private let rows: UInt16 = 6
    private let rowCount = 30_000

    /// Row index -> text, planted in place of the generated ASCII line.
    private let planted: [Int: String] = [
        100: "caf\u{E9} au lait",
        200: "日本語 テスト",
        300: "grin \u{1F600} done",
        400: "R\u{E9}SUM\u{C9} resume",
    ]

    /// (query, expected (row index, startCol, endCol)) for the planted rows.
    /// "é" also matches "É" (the default is case-insensitive).
    private let nonAsciiCases: [(query: String, expected: [(Int, Int, Int)])] = [
        ("\u{E9}", [(100, 3, 3), (400, 1, 1), (400, 5, 5)]),
        ("日本", [(200, 0, 3)]),
        ("\u{1F600}", [(300, 5, 6)]),
    ]

    private let asciiControlQuery = "zqxj"
    private let excessBudgetMicrosecondsPerRow = 3.0

    private func generatedLines() -> [String] {
        var lines: [String] = []
        lines.reserveCapacity(rowCount)
        for i in 0..<rowCount {
            if let p = planted[i] {
                lines.append(p)
            } else {
                lines.append(String(format: "step %06d compiling module alpha ok", i))
            }
        }
        return lines
    }

    /// Loads the scrollback, publishes a snapshot, opens the find bar, and
    /// proves the fixture is what the test claims it is.
    private func makeLoadedRig(file: StaticString = #filePath, line: UInt = #line) throws -> (rig: Rig, captured: [Row]) {
        let view = try XCTUnwrap(TerminalView.makeHeadlessForTests(), "Metal device required", file: file, line: line)
        let session = TerminalSession.makeHeadlessForTests()
        session.resize(to: .init(cols: cols, rows: rows))
        view.session = session
        let rig = Rig(view: view, session: session)

        var text = ""
        for l in generatedLines() { text += l + "\r\n" }
        session.feedBytesForTests(Data(text.utf8))
        let snap = try XCTUnwrap(session.takeSnapshotForTests(), "snapshot must be available", file: file, line: line)
        view.currentSnapshot = snap
        view.findController.installFindBar()
        let bar = try XCTUnwrap(view.findController.findBar, "fixture: the find bar must be open", file: file, line: line)
        XCTAssertFalse(bar.options.regex, "fixture: substring (non-regex) path", file: file, line: line)
        XCTAssertFalse(bar.options.caseSensitive, "fixture: default case-insensitive options", file: file, line: line)

        XCTAssertGreaterThanOrEqual(snap.historySize, rowCount - Int(rows) - 1,
                                    "fixture: the whole feed must still be in scrollback", file: file, line: line)
        let captured = view.findController.captureRows(
            topLine: -Int32(clamping: snap.historySize),
            bottomLine: Int32(clamping: snap.rows - 1),
            cols: snap.cols,
            session: session,
            snap: snap
        )
        XCTAssertEqual(captured.count, rowCount, "fixture: every generated row must be captured as one entry",
                       file: file, line: line)
        for (idx, text) in planted {
            XCTAssertEqual(idx < captured.count ? captured[idx].hay : "<missing>", text,
                           "fixture: planted row \(idx) must be captured verbatim", file: file, line: line)
            XCTAssertNil(idx < captured.count ? captured[idx].utf16ToCol : [],
                         "fixture: planted row \(idx) must be a plain scrollback row", file: file, line: line)
        }
        let nonAscii = captured.filter { row -> Bool in row.hay.utf8.contains { $0 >= 0x80 } }.count
        XCTAssertEqual(nonAscii, planted.count, "fixture: only the planted rows may contain non-ASCII text",
                       file: file, line: line)
        return (rig, captured)
    }

    private func expectedMatches(_ spec: [(Int, Int, Int)], _ captured: [Row]) -> [Match] {
        spec.map { s -> Match in (line: captured[s.0].line, startCol: s.1, endCol: s.2) }
    }

    private func fmt(_ ms: [Match]) -> String {
        ms.prefix(12).map { m -> String in "(\(m.line),\(m.startCol)-\(m.endCol))" }.joined(separator: " ")
            + (ms.count > 12 ? " ...(\(ms.count) total)" : "")
    }

    private func sameMatches(_ a: [Match], _ b: [Match]) -> Bool {
        a.count == b.count && zip(a, b).allSatisfy { x, y -> Bool in
            x.line == y.line && x.startCol == y.startCol && x.endCol == y.endCol
        }
    }

    private func elapsedMs(_ body: () -> Void) -> Double {
        let t0 = DispatchTime.now().uptimeNanoseconds
        body()
        let t1 = DispatchTime.now().uptimeNanoseconds
        return Double(t1 - t0) / 1_000_000.0
    }

    /// Pump the main runloop in 5 ms slices until `condition` holds or
    /// `timeout` elapses.
    @discardableResult
    private func pump(until timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date(timeIntervalSinceNow: timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.005))
        }
        return condition()
    }

    // MARK: - performSearch (typing a query)

    /// Typing a non-ASCII query over a 30 000-row ASCII scrollback may cost at
    /// most a few microseconds per row more than an ASCII query that does not
    /// match, and must still find the planted rows.
    func test_nonAsciiQuery_searchCostsNoMorePerRowThanAnAsciiMissOverTheSameScrollback() throws {
        let (rig, captured) = try makeLoadedRig()
        let fc = rig.view.findController
        let n = captured.count

        // Control: an ASCII needle that occurs nowhere. Same capture, same
        // scan loop, no matches, so no highlight/scroll side effects.
        var controlMs = Double.greatestFiniteMagnitude
        for _ in 0..<3 {
            let ms = elapsedMs { fc.performSearch(query: asciiControlQuery) }
            controlMs = min(controlMs, ms)
        }
        XCTAssertEqual(fc.findMatches.count, 0, "control query \(asciiControlQuery.debugDescription) must match nothing")

        var report: [String] = []
        for c in nonAsciiCases {
            var bestMs = Double.greatestFiniteMagnitude
            for _ in 0..<3 {
                let ms = elapsedMs { fc.performSearch(query: c.query) }
                bestMs = min(bestMs, ms)
            }

            // Correctness: the search (sync or async) must land on exactly
            // the planted rows.
            let want = expectedMatches(c.expected, captured)
            let landed = pump(until: 10.0) { () -> Bool in sameMatches(fc.findMatches, want) }
            XCTAssertTrue(landed,
                          "query \(c.query.debugDescription): got [\(fmt(fc.findMatches))], expected [\(fmt(want))]")

            let excessUsPerRow = (bestMs - controlMs) * 1000.0 / Double(n)
            report.append("\(c.query.debugDescription)=\(Int(bestMs)) ms")
            XCTAssertLessThan(
                excessUsPerRow, excessBudgetMicrosecondsPerRow,
                "searching \(n) ASCII rows for \(c.query.debugDescription) blocked the calling (main) thread for "
                + "\(String(format: "%.1f", bestMs)) ms vs \(String(format: "%.1f", controlMs)) ms for the ASCII "
                + "control \(asciiControlQuery.debugDescription): +\(String(format: "%.1f", excessUsPerRow)) us/row, "
                + "budget \(excessBudgetMicrosecondsPerRow) us/row"
            )
        }
        print("FindNonAsciiMainThreadStallBlindTests.search: control \(String(format: "%.1f", controlMs)) ms; "
              + report.joined(separator: ", "))
        withExtendedLifetime(rig) {}
    }

    // MARK: - Snapshot-driven refresh while output streams

    /// Longest single main-runloop block while one streamed line triggers the
    /// debounced re-search of the live query.
    private func longestRunLoopBlockMs(_ rig: Rig, query: String, expectedCount: Int,
                                       tick: String) -> (maxSliceMs: Double, reSearched: Bool) {
        let fc = rig.view.findController
        fc.findQuery = query
        fc.performSearch(query: query)
        // Let any asynchronous completion of the initial search settle.
        pump(until: 10.0) { () -> Bool in fc.findMatches.count == expectedCount }
        let seqBefore = fc.findMatchesSeq

        rig.session.feedBytesForTests(Data((tick + "\r\n").utf8))
        var maxSliceMs = 0.0
        let end = Date(timeIntervalSinceNow: 1.2)
        while Date() < end {
            let t0 = DispatchTime.now().uptimeNanoseconds
            RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.005))
            let dt = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1_000_000.0
            maxSliceMs = max(maxSliceMs, dt)
        }
        let reSearched = pump(until: 10.0) { () -> Bool in fc.findMatchesSeq != seqBefore }
        return (maxSliceMs, reSearched)
    }

    /// With the bar open on a non-ASCII query, a streamed line makes the
    /// debounced refresh re-scan the scrollback; that block must not be a
    /// per-row amount longer than the same refresh for an ASCII query.
    func test_streamingWithNonAsciiQueryOpen_refreshBlockIsNoLongerPerRowThanAnAsciiQuery() throws {
        let (rig, captured) = try makeLoadedRig()
        let fc = rig.view.findController
        let n = captured.count

        // Flush the publish that the bulk feed queued, so it cannot land
        // inside a measurement window.
        let settled = pump(until: 10.0) { () -> Bool in
            guard let snap = rig.view.currentSnapshot else { return false }
            return snap.visibleRowsAsText().contains { $0.hasPrefix("step 029999") }
        }
        XCTAssertTrue(settled, "fixture: the bulk feed's publish must reach view.currentSnapshot")
        pump(until: 0.3) { false }

        let control = longestRunLoopBlockMs(rig, query: asciiControlQuery, expectedCount: 0, tick: "tick control")
        XCTAssertTrue(control.reSearched,
                      "fixture: streaming a line with the bar open must re-search the live ASCII query")

        let target = nonAsciiCases[0]
        let nonAscii = longestRunLoopBlockMs(rig, query: target.query, expectedCount: target.expected.count, tick: "tick nonascii")
        XCTAssertTrue(nonAscii.reSearched,
                      "streaming a line with the bar open must re-search the live non-ASCII query")
        XCTAssertEqual(fc.findMatches.count, target.expected.count,
                       "the refreshed non-ASCII search must still find the planted rows "
                       + "(\(target.query.debugDescription)): got [\(fmt(fc.findMatches))]")

        let excessUsPerRow = (nonAscii.maxSliceMs - control.maxSliceMs) * 1000.0 / Double(n)
        XCTAssertLessThan(
            excessUsPerRow, excessBudgetMicrosecondsPerRow,
            "with the find bar open on \(target.query.debugDescription) over \(n) ASCII rows, one streamed line "
            + "stalled the main runloop for \(String(format: "%.1f", nonAscii.maxSliceMs)) ms vs "
            + "\(String(format: "%.1f", control.maxSliceMs)) ms for the ASCII control "
            + "\(asciiControlQuery.debugDescription): +\(String(format: "%.1f", excessUsPerRow)) us/row, "
            + "budget \(excessBudgetMicrosecondsPerRow) us/row"
        )
        withExtendedLifetime(rig) {}
    }
}
