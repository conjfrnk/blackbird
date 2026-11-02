import XCTest
import AppKit
import Metal
@testable import Blackbird
import BBCore

/// Blind behaviour tests for two properties of the find bar's regex mode
/// (spec, not implementation):
///
///  1. A regex query that misses its 250 ms scan deadline ONCE must not stay
///     dead for the rest of the session. A miss is about the buffer and the
///     machine at that instant (a big scrollback, a loaded box), not about the
///     query: once the buffer no longer contains what made the scan slow, live
///     output with the bar open must again keep the query's match count and
///     highlights fresh, exactly as it does for any other query.
///     The fixture models a "transient" miss deterministically: a polynomial
///     pattern (`.*.*.*.*.*x`) over one 100-column row with no `x` blows the
///     deadline, then that row is overwritten in place by a light row that
///     does contain an `x`, and output keeps streaming. The very same query
///     is now trivially cheap, so the find bar must show its match.
///
///  2. The machinery that makes a scan cancellable (so a runaway pattern stops
///     with the deadline) must not tax ordinary scans. A regex search over a
///     large scrollback with a cheap, well-behaved pattern has to cost about
///     what the plain regex engine costs for the same rows, not a large
///     multiple of it (every wasted millisecond comes out of the 250 ms
///     budget that real big-buffer queries need).
///     The yardstick is measured in-process, interleaved with the find-bar
///     scans so both see the same machine load: the plain
///     `NSRegularExpression.enumerateMatches` loop over the same row strings,
///     minimum of several runs for each side.
///
/// Fixture: headless `TerminalView` + headless `TerminalSession` (real BBTerm,
/// no PTY, no window, no MainWindowController). Cost, latch test: 120x6 grid, a
/// few dozen short lines, ~1.5 s of runloop pumping on a fixed build, ~10 s on
/// a buggy one (it waits out a bounded recovery window). Cost, scan-cost test: 80x6
/// grid with `perfRowCount` (10 000) scrollback rows of <= 72 cells = at most
/// ~26 MB of cell storage and a ~0.7 MB feed; seven timed runs of ~10-120 ms
/// each plus settling; total ~5 s.
final class FindRegexTimeoutLatchBlindTests: XCTestCase {

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

    private func makeRig(cols: UInt16, file: StaticString = #filePath, line: UInt = #line) throws -> Rig {
        let view = try XCTUnwrap(TerminalView.makeHeadlessForTests(), "Metal device required", file: file, line: line)
        let session = TerminalSession.makeHeadlessForTests()
        session.resize(to: .init(cols: cols, rows: 6))
        view.session = session
        return Rig(view: view, session: session)
    }

