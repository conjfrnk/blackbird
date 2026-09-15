import XCTest
import AppKit
import Metal
@testable import Blackbird
import BBCore

/// Blind behaviour tests for trackpad scroll accumulation on the NORMAL
/// (scrollback) path of `TerminalView.scrollWheel`, written from the spec
/// without sight of the implementation.
///
/// Contract under test: in normal mode (no alt screen, no mouse
/// reporting) the wheel scrolls local scrollback through
/// `session.scroll(delta:)`, and fractional trackpad travel now
/// ACCUMULATES across events exactly like `WheelScrollAccumulator` with
/// `pointsPerLine = cellHeight / 2` (precise devices) and
/// `linesPerNotch = 3` (classic wheels). Pinned consequences:
///
///  1. Four precise events of `+cellHeight/4` each scroll TWO lines in
///     total, with the cumulative count after each event being
///     0 → 1 → 1 → 2 (each event is half a line; whole lines only).
///  2. One precise event of `+cellHeight` scrolls exactly 2 lines.
///  3. A one-point precise nudge on a ≥ 12-pt cell scrolls 0 lines
///     (through v0.8.1 it rounded away from zero to a full line).
///  4. Reversing direction discards the remainder: `+q, −q` → 0 total,
///     a further `−q` still 0 (the remainder restarted at the reversal),
///     and one more `−q` → one line the other way.
///  5. A classic wheel notch (`hasPreciseScrollingDeltas == false`,
///     `scrollingDeltaY = ∓1`) still scrolls 3 lines per notch.
///
/// **Direction.** Which sign of `scrollingDeltaY` moves toward OLDER
/// content is the product's choice, so each rig calibrates it once with
/// a full-cell event (whose 2-line result is itself asserted) and every
/// later expectation is expressed in "lines in the +deltaY direction".
/// The sign `session.scroll(delta:)` needs to move INTO history is also
/// probed rather than assumed, so the viewport can be parked mid-history
/// with headroom in both directions before any wheel event arrives.
///
/// **Event synthesis.** `NSEvent` has no scroll-wheel initializer, so
/// events come from
/// `CGEvent(scrollWheelEvent2Source:units:wheelCount:wheel1:wheel2:wheel3:)`
/// bridged through `NSEvent(cgEvent:)`. `.pixel` units bridge to a precise
/// event (`hasPreciseScrollingDeltas == true`) whose `scrollingDeltaY` is
/// the integer point count 1:1; `.line` units bridge to a classic event.
/// The CG bridge cannot carry FRACTIONAL points, so the rig pins a font
/// size whose (already whole-number) `cellHeight` is a multiple of 4 and
/// derives every delta from it: `q = cellHeight / 4` is then a whole
/// number of points and exactly half of `pointsPerLine = cellHeight / 2`.
/// Both properties are asserted on the fixture. The size is pinned via the
/// view's own per-view override (`increaseFontSize(_:)`, ⌘+), which never
/// writes `Preferences.shared` / UserDefaults.
///
/// **Memory / time pre-flight** (per `feedback_test_memory_safety`):
///  - One headless `TerminalSession` per rig (`makeHeadlessForTests()`:
///    no PTY, no child process), resized to a 40 × 6 grid (240 cells)
///    and fed 40 short lines (~300 bytes) — 34 lines of history.
///    `BBTerm`'s scrollback ring is lazily allocated, so the default cap
///    costs nothing beyond those 34 rows.
///  - One 640 × 240 headless `TerminalView` per rig; never added to a
///    window, never drawn. Up to ~12 font-size steps rebuild the glyph
///    atlas while hunting for a multiple-of-4 cell height (each a small
///    Metal texture; with the default Menlo pref it takes ≤ 2 steps).
///  - No runloop pumping, no timers, no expectations. `session.scroll`
///    and `feedBytesForTests` are synchronous (`coreQueue.sync`). Wall
///    time is dominated by `MTLCreateSystemDefaultDevice()`.
final class NormalScrollAccumulationBlindTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        TestHostTermination.shared.register()
    }

    // MARK: - Rig

    /// Where the viewport is parked before every wheel event: 10 lines
    /// into 34 lines of history, so up to 10 lines of travel in either
    /// direction is observable without hitting the 0 / historySize clamp.
    private static let parkedOffset = 10
    private static let historyLinesFed = 40
    private static let gridRows: UInt16 = 6

    /// Held together so nothing is deallocated mid-test. `TerminalView.session`
    /// is `weak`, so the strong `session` here is load-bearing.
    private final class Rig {
        let view: TerminalView
        let session: TerminalSession
        let recorder: RecordingPTY
        /// Whole number of points per cell row (asserted multiple of 4).
        let cellHeight: Int
        /// Sign of the `session.scroll(delta:)` argument that INCREASES
        /// `displayOffset` (moves into history). Probed, not assumed.
        let intoHistorySign: Int
        /// Sign of the `displayOffset` change produced by a POSITIVE
        /// `scrollingDeltaY`. Calibrated with one full-cell event.
        let offsetSignForPositiveDelta: Int

        init(view: TerminalView, session: TerminalSession, recorder: RecordingPTY,
             cellHeight: Int, intoHistorySign: Int, offsetSignForPositiveDelta: Int) {
            self.view = view
            self.session = session
            self.recorder = recorder
            self.cellHeight = cellHeight
            self.intoHistorySign = intoHistorySign
            self.offsetSignForPositiveDelta = offsetSignForPositiveDelta
        }

        /// One quarter of a cell in points — half of `pointsPerLine`.
        var quarterCell: Int32 { Int32(cellHeight / 4) }
        var fullCell: Int32 { Int32(cellHeight) }
    }

    private func currentOffset(_ session: TerminalSession,
                               file: StaticString = #filePath, line: UInt = #line) throws -> Int {
        try XCTUnwrap(session.takeSnapshotForTests(), "takeSnapshotForTests() returned nil",
                      file: file, line: line).displayOffset
    }

    /// Steps the per-view font size until `metrics.cellHeight` is a whole
    /// multiple of 4 (so `cellHeight/4` is a whole point count and
    /// `cellHeight/2` an exact half). Fails the fixture, never skips, if no
    /// size in the envelope qualifies.
    private struct FixtureFailure: Error {}

    private func pinCellHeightMultipleOfFour(_ view: TerminalView,
                                             file: StaticString = #filePath,
                                             line: UInt = #line) throws -> Int {
        // Step up first; if the global pref already sits at the top of the
        // envelope (⌘+ is a no-op there) turn around and step down.
        var stepUp = true
        for _ in 0..<24 {
            let h = view.metrics.cellHeight
            XCTAssertEqual(h, h.rounded(), "precondition: cellHeight is a whole number of points",
                           file: file, line: line)
            if h >= 12, h.truncatingRemainder(dividingBy: 4) == 0 {
                return Int(h)
            }
            let before = view.metrics.font.pointSize
            if stepUp { view.increaseFontSize(nil) } else { view.decreaseFontSize(nil) }
            if view.metrics.font.pointSize == before { stepUp.toggle() }
        }
        XCTFail("fixture: no font size in the envelope produced a cellHeight ≥ 12 that is a multiple of 4 (last: \(view.metrics.cellHeight))",
                file: file, line: line)
        throw FixtureFailure()
    }

    private func makeRig(file: StaticString = #filePath, line: UInt = #line) throws -> Rig {
        let device = try requireMetalDevice(file: file, line: line)
        let view = TerminalView(
            frame: NSRect(x: 0, y: 0, width: 640, height: 240),
            device: device
        )
        let cellHeight = try pinCellHeightMultipleOfFour(view, file: file, line: line)

        let session = TerminalSession.makeHeadlessForTests()
        session.resize(to: .init(cols: 40, rows: Self.gridRows))
        var feed = ""
        for n in 1...Self.historyLinesFed { feed += "line \(n)\r\n" }
        session.feedBytesForTests(Data(feed.utf8))

        view.session = session
        let recorder = RecordingPTY()
        view.ptyRecorderForTests = recorder

        let snap = try XCTUnwrap(session.takeSnapshotForTests(), "takeSnapshotForTests() returned nil",
                                 file: file, line: line)
        XCTAssertEqual(snap.rows, Int(Self.gridRows), "precondition: grid resized", file: file, line: line)
        XCTAssertGreaterThanOrEqual(snap.historySize, Self.parkedOffset * 2 + 4,
                                    "precondition: enough history to park mid-way with headroom",
                                    file: file, line: line)
        XCTAssertEqual(snap.displayOffset, 0, "precondition: fresh session is pinned to the bottom",
                       file: file, line: line)
        assertNormalMode(snap, file: file, line: line)
        view.render(snapshot: snap)

        // Probe which sign of `scroll(delta:)` moves into history.
        session.scroll(delta: Int32(Self.parkedOffset))
        var intoHistorySign = 1
        if try currentOffset(session, file: file, line: line) == 0 {
            session.scroll(delta: -Int32(Self.parkedOffset))
            intoHistorySign = -1
        }
        XCTAssertEqual(try currentOffset(session, file: file, line: line), Self.parkedOffset,
                       "precondition: session.scroll(delta:) parks the viewport \(Self.parkedOffset) lines into history",
                       file: file, line: line)

        // Calibrate the wheel direction with one full-cell precise event.
        // Spec consequence 2: exactly two lines, and no partial line left
        // over (cellHeight / (cellHeight/2) == 2 exactly).
        view.scrollWheel(with: try precise(points: Int32(cellHeight), file: file, line: line))
        let calibrated = try currentOffset(session, file: file, line: line) - Self.parkedOffset
        XCTAssertEqual(abs(calibrated), 2,
                       "calibration: one full-cell precise event must move exactly 2 lines (got \(calibrated))",
                       file: file, line: line)
        let sign = calibrated > 0 ? 1 : (calibrated < 0 ? -1 : 1)

        let rig = Rig(view: view, session: session, recorder: recorder,
                      cellHeight: cellHeight, intoHistorySign: intoHistorySign,
                      offsetSignForPositiveDelta: sign)
        try park(rig, file: file, line: line)
        return rig
    }

    /// Re-park the viewport at `parkedOffset` via the session (not the
    /// wheel), so a test starts from a known offset without touching the
    /// view's accumulator.
    private func park(_ rig: Rig, file: StaticString = #filePath, line: UInt = #line) throws {
        let now = try currentOffset(rig.session, file: file, line: line)
        let delta = (Self.parkedOffset - now) * rig.intoHistorySign
        if delta != 0 { rig.session.scroll(delta: Int32(delta)) }
        XCTAssertEqual(try currentOffset(rig.session, file: file, line: line), Self.parkedOffset,
                       "fixture: viewport re-parked", file: file, line: line)
    }

    /// Lines moved since parking, signed so that a POSITIVE `scrollingDeltaY`
    /// counts positive regardless of which way the product maps it.
    private func linesMoved(_ rig: Rig, file: StaticString = #filePath, line: UInt = #line) throws -> Int {
        let now = try currentOffset(rig.session, file: file, line: line)
        return (now - Self.parkedOffset) * rig.offsetSignForPositiveDelta
    }

    // MARK: - Event synthesis

    /// Precise (trackpad-style) event carrying `points` of vertical travel.
    private func precise(points: Int32, file: StaticString = #filePath, line: UInt = #line) throws -> NSEvent {
        let cg = try XCTUnwrap(
            CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1,
                    wheel1: points, wheel2: 0, wheel3: 0),
            "CGEvent(scrollWheelEvent2Source:) returned nil", file: file, line: line
        )
        let ev = try XCTUnwrap(NSEvent(cgEvent: cg), "NSEvent(cgEvent:) returned nil", file: file, line: line)
        XCTAssertEqual(ev.type, .scrollWheel, file: file, line: line)
        XCTAssertTrue(ev.hasPreciseScrollingDeltas,
                      "precondition: .pixel units must bridge to a precise (trackpad-style) event",
                      file: file, line: line)
        XCTAssertEqual(ev.scrollingDeltaY, Double(points), accuracy: 1e-9,
                       "precondition: scrollingDeltaY must bridge 1:1 from wheel1 for .pixel units",
                       file: file, line: line)
        XCTAssertFalse(ev.modifierFlags.contains(.option), "precondition: no Option (that path is local-scroll escape)",
                       file: file, line: line)
        return ev
    }

    /// Classic (non-precise) wheel event with the given notch delta.
    private func classic(notches: Int32, file: StaticString = #filePath, line: UInt = #line) throws -> NSEvent {
        let cg = try XCTUnwrap(
            CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1,
                    wheel1: notches, wheel2: 0, wheel3: 0),
            "CGEvent(scrollWheelEvent2Source:) returned nil", file: file, line: line
        )
        let ev = try XCTUnwrap(NSEvent(cgEvent: cg), "NSEvent(cgEvent:) returned nil", file: file, line: line)
        XCTAssertEqual(ev.type, .scrollWheel, file: file, line: line)
        XCTAssertFalse(ev.hasPreciseScrollingDeltas,
                       "precondition: .line units must bridge to a classic (non-precise) wheel event",
                       file: file, line: line)
        XCTAssertEqual(ev.scrollingDeltaY, Double(notches), accuracy: 1e-9,
                       "precondition: scrollingDeltaY must bridge 1:1 from wheel1 for .line units",
                       file: file, line: line)
        return ev
    }

    // MARK: - Fixture gates

    private func assertNormalMode(_ snap: BBSnapshot, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(snap.termMode.contains(.altScreen), "precondition: primary screen", file: file, line: line)
        XCTAssertTrue(snap.termMode.isDisjoint(with: [.mouseReportClick, .mouseMotion, .mouseDrag]),
                      "precondition: no mouse protocol", file: file, line: line)
    }

    /// Normal-mode scrolling is local: nothing may reach the PTY.
    private func assertNothingSentToPTY(_ rig: Rig, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(rig.recorder.sent.isEmpty,
                      "normal-mode wheel must scroll locally, never write to the PTY; got \(rig.recorder.sent.map { String(format: "%02X", $0) }.joined(separator: " "))",
                      file: file, line: line)
    }

    private func assertQuarterCellIsHalfALine(_ rig: Rig, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(rig.cellHeight % 4, 0, "precondition: cellHeight multiple of 4", file: file, line: line)
        XCTAssertEqual(Double(rig.quarterCell) / (Double(rig.cellHeight) / 2), 0.5, accuracy: 1e-12,
                       "precondition: a quarter-cell event is exactly half of pointsPerLine (= cellHeight/2)",
                       file: file, line: line)
    }

    // MARK: - 1. Accumulation across quarter-cell events

    /// Four events of cellHeight/4 each = one cell of travel = TWO lines
    /// (pointsPerLine is cellHeight/2), delivered as 0, 1, 1, 2 cumulative.
    func test_fourQuarterCellEvents_accumulateToTwoLines_zeroOneOneTwo() throws {
        let rig = try makeRig()
        assertQuarterCellIsHalfALine(rig)
        let q = rig.quarterCell

        rig.view.scrollWheel(with: try precise(points: q))
        XCTAssertEqual(try linesMoved(rig), 0, "after 1 × q (0.5 line): no whole line yet")

        rig.view.scrollWheel(with: try precise(points: q))
        XCTAssertEqual(try linesMoved(rig), 1, "after 2 × q (1.0 line): one line")

        rig.view.scrollWheel(with: try precise(points: q))
        XCTAssertEqual(try linesMoved(rig), 1, "after 3 × q (1.5 lines): still one line")

        rig.view.scrollWheel(with: try precise(points: q))
        XCTAssertEqual(try linesMoved(rig), 2, "after 4 × q (2.0 lines): two lines — not four")

        assertNothingSentToPTY(rig)
    }

    /// Same travel, opposite sign: the accumulator is symmetric.
    func test_fourNegativeQuarterCellEvents_accumulateToMinusTwoLines() throws {
        let rig = try makeRig()
        assertQuarterCellIsHalfALine(rig)
        let q = rig.quarterCell

        rig.view.scrollWheel(with: try precise(points: -q))
        XCTAssertEqual(try linesMoved(rig), 0)
        rig.view.scrollWheel(with: try precise(points: -q))
        XCTAssertEqual(try linesMoved(rig), -1)
        rig.view.scrollWheel(with: try precise(points: -q))
        XCTAssertEqual(try linesMoved(rig), -1)
        rig.view.scrollWheel(with: try precise(points: -q))
        XCTAssertEqual(try linesMoved(rig), -2)

        assertNothingSentToPTY(rig)
    }

    // MARK: - 2. Full-cell event

    /// cellHeight / (cellHeight/2) = 2 lines, exactly, from one event.
    func test_oneFullCellEvent_scrollsExactlyTwoLines() throws {
        let rig = try makeRig()
        rig.view.scrollWheel(with: try precise(points: rig.fullCell))
        XCTAssertEqual(try linesMoved(rig), 2, "one cell of precise travel = two lines")
        assertNothingSentToPTY(rig)
    }

    /// A full-cell event leaves no remainder: two of them give exactly 4,
    /// and a following half-line (quarter cell) still gives nothing.
    func test_twoFullCellEvents_thenQuarter_isFourLines() throws {
        let rig = try makeRig()
        assertQuarterCellIsHalfALine(rig)
        rig.view.scrollWheel(with: try precise(points: rig.fullCell))
        rig.view.scrollWheel(with: try precise(points: rig.fullCell))
        XCTAssertEqual(try linesMoved(rig), 4)
        rig.view.scrollWheel(with: try precise(points: rig.quarterCell))
        XCTAssertEqual(try linesMoved(rig), 4, "a full-cell event carries no remainder into the next")
        assertNothingSentToPTY(rig)
    }

    // MARK: - 3. Tiny nudge

    /// One point on a ≥ 12-pt cell is < 1/6 of pointsPerLine: zero lines.
    func test_onePointNudge_scrollsZeroLines() throws {
        let rig = try makeRig()
        XCTAssertGreaterThanOrEqual(rig.cellHeight, 12, "precondition: cell ≥ 12 pt")
        rig.view.scrollWheel(with: try precise(points: 1))
        XCTAssertEqual(try linesMoved(rig), 0, "a 1-pt jitter must not move a whole line")
        rig.view.scrollWheel(with: try precise(points: -1))
        XCTAssertEqual(try linesMoved(rig), 0, "nor in the other direction")
        assertNothingSentToPTY(rig)
    }

    /// One-point nudges accumulate: after cellHeight/2 of them (one
    /// pointsPerLine of travel) exactly one line has moved, and not before.
    func test_onePointNudges_accumulateToOneLineAtHalfCell() throws {
        let rig = try makeRig()
        let pointsPerLine = rig.cellHeight / 2
        XCTAssertEqual(pointsPerLine * 2, rig.cellHeight, "precondition: cellHeight even")
        for i in 1..<pointsPerLine {
            rig.view.scrollWheel(with: try precise(points: 1))
            XCTAssertEqual(try linesMoved(rig), 0, "after \(i) of \(pointsPerLine) points: not yet a line")
        }
        rig.view.scrollWheel(with: try precise(points: 1))
        XCTAssertEqual(try linesMoved(rig), 1, "after \(pointsPerLine) points (= cellHeight/2): exactly one line")
        assertNothingSentToPTY(rig)
    }

    // MARK: - 4. Direction reversal discards the remainder

    func test_reversal_discardsRemainder_thenAccumulatesInNewDirection() throws {
        let rig = try makeRig()
        assertQuarterCellIsHalfALine(rig)
        let q = rig.quarterCell

        rig.view.scrollWheel(with: try precise(points: q))
        XCTAssertEqual(try linesMoved(rig), 0, "+q: half a line pending")

        rig.view.scrollWheel(with: try precise(points: -q))
        XCTAssertEqual(try linesMoved(rig), 0, "−q after +q: reversal discards the +half; −half pending, 0 total")

        rig.view.scrollWheel(with: try precise(points: -q))
        XCTAssertEqual(try linesMoved(rig), -1,
                       "second −q: −half + −half = one line the other way (remainder restarted at the reversal)")

        rig.view.scrollWheel(with: try precise(points: -q))
        XCTAssertEqual(try linesMoved(rig), -1, "third −q: half pending again")

        assertNothingSentToPTY(rig)
    }

    /// Mirror of the above starting negative — the discard is not
    /// sign-specific.
    func test_reversal_fromNegative_discardsRemainder() throws {
        let rig = try makeRig()
        assertQuarterCellIsHalfALine(rig)
        let q = rig.quarterCell

        rig.view.scrollWheel(with: try precise(points: -q))
        XCTAssertEqual(try linesMoved(rig), 0)
        rig.view.scrollWheel(with: try precise(points: q))
        XCTAssertEqual(try linesMoved(rig), 0, "reversal: the −half is dropped, +half pending")
        rig.view.scrollWheel(with: try precise(points: q))
        XCTAssertEqual(try linesMoved(rig), 1)
        assertNothingSentToPTY(rig)
    }

    /// Three quarter-cells one way (1 line + half pending), then a full
    /// cell the other way: the pending half is dropped, so the net is
    /// exactly 1 − 2 = −1, not 1 − 2.5 rounded somewhere.
    func test_reversal_afterWholeLine_dropsOnlyTheFraction() throws {
        let rig = try makeRig()
        assertQuarterCellIsHalfALine(rig)
        let q = rig.quarterCell
        rig.view.scrollWheel(with: try precise(points: q))
        rig.view.scrollWheel(with: try precise(points: q))
        rig.view.scrollWheel(with: try precise(points: q))
        XCTAssertEqual(try linesMoved(rig), 1)
        rig.view.scrollWheel(with: try precise(points: -rig.fullCell))
        XCTAssertEqual(try linesMoved(rig), -1, "1 line forward, then a clean 2 back = −1 net")
        assertNothingSentToPTY(rig)
    }

    // MARK: - 5. Classic wheel: 3 lines per notch, unchanged

    func test_classicWheel_minusOneNotch_scrollsThreeLines() throws {
        let rig = try makeRig()
        rig.view.scrollWheel(with: try classic(notches: -1))
        XCTAssertEqual(try linesMoved(rig), -3, "one classic notch = three lines, same sign convention as precise deltas")
        assertNothingSentToPTY(rig)
    }

    func test_classicWheel_plusOneNotch_scrollsThreeLinesTheOtherWay() throws {
        let rig = try makeRig()
        rig.view.scrollWheel(with: try classic(notches: 1))
        XCTAssertEqual(try linesMoved(rig), 3)
        assertNothingSentToPTY(rig)
    }

    /// Classic events are per-notch and stateless: two opposite notches
    /// cancel exactly.
    func test_classicWheel_oppositeNotches_cancel() throws {
        let rig = try makeRig()
        rig.view.scrollWheel(with: try classic(notches: -1))
        XCTAssertEqual(try linesMoved(rig), -3)
        rig.view.scrollWheel(with: try classic(notches: 1))
        XCTAssertEqual(try linesMoved(rig), 0)
        assertNothingSentToPTY(rig)
    }

    // MARK: - 6. Direction consistency

    /// The sign convention is one convention: a +1 classic notch and a
    /// +cellHeight precise event move the viewport the same way, and the
    /// negative counterparts move it the opposite way.
    func test_preciseAndClassic_shareOneDirectionConvention() throws {
        let rig = try makeRig()

        rig.view.scrollWheel(with: try precise(points: rig.fullCell))
        let preciseSign = try linesMoved(rig).signum()
        XCTAssertEqual(preciseSign, 1, "by construction of linesMoved(): +delta counts positive")
        try park(rig)

        rig.view.scrollWheel(with: try classic(notches: 1))
        let classicPlus = try linesMoved(rig).signum()
        XCTAssertEqual(classicPlus, preciseSign, "+1 notch goes the same way as +cellHeight")
        try park(rig)

        rig.view.scrollWheel(with: try precise(points: -rig.fullCell))
        let preciseMinus = try linesMoved(rig).signum()
        XCTAssertEqual(preciseMinus, -preciseSign, "−cellHeight reverses")
        try park(rig)

        rig.view.scrollWheel(with: try classic(notches: -1))
        let classicMinus = try linesMoved(rig).signum()
        XCTAssertEqual(classicMinus, -preciseSign, "−1 notch reverses")

        assertNothingSentToPTY(rig)
    }
}
