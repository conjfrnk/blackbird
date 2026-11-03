import XCTest
import AppKit
@testable import Blackbird

/// Blind-authored regression tests for **a text-size step that is queued
/// behind a pending coalesced window resize must never leave the terminal
/// core (and therefore the PTY winsize) at a grid size different from the one
/// the view last computed**.
///
/// Written purely from the observable contract, WITHOUT reading the bodies of
/// `ResizeController.swift` / `propagateResize` / `applyEffectiveFont`
/// (CLAUDE.md "Author new behavior tests blind"). Only the documented
/// contracts were used:
///
///   - A *column* change of the view (window drag) is delivered through the
///     latest-wins coalesced path, which hands the reflow to `coreQueue` and
///     keeps `hasPendingCoalescedResize == true` until it has been applied.
///   - A text-size step (`⌘+`, `⌘-`, `⌘0`, pinch, Settings slider) re-derives
///     the grid from the new cell metrics and delivers it off-main.
///   - `coreQueue` is a SERIAL queue, so the core can only ever end up at the
///     size of whichever resize work item it runs LAST.
///   - The view records the grid it last computed in
///     `lastPropagatedSizeForTesting()`; the shell/PTY must be told that same
///     grid. "The view is F-sized but the grid is D-sized" is a bug no matter
///     which path produced D.
///
/// ## The scenario (why it is deterministic here)
///
/// In production the window between "resize queued" and "resize starts" is the
/// feed backlog ahead of it on `coreQueue` (bounded by the 4 MiB feed budget,
/// roughly 150 ms). The tests reproduce that backlog exactly, and
/// deterministically, by parking a blocker on `session.coreQueue` BEFORE the
/// events fire, then releasing it once every event has been delivered on main:
///
///   1. a width change that crosses a column boundary  (queues coalesced B1)
///   2. a text-size step                                (queues async A, grid D)
///   3. another window resize to a different grid       (grid F, newest)
///
/// Final contract: after `coreQueue` drains, the core grid equals F (the grid
/// the view last computed), and stays there.
///
/// ## What each test pins
///
///   - `test_fontStepBehindCoalescedResize_thenShrink_...` the headline
///     sequence with `⌘+` and a shrinking drag.
///   - `test_fontResetBehindCoalescedResize_thenShrink_...` same ordering via
///     the `⌘0` (drop the per-view override) entry point.
///   - `test_fontStepBehindCoalescedResize_thenRowOnlyChange_...` the newest
///     resize keeps the column count (it is "row-only" relative to D), the
///     path that, while a coalesced resize is outstanding, must still not
///     be overtaken by the stale font-step grid.
///   - Two CONTROLS that must pass before and after any fix: the same rig
///     without event 3, and without event 1. They prove the blocker rig,
///     the drain, and the core-grid probe are not vacuous (a rig that could
///     not observe a correct ordering could not be trusted to flag a wrong
///     one).
///
/// ## Cost / safety (repo rules)
///
///   - One headless `TerminalView` + one headless (PTY-less) `TerminalSession`
///     per test; no `MainWindowController`, no window, no real shell, no
///     keystroke / CGEvent injection.
///   - Grids stay under ~120 x 35 with an EMPTY scrollback: well under 1 MB of
///     cell storage per test; wall clock well under a second per test.
///   - `coreQueue` is blocked only while main performs three cheap view calls
///     that must not need the core queue. The blocker also self-releases after
///     a bounded timeout so a regression that made one of those calls wait on
///     `coreQueue` slows the test down instead of hanging the xctest host.
///   - `Preferences.shared.fontSize` is saved / restored around every test.
@MainActor
final class FontStepBehindCoalescedResizeBlindTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        TestHostTermination.shared.register()
    }

    /// Headless sessions created by a test. Held strongly because
    /// `TerminalView.session` is `weak`; terminated in `tearDown`.
    private var liveSessions: [TerminalSession] = []

    private var originalFontSize: Double = 13

    override func setUp() {
        super.setUp()
        originalFontSize = Preferences.shared.fontSize
        Preferences.shared.fontSize = 13
        pumpMainQueue()
    }

    override func tearDown() {
        for session in liveSessions { session.terminate() }
        liveSessions.removeAll()
        Preferences.shared.fontSize = originalFontSize
        pumpMainQueue()
        super.tearDown()
    }

    // MARK: - Rig

    /// One event delivered to the view on the main thread.
    private enum Step {
        /// `view.setFrameSize` (a window / view resize).
        case resize(width: CGFloat, height: CGFloat)
        /// `⌘+`: per-view text size +1 pt.
        case fontUp
        /// `⌘-`: per-view text size -1 pt.
        case fontDown
        /// `⌘0`: drop the per-view override.
        case fontReset
    }

    /// What the rig measured. Plain value type so the tests' failure messages
    /// can print every number.
    private struct Outcome {
        /// `hasPendingCoalescedResize` right after the FIRST step (the
        /// premise that the coalesced work item is really outstanding).
        let pendingAfterFirstStep: Bool
        /// The view's computed grid after each step, in order.
        let viewGrids: [Grid]
        /// The view's font point size after each step, in order.
        let pointSizes: [CGFloat]
        /// The core grid immediately after `coreQueue` fully drained.
        let coreAfterDrain: Grid
        /// The core grid again after a further quiet period.
        let coreAfterSettle: Grid

        var finalViewGrid: Grid { viewGrids[viewGrids.count - 1] }
    }

    private struct Grid: Equatable, CustomStringConvertible {
        let cols: Int
        let rows: Int
        var description: String { "\(cols)x\(rows)" }
    }

    /// A headless view + headless session, primed with one frame change and
    /// fully settled: the core grid equals the view's grid and nothing is
    /// outstanding. This is the quiet starting state of the trigger.
    private func makeSettledView(
        width: CGFloat = 600,
        height: CGFloat = 400
    ) throws -> (view: TerminalView, session: TerminalSession) {
        let view = try XCTUnwrap(TerminalView.makeHeadlessForTests())
        let session = TerminalSession.makeHeadlessForTests()
        liveSessions.append(session)
        view.session = session
        view.setFrameSize(NSSize(width: width, height: height))
        try settle(view: view, session: session, what: "priming \(width)x\(height)")
        return (view, session)
    }

    /// Wait until the core has applied everything the view asked for, and
    /// assert the rig is in sync (so a later mismatch can only come from the
    /// events under test).
    private func settle(view: TerminalView, session: TerminalSession, what: String) throws {
        let grid = try XCTUnwrap(
            view.lastPropagatedSizeForTesting(),
            "premise (\(what)): the view must have propagated a grid"
        )
        waitForSessionGrid(session, cols: Int(grid.cols), rows: Int(grid.rows))
        drainCoreQueue(session)
        let core = try XCTUnwrap(
            session.takeSnapshotForTests(),
            "premise (\(what)): the session core queue must answer"
        )
        XCTAssertEqual(
            Grid(cols: core.cols, rows: core.rows),
            Grid(cols: Int(grid.cols), rows: Int(grid.rows)),
            "premise (\(what)): with nothing in flight the core grid must equal the "
            + "view's grid before the trigger sequence starts"
        )
        XCTAssertGreaterThan(Int(grid.cols), 2, "premise (\(what)): a real grid, not the clamp floor")
    }

    /// Park a blocker on the session's core queue, deliver `steps` on main,
    /// release the blocker, drain the queue completely and measure.
    private func runBlocked(
        view: TerminalView,
        session: TerminalSession,
        steps: [Step]
    ) throws -> Outcome {
        let gate = DispatchSemaphore(value: 0)
        // The blocker occupies coreQueue (the serial queue every resize work
        // item runs on) like a large PTY feed backlog does. The bounded wait
        // keeps a misbehaving build from hanging the host.
        session.coreQueue.async { () -> Void in
            _ = gate.wait(timeout: .now() + 6)
        }
        // Extra signals are harmless; this guarantees release if a step throws.
        defer { gate.signal() }

        var pendingAfterFirst = false
        var grids: [Grid] = []
        var sizes: [CGFloat] = []
        for (index, step) in steps.enumerated() {
            switch step {
            case .resize(let width, let height):
                view.setFrameSize(NSSize(width: width, height: height))
            case .fontUp:
                view.increaseFontSize(nil)
            case .fontDown:
                view.decreaseFontSize(nil)
            case .fontReset:
                view.resetFontSize(nil)
            }
            if index == 0 {
                pendingAfterFirst = session.hasPendingCoalescedResize
            }
            let g = try XCTUnwrap(
                view.lastPropagatedSizeForTesting(),
                "premise: step \(index) (\(step)) must leave the view with a computed grid"
            )
            grids.append(Grid(cols: Int(g.cols), rows: Int(g.rows)))
            sizes.append(view.metrics.font.pointSize)
        }

        // Every event has been delivered; now let the backlog run.
        gate.signal()
        drainCoreQueue(session)
        let afterDrain = try XCTUnwrap(
            session.takeSnapshotForTests(),
            "the session core queue must answer after the backlog drained"
        )
        let drained = Grid(cols: afterDrain.cols, rows: afterDrain.rows)

        // And it must STAY there: nothing late may move it again.
        settleQuietly(milliseconds: 150)
        drainCoreQueue(session)
        let afterQuiet = try XCTUnwrap(
            session.takeSnapshotForTests(),
            "the session core queue must answer after the quiet period"
        )
        return Outcome(
            pendingAfterFirstStep: pendingAfterFirst,
            viewGrids: grids,
            pointSizes: sizes,
            coreAfterDrain: drained,
            coreAfterSettle: Grid(cols: afterQuiet.cols, rows: afterQuiet.rows)
        )
    }

    /// Block until every work item currently queued on `coreQueue`, and any
    /// coalesced resize that is still outstanding, has finished. Sampling the
    /// grid while a stale item is still queued would let a transient correct
    /// value hide the bug, so the tests only ever read the core after this.
    private func drainCoreQueue(_ session: TerminalSession) {
        let deadline = Date().addingTimeInterval(8)
        while true {
            session.coreQueue.sync { }
            if !session.hasPendingCoalescedResize || Date() >= deadline { break }
            RunLoop.current.run(until: Date().addingTimeInterval(0.005))
        }
        session.coreQueue.sync { }
    }

    /// Column count `propagateResize` must derive from a frame width (the
    /// formula pinned by `TerminalViewResizeMathTests`): used only to prove
    /// the premise that the newest resize really moved the grid.
    private func expectedCols(forWidth width: CGFloat, view: TerminalView) -> Int {
        let usable = width - 2 * TerminalView.horizontalContentInsetPoints
        return Int(usable / view.metrics.cellWidth)
    }

    private func pumpMainQueue(times: Int = 2) {
        for i in 0..<times {
            let exp = expectation(description: "main queue turn \(i)")
            DispatchQueue.main.async { exp.fulfill() }
            wait(for: [exp], timeout: 2.0)
        }
    }

    /// Poll (pumping the main run loop, never blocking main on the core queue)
    /// until the session's grid reaches the target or the timeout lapses; on
    /// timeout it still returns so the caller's own assertion reports the
    /// ACTUAL grid.
    private func waitForSessionGrid(
        _ session: TerminalSession,
        cols: Int,
        rows: Int,
        timeout: TimeInterval = 8.0
    ) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let snap = session.takeSnapshotForTests(), snap.cols == cols, snap.rows == rows {
                return
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
    }

    /// Let the main run loop (and any hops queued on it) run for a bounded
    /// interval.
    private func settleQuietly(milliseconds: Int) {
        RunLoop.current.run(until: Date().addingTimeInterval(Double(milliseconds) / 1000.0))
    }

    // MARK: - The bug

    /// Headline sequence. Drag wider (column change, coalesced), step the text
    /// size up with `⌘+`, then drag narrower and shorter, all before the
    /// core queue gets to run anything.
    ///
    /// The newest event is the narrower window, so the terminal must end at
    /// THAT grid. Ending at the grid the font step computed for the older,
    /// wider window leaves the shell wrapping at the wrong width and the
    /// picture clipped or padded.
    func test_fontStepBehindCoalescedResize_thenShrink_coreGridEndsAtViewGrid() throws {
        let (view, session) = try makeSettledView(width: 600, height: 400)

        let out = try runBlocked(view: view, session: session, steps: [
            .resize(width: 900, height: 400),   // 1. column change -> coalesced B1
            .fontUp,                            // 2. text size step -> A with grid D
            .resize(width: 500, height: 300),   // 3. newest window size -> grid F
        ])

        XCTAssertTrue(
            out.pendingAfterFirstStep,
            "premise: the width change must have left a coalesced resize outstanding "
            + "(hasPendingCoalescedResize) while the core queue is occupied; otherwise "
            + "the trigger window is not open and this test proves nothing"
        )
        XCTAssertEqual(out.pointSizes[1], 14, "premise: the font step took the view 13 -> 14 pt")
        let d = out.viewGrids[1]
        let f = out.viewGrids[2]
        XCTAssertNotEqual(
            [d.cols, d.rows], [f.cols, f.rows],
            "premise: the newest resize must produce a grid different from the one the "
            + "font step computed (font-step grid \(d), newest grid \(f))"
        )
        XCTAssertEqual(
            f.cols, expectedCols(forWidth: 500, view: view),
            "premise: the newest grid's columns must follow the 500 pt width"
        )

        XCTAssertEqual(
            [out.coreAfterDrain.cols, out.coreAfterDrain.rows], [f.cols, f.rows],
            "after the core queue drained, the terminal core (and so the PTY winsize, "
            + "which is applied in lockstep with it) must be at the view's CURRENT grid "
            + "\(f) -- the newest event wins. Measured core grid: \(out.coreAfterDrain). "
            + "The stale font-step grid was \(d). The view grids per step were "
            + "\(out.viewGrids.map { $0.description })."
        )
        XCTAssertEqual(
            [out.coreAfterSettle.cols, out.coreAfterSettle.rows], [f.cols, f.rows],
            "the core grid must STAY at the view's grid \(f) after things go quiet; "
            + "measured \(out.coreAfterSettle)"
        )
    }

    /// Same ordering through the `⌘0` entry point: a view that carries a
    /// per-view size override drops it, and the resulting grid re-derivation
    /// must not be applied after a newer window size.
    func test_fontResetBehindCoalescedResize_thenShrink_coreGridEndsAtViewGrid() throws {
        let (view, session) = try makeSettledView(width: 600, height: 400)

        // Give the view an override first, fully settled, so ⌘0 is a real
        // change (it is a no-op without an override).
        view.increaseFontSize(nil)
        view.increaseFontSize(nil)
        XCTAssertEqual(view.fontSizeOverride, 15, "premise: two ⌘+ steps leave a 15 pt override")
        try settle(view: view, session: session, what: "after the 15 pt override")

        let out = try runBlocked(view: view, session: session, steps: [
            .resize(width: 900, height: 400),   // 1. column change -> coalesced B1
            .fontReset,                         // 2. ⌘0 -> A with grid D (13 pt)
            .resize(width: 500, height: 300),   // 3. newest window size -> grid F
        ])

        XCTAssertTrue(
            out.pendingAfterFirstStep,
            "premise: the width change must have left a coalesced resize outstanding"
        )
        XCTAssertNil(view.fontSizeOverride, "premise: ⌘0 cleared the per-view override")
        XCTAssertEqual(out.pointSizes[1], 13, "premise: ⌘0 returned the view to the 13 pt default")
        let d = out.viewGrids[1]
        let f = out.viewGrids[2]
        XCTAssertNotEqual(
            [d.cols, d.rows], [f.cols, f.rows],
            "premise: the newest resize must differ from the ⌘0 grid (\(d) vs \(f))"
        )

        XCTAssertEqual(
            [out.coreAfterDrain.cols, out.coreAfterDrain.rows], [f.cols, f.rows],
            "after the core queue drained, the core grid must equal the view's CURRENT "
            + "grid \(f). Measured core grid: \(out.coreAfterDrain); the stale ⌘0 grid was "
            + "\(d); view grids per step: \(out.viewGrids.map { $0.description })."
        )
        XCTAssertEqual(
            [out.coreAfterSettle.cols, out.coreAfterSettle.rows], [f.cols, f.rows],
            "the core grid must stay at \(f) once quiet; measured \(out.coreAfterSettle)"
        )
    }

    /// The newest resize keeps the column count the font step produced (it is
    /// "row-only" relative to the font step's grid) but changes the row
    /// count. A coalesced resize is still outstanding, so the view must not
    /// treat it as a cheap in-line resize that the stale font-step item can
    /// then overwrite: the core must still end at the view's grid.
    func test_fontStepBehindCoalescedResize_thenRowOnlyChange_coreGridEndsAtViewGrid() throws {
        let (view, session) = try makeSettledView(width: 600, height: 400)

        let out = try runBlocked(view: view, session: session, steps: [
            .resize(width: 900, height: 400),   // 1. column change -> coalesced B1
            .fontDown,                          // 2. ⌘- -> A with grid D (12 pt)
            .resize(width: 900, height: 250),   // 3. height-only change -> grid F
        ])

        XCTAssertTrue(
            out.pendingAfterFirstStep,
            "premise: the width change must have left a coalesced resize outstanding"
        )
        XCTAssertEqual(out.pointSizes[1], 12, "premise: ⌘- took the view 13 -> 12 pt")
        let d = out.viewGrids[1]
        let f = out.viewGrids[2]
        XCTAssertEqual(
            f.cols, d.cols,
            "premise: a height-only resize must keep the column count (\(d) -> \(f))"
        )
        XCTAssertNotEqual(
            f.rows, d.rows,
            "premise: 400 -> 250 pt must change the row count (\(d) -> \(f))"
        )

        XCTAssertEqual(
            [out.coreAfterDrain.cols, out.coreAfterDrain.rows], [f.cols, f.rows],
            "after the core queue drained, the core grid must equal the view's CURRENT "
            + "grid \(f). Measured core grid: \(out.coreAfterDrain); the stale font-step "
            + "grid was \(d); view grids per step: \(out.viewGrids.map { $0.description })."
        )
        XCTAssertEqual(
            [out.coreAfterSettle.cols, out.coreAfterSettle.rows], [f.cols, f.rows],
            "the core grid must stay at \(f) once quiet; measured \(out.coreAfterSettle)"
        )
    }

    // MARK: - Controls (correct today; must stay correct)

    /// Without the newest resize there is nothing to overtake: the coalesced
    /// resize applies first and the font step's grid is the view's grid.
    /// Also proves the rig can observe a correct final state at all.
    func test_control_fontStepBehindCoalescedResize_withoutNewerResize_coreGridMatchesView() throws {
        let (view, session) = try makeSettledView(width: 600, height: 400)

        let out = try runBlocked(view: view, session: session, steps: [
            .resize(width: 900, height: 400),   // 1. column change -> coalesced B1
            .fontUp,                            // 2. text size step -> grid D (newest)
        ])

        XCTAssertTrue(
            out.pendingAfterFirstStep,
            "premise: the width change must have left a coalesced resize outstanding"
        )
        XCTAssertEqual(out.pointSizes[1], 14, "premise: the font step took the view 13 -> 14 pt")
        let d = out.finalViewGrid
        let afterWidthChange = out.viewGrids[0]
        XCTAssertNotEqual(
            [d.cols, d.rows], [afterWidthChange.cols, afterWidthChange.rows],
            "premise: the font step must move the grid away from the one the width "
            + "change computed (\(afterWidthChange) -> \(d)), otherwise the comparison "
            + "below could pass without the font step's resize ever being applied"
        )
        XCTAssertEqual(
            [out.coreAfterDrain.cols, out.coreAfterDrain.rows], [d.cols, d.rows],
            "control: with the font step as the newest event the core must end at its "
            + "grid \(d); measured \(out.coreAfterDrain)"
        )
        XCTAssertEqual(
            [out.coreAfterSettle.cols, out.coreAfterSettle.rows], [d.cols, d.rows],
            "control: and stay there; measured \(out.coreAfterSettle)"
        )
    }

    /// Without the leading column change nothing coalesced is outstanding when
    /// the font step is queued, so the newest window resize simply queues
    /// after it and wins.
    func test_control_fontStepThenResize_withoutLeadingCoalescedResize_coreGridMatchesView() throws {
        let (view, session) = try makeSettledView(width: 600, height: 400)

        let out = try runBlocked(view: view, session: session, steps: [
            .fontUp,                            // 1. text size step -> grid D
            .resize(width: 500, height: 300),   // 2. newest window size -> grid F
        ])

        XCTAssertEqual(out.pointSizes[0], 14, "premise: the font step took the view 13 -> 14 pt")
        let d = out.viewGrids[0]
        let f = out.viewGrids[1]
        XCTAssertNotEqual(
            [d.cols, d.rows], [f.cols, f.rows],
            "premise: the newest resize must differ from the font-step grid (\(d) vs \(f))"
        )
        XCTAssertEqual(
            [out.coreAfterDrain.cols, out.coreAfterDrain.rows], [f.cols, f.rows],
            "control: the newest resize queued after the font step must win; core grid "
            + "\(out.coreAfterDrain), view grid \(f), font-step grid \(d)"
        )
        XCTAssertEqual(
            [out.coreAfterSettle.cols, out.coreAfterSettle.rows], [f.cols, f.rows],
            "control: and stay there; measured \(out.coreAfterSettle)"
        )
    }
}