    @discardableResult
    private func pump(until timeout: TimeInterval, step: TimeInterval = 0.005, _ condition: () -> Bool) -> Bool {
        let deadline = Date(timeIntervalSinceNow: timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: step))
        }
        return condition()
    }

    /// Unconditionally run the main runloop for `seconds`.
    private func settle(_ seconds: TimeInterval) {
        pump(until: seconds) { false }
    }

    /// Feed `text` and wait until the view's snapshot SHOWS a row starting
    /// with `lastRowPrefix`.
    private func feed(_ rig: Rig, text: String, waitForRowPrefix lastRowPrefix: String,
                      file: StaticString = #filePath, line: UInt = #line) {
        rig.session.feedBytesForTests(Data(text.utf8))
        let landed = pump(until: 5.0) {
            guard let snap = rig.view.currentSnapshot else { return false }
            return snap.visibleRowsAsText().contains { $0.hasPrefix(lastRowPrefix) }
        }
        XCTAssertTrue(landed, "publish showing a row starting '\(lastRowPrefix)' must reach the view within 5 s",
                      file: file, line: line)
    }

    private func feed(_ rig: Rig, lines: [String],
                      file: StaticString = #filePath, line: UInt = #line) {
        guard let last = lines.last else { return }
        feed(rig, text: lines.joined(separator: "\r\n") + "\r\n", waitForRowPrefix: last, file: file, line: line)
    }

    /// Open the bar in regex mode (no query yet, so no search runs) and type
    /// `query`. Returns without yielding to the runloop, so any async scan is
    /// still in flight.
    @discardableResult
    private func startRegexSearch(_ rig: Rig, query: String,
                                  file: StaticString = #filePath, line: UInt = #line) throws -> FindBar {
        let fc = rig.fc
        if fc.findBar == nil { fc.installFindBar() }
        let bar = try XCTUnwrap(fc.findBar, file: file, line: line)
        if !bar.options.regex { bar.toggleRegexMode(nil) }
        XCTAssertTrue(bar.options.regex, "fixture: regex mode must be on", file: file, line: line)
        bar.setQuery(query)
        return bar
    }

    private func label(_ rig: Rig) -> String {
        rig.fc.findBar?._matchLabelStringForTests() ?? "<no bar>"
    }

    // MARK: - A transient timeout must not latch the query forever

    /// Polynomial in the row length when the row has no `x` (several adjacent
    /// unbounded quantifiers: passes the ReDoS pre-gate on purpose, see
    /// `RegexSafetyGate`), instant when the row is short or contains one.
    private static let slowPattern = ".*.*.*.*.*x"

    /// 100 ordinary characters, no letter 'x': 7-15 s of standalone ICU time
    /// for `slowPattern` on Apple silicon, i.e. it always blows 250 ms.
    private static let heavyRow: String = {
        let unit = "just an ordinary log line with no letter of that kind in it at all; "
        return String(String(repeating: unit, count: 3).prefix(100))
    }()

    private static let lightRow = "tiny x marker"

    /// Control (passes before and after the fix): the same query over the
    /// light content, with no history of a timeout, publishes its single match
    /// promptly. Proves the recovery target in the next test is reachable.
    func test_control_slowPatternOverLightRowPublishesItsMatch() throws {
        let rig = try makeRig(cols: 120)
        feed(rig, lines: ["header", Self.lightRow])
        try startRegexSearch(rig, query: Self.slowPattern)
        let published = pump(until: 3.0) { rig.fc.findMatchesSeq != nil }
        XCTAssertTrue(published, "'\(Self.slowPattern)' over short rows must publish within 3 s")
        XCTAssertEqual(rig.fc.findMatches.count, 1,
                       "exactly one 'x' in the buffer ('\(Self.lightRow)'); label '\(label(rig))'")
    }

    /// After one deadline miss, once the cause of the slowness is gone and
    /// output keeps flowing, the bar must resume live refresh of the SAME
    /// query: the match count has to catch up (1 match), keep tracking the
    /// live snapshot, and then follow brand-new matching output (2 matches).
    func test_timedOutRegexQuery_resumesLiveRefreshOnceTheBufferChanges() throws {
        let rig = try makeRig(cols: 120)
        let fc = rig.fc
        feed(rig, lines: ["header", Self.heavyRow])
        let heavyVisible = rig.view.currentSnapshot?.visibleRowsAsText().contains { $0.hasPrefix(Self.heavyRow) } ?? false
        XCTAssertTrue(heavyVisible, "fixture: the full heavy row must be in the buffer")

        try startRegexSearch(rig, query: Self.slowPattern)

        // 250 ms deadline plus generous slack for the worker to stand down.
        settle(1.0)
        XCTAssertEqual(fc.findMatches.count, 0,
                       "precondition: '\(Self.slowPattern)' over the heavy row must NOT have produced results "
                       + "(the scan has to have missed its 250 ms deadline); label '\(label(rig))'")
        XCTAssertNil(fc.findMatchesSeq,
                     "precondition: a timed-out scan must not stamp findMatchesSeq")

        // The transient condition passes: overwrite the heavy row in place
        // (cursor to row 2, erase line, write the light row, cursor back to
        // row 3) so no scrolling is involved.
        feed(rig, text: "\u{1B}[2;1H\u{1B}[2K\(Self.lightRow)\u{1B}[3;1H", waitForRowPrefix: Self.lightRow)
        let stillHeavy = rig.view.currentSnapshot?.visibleRowsAsText().contains { $0.hasPrefix(Self.heavyRow) } ?? true
        XCTAssertFalse(stillHeavy, "fixture: the heavy row must be gone from the buffer")

        // Output keeps streaming with the bar open (a build log, a tail -f).
        // None of these lines contains an 'x'. Bounded recovery window: the
        // query must come back within it, whether the implementation clears
        // its timeout mark on buffer change, on a backoff, or both.
        let window: TimeInterval = 8.0
        let started = Date()
        var fed = 0
        var recovered = false
        while Date().timeIntervalSince(started) < window {
            rig.session.feedBytesForTests(Data("streaming line \(fed)\r\n".utf8))
            fed += 1
            if pump(until: 0.15, { fc.findMatches.count == 1 }) { recovered = true; break }
        }
        let elapsed = Date().timeIntervalSince(started)
        XCTAssertTrue(recovered,
                      "after the buffer stopped containing the slow row, the SAME query must again produce its "
                      + "single match through live refresh; still \(fc.findMatches.count) matches after "
                      + "\(String(format: "%.1f", elapsed)) s and \(fed) streamed lines (label '\(label(rig))', "
                      + "findMatchesSeq \(String(describing: fc.findMatchesSeq)), live seq "
                      + "\(String(describing: rig.view.currentSnapshot?.sequenceID)))")
        guard recovered else { return }

        // Output stopped: the cached matches must catch up to the live snapshot.
        let synced = pump(until: 3.0) {
            fc.findMatchesSeq != nil && fc.findMatchesSeq == rig.view.currentSnapshot?.sequenceID
        }
        XCTAssertTrue(synced,
                      "once recovered, findMatchesSeq (\(String(describing: fc.findMatchesSeq))) must reach the live "
                      + "snapshot's sequenceID (\(String(describing: rig.view.currentSnapshot?.sequenceID)))")

        // And it keeps following new matching output.
        rig.session.feedBytesForTests(Data("another x line\r\n".utf8))
        let followed = pump(until: 3.0) { fc.findMatches.count == 2 }
        XCTAssertEqual(fc.findMatches.count, 2,
                       "a new matching line fed after recovery must be picked up by live refresh "
                       + "(waited \(followed ? "<3" : "3") s); label '\(label(rig))'")
    }

    // MARK: - The cancellation hook must not tax ordinary scans

    private static let perfRowCount = 10_000
    private static let perfPattern = #"status=5\d\d"#

    /// <= 72 cells, so no soft wrap on an 80-column grid. `status=200` never
    /// matches `perfPattern`; only the three sentinel rows below do.
    private static func logRow(_ i: Int) -> String {
        String(format: "2026-11-02T10:%02d:%02d INFO w%02d req=%05d /api/v1/items/%03d status=200 %dms",
               i % 60, (i / 60) % 60, i % 17, (i * 7919) % 100_003, i % 1000, i % 97)
    }

    private static func perfRows() -> [String] {
        var rows: [String] = []
        rows.reserveCapacity(perfRowCount)
        for i in 0..<perfRowCount { rows.append(logRow(i)) }
        rows[0] = "2026-11-02T10:00:00 INFO w00 status=503 oldest"
        rows[perfRowCount - 3] = "2026-11-02T10:59:58 INFO w01 status=504 near-end"
        rows[perfRowCount - 2] = "2026-11-02T10:59:59 INFO w02 status=505 last"
        return rows
    }

    private func feedPerfRows(_ rig: Rig, _ rows: [String]) {
        let chunk = 2000
        var i = 0
        while i < rows.count {
            let hi = min(rows.count, i + chunk)
            feed(rig, text: rows[i..<hi].joined(separator: "\r\n") + "\r\n", waitForRowPrefix: rows[hi - 1])
            i = hi
        }
    }

    /// One plain-engine pass over `rows[range]`: one `enumerateMatches` per
    /// row, no options. Returns elapsed milliseconds and the match count.
    private func plainScan(_ rows: [String], _ range: Range<Int>, _ regex: NSRegularExpression) -> (millis: Double, matches: Int) {
        var matches = 0
        let t0 = DispatchTime.now().uptimeNanoseconds
        for k in range {
            let row = rows[k]
            let ns = row as NSString
            regex.enumerateMatches(in: row, options: [], range: NSRange(location: 0, length: ns.length)) {
                (_: NSTextCheckingResult?, _: NSRegularExpression.MatchingFlags, _: UnsafeMutablePointer<ObjCBool>) -> Void in
                matches += 1
            }
        }
        let t1 = DispatchTime.now().uptimeNanoseconds
        return (Double(t1 - t0) / 1e6, matches)
    }

    /// Busy-wait on the calling thread so the CPU is at full clock before a
    /// timed section (a 10-20 ms measurement started cold is dominated by the
    /// frequency ramp, and the plain yardstick would be inflated relative to
    /// a scan that runs while the core is already hot).
    private func spinCPU(milliseconds: Double) {
        let end = DispatchTime.now().uptimeNanoseconds + UInt64(milliseconds * 1e6)
        var x = 0.0
        while DispatchTime.now().uptimeNanoseconds < end { x += sin(x) + 1 }
        if x < 0 { print(x) }   // keep the loop observable
    }

    /// Runs `pattern` through the find bar `runs` times over `rows` (already
    /// fed to `rig`) and returns the best find-bar scan time and the best
    /// plain-engine time, both in milliseconds. The find-bar side is timed
    /// from the moment `setQuery` returns (the row capture is synchronous
    /// inside it) until the results are published. Each run warms the CPU,
    /// takes the best of three plain passes, then immediately times one
    /// find-bar scan, so both sides see the same machine state and load.
    private func measure(pattern: String, rows: [String], rig: Rig, runs: Int,
                         file: StaticString = #filePath, line: UInt = #line) throws -> (app: Double, plain: Double) {
        let regex = try NSRegularExpression(pattern: pattern, options: [])
        let fc = rig.fc
        let snap = try XCTUnwrap(rig.view.currentSnapshot, "fixture: snapshot", file: file, line: line)
        XCTAssertGreaterThanOrEqual(snap.historySize, rows.count - 10,
                                    "fixture: (almost) every fed row must be retained in scrollback", file: file, line: line)

        // Warm-up: the first publish scrolls the viewport to the oldest match
        // (a snapshot change, hence a coalesced refresh scan ~100 ms later);
        // let all of that finish before anything is timed.
        let bar = try startRegexSearch(rig, query: pattern, file: file, line: line)
        let warm = pump(until: 5.0) { fc.findMatchesSeq != nil }
        XCTAssertTrue(warm, "fixture: the warm-up scan of '\(pattern)' over \(rows.count) rows must publish within 5 s "
                      + "(label '\(label(rig))')", file: file, line: line)
        settle(0.7)

        var plainBest = Double.infinity
        var appBest = Double.infinity
        for _ in 0..<runs {
            spinCPU(milliseconds: 40)
            for _ in 0..<3 {
                let plain = plainScan(rows, 0..<rows.count, regex)
                XCTAssertEqual(plain.matches, 3, "yardstick: the plain engine must find exactly the three sentinels",
                               file: file, line: line)
                plainBest = min(plainBest, plain.millis)
            }
            fc.clearMatches()
            bar.setQuery(pattern)
            let t0 = DispatchTime.now().uptimeNanoseconds
            let ok = pump(until: 5.0, step: 0.001) { fc.findMatchesSeq != nil }
            let t1 = DispatchTime.now().uptimeNanoseconds
            XCTAssertTrue(ok, "'\(pattern)' over \(rows.count) rows must publish within 5 s (label '\(label(rig))')",
                          file: file, line: line)
            XCTAssertEqual(fc.findMatches.count, 3,
                           "the three sentinel rows (oldest, near-end, last) are the only matches", file: file, line: line)
            appBest = min(appBest, Double(t1 - t0) / 1e6)
            settle(0.3)
        }
        return (appBest, plainBest)
    }

    /// Upper bound for (find-bar scan time) / (plain engine time) on the cheap
    /// workload above. Plain `enumerateMatches` per row is the floor; the find
    /// bar legitimately adds per-row bookkeeping (column mapping, match
    /// tuples, the dispatch hop and the publish), so parity is not expected.
    /// An implementation whose cancellation machinery is free for ordinary
    /// rows lands well below this; one that taxes every row with a progress
    /// hook lands far above it.
    private static let maxScanCostRatio = 1.8

    func test_regexScanOverLargeScrollback_isNotTaxedByTheCancellationHook() throws {
        let rig = try makeRig(cols: 80)
        let rows = Self.perfRows()
        feedPerfRows(rig, rows)

        let m = try measure(pattern: Self.perfPattern, rows: rows, rig: rig, runs: 7)
        let ratio = m.app / m.plain
        print(String(format: "FindRegexTimeoutLatchBlindTests: '%@' over %d scrollback rows: plain engine %.1f ms, find bar %.1f ms, ratio %.2f (limit %.2f)",
                     Self.perfPattern, rows.count, m.plain, m.app, ratio, Self.maxScanCostRatio))

        // Non-vacuous: the scans being timed really walked the whole buffer
        // (buffer line of rows[k] is k - historySize; rows[0] is the oldest).
        let snap = try XCTUnwrap(rig.view.currentSnapshot, "snapshot")
        let expectedLines: [Int32] = [0, rows.count - 3, rows.count - 2].map { Int32($0 - snap.historySize) }
        XCTAssertEqual(rig.fc.findMatches.map { $0.line }, expectedLines,
                       "the find bar must have found the oldest scrollback sentinel and both sentinels near the live end")
        XCTAssertLessThanOrEqual(ratio, Self.maxScanCostRatio,
                                 "a cheap regex ('\(Self.perfPattern)') over \(rows.count) scrollback rows takes "
                                 + "\(String(format: "%.1f", m.app)) ms through the find bar vs \(String(format: "%.1f", m.plain)) ms "
                                 + "for the plain regex engine over the same rows (\(String(format: "%.2f", ratio))x, limit "
                                 + "\(Self.maxScanCostRatio)x): the cancellation machinery must not tax ordinary scans")
    }
}
