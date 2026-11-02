import XCTest
import AppKit
import Metal
@testable import Blackbird
import BBCore

/// Mouse report coordinates must stay inside the grid.
///
/// **The bug this suite exists for.** A TUI that enables mouse reporting
/// (DEC 1000 / 1002 / 1003, with SGR `?1006` or the legacy X10 byte
/// encoding) is told where the pointer is as a 1-based `(col, row)` cell.
/// The terminal window is never an exact multiple of the cell size: the
/// view carries a 10 pt strip at the bottom (`bottomContentInsetPoints`), an
/// 8 pt inset on the right (`horizontalContentInsetPoints`) and, on top of
/// those, whatever sub-cell remainder the window size leaves over. A pointer
/// in one of those strips, or dragged right out of the window, is not over
/// any cell — and the cell number computed for it is simply past the grid:
/// on a 98 x 30 grid a click at view y = 5 is reported as row 31 (SGR
/// `ESC [ < 0 ; c ; 31 M`), with leftover rows as row 32. The TUI then gets a
/// coordinate that does not exist on its screen: tmux/vim/Claude Code treat
/// it as "no pane", so the bottom 10-26 pt of the window (status bars,
/// scrollbar tracks, the last line of a list) and the right 8-n pt are a dead
/// zone instead of clicking the last row / column.
///
/// **The contract pinned here** (decided from terminal and xterm convention —
/// Terminal.app, iTerm2, kitty and xterm itself all clamp the reported cell
/// to the grid — not from Blackbird's current code):
///
///  1. A press, release, wheel tick or drag/motion whose pointer is below the
///     last row reports the LAST row (`rows`), and one right of the last
///     column reports the LAST column (`cols`). Both can be true at once
///     (the bottom-right corner reports `(cols, rows)`).
///  2. That holds whether or not the window has leftover cells (the bottom
///     strip alone, 10 pt, is already enough to trigger the bug), in SGR and
///     in the legacy X10 encoding.
///  3. A drag that leaves the window altogether still produces only
///     in-range coordinates; its release lands on the clamped cell. (Whether
///     a fix chooses to emit motion reports while the pointer is outside the
///     window is a product choice, so the drag tests require only that the
///     press is first, the release is last and exact, and that NO report
///     anywhere in the stream names a cell outside `1...cols` x `1...rows`.)
///
/// Controls (they pass today and must keep passing — they prove the rig
/// delivers each gesture to the reporting path and that a correct clamp does
/// not over-clamp): clicks in the interior, in the last cell itself, in the
/// left inset (col 1), a plain in-grid drag, a drag past the top-left, and a
/// wheel tick over the last cell.
///
/// **Geometry.** The view is sized like a real window: titlebar inset + 10
/// rows of cells + the bottom inset + a 0.5 pt slack (keeps the grid maths
/// from rounding 10.0 down to 9) + an optional sub-cell remainder; width
/// likewise (2 x 8 pt inset + 40 cells). The grid the view would compute from
/// that frame is asserted to be exactly 40 x 10, and the headless session and
/// its snapshot are resized to the same 40 x 10 — so a fix may clamp against
/// the snapshot, the session, or the view-derived grid and all three agree.
/// The view is never added to a window, so its frame origin is (0, 0) and
/// `locationInWindow` equals the view-local point.
///
/// **Event synthesis.** Mouse events: `NSEvent.mouseEvent(with:...)`. Wheel
/// events: an unposted `CGEvent(scrollWheelEvent2Source:...)` with its
/// `location` set, bridged through `NSEvent(cgEvent:)` (the same technique as
/// `WheelDirectionBlindTests` / `MouseSideButtonReportingBlindTests`).
/// Nothing is posted to the window server, so this is not event injection and
/// nothing can route back to the outer terminal. Every event's type and
/// `locationInWindow` are asserted before use.
///
/// **Memory / time pre-flight** (per `feedback_test_memory_safety`):
///  - One PTY-less headless `TerminalSession` resized to 40 x 10 = 400 cells
///    per rig (a few KB); one rig per test.
///  - One headless `TerminalView` per rig, about 340 x 210 pt; never added to
///    a window, never shown, never drawn. No `NSWindow`, no
///    `MainWindowController`, no real shell, no runloop pumping, no timers.
///  - Each test sends at most a handful of events. Wall time is dominated by
///    `MTLCreateSystemDefaultDevice()`.
final class MouseReportGridClampBlindTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        TestHostTermination.shared.register()
    }

    // MARK: - Fixture constants

    private let gridCols = 40
    private let gridRows = 10

    /// Click reporting (DEC 1000) + SGR encoding.
    private let click1000SGR = "\u{1B}[?1000h\u{1B}[?1006h"
    /// Button-event tracking (DEC 1002) + SGR encoding.
    private let drag1002SGR = "\u{1B}[?1002h\u{1B}[?1006h"
    /// Click reporting with the legacy (X10 / normal) byte encoding.
    private let click1000Legacy = "\u{1B}[?1000h"

    /// Monotonic synthetic event clock; one second apart so successive clicks
    /// can never be folded into a double click.
    private var clock: TimeInterval = 1.0
    private func nextTimestamp() -> TimeInterval {
        clock += 1.0
        return clock
    }

    // MARK: - Rig

    /// Held together so nothing is deallocated mid-test. `TerminalView.session`
    /// is `weak`, so the strong `session` here is load-bearing.
    private struct Rig {
        let view: TerminalView
        let session: TerminalSession
        let recorder: RecordingPTY
        /// View-local x of the right edge of the last grid column.
        let gridRight: CGFloat
        /// Height in points of the dead area below the last grid row (bottom
        /// inset + slack + sub-row remainder): view-local y in
        /// `0 ..< bottomStrip` is "below the last row".
        let bottomStrip: CGFloat
        /// Width in points of the dead area right of the last column.
        let rightStrip: CGFloat
    }

    private func makeRig(
        decset: String,
        expectSGR: Bool,
        expectedProtocol: BBTermMode,
        rightRemainderCells: CGFloat = 0,
        bottomRemainderRows: CGFloat = 0,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> Rig {
        let device = try requireMetalDevice(file: file, line: line)
        let view = TerminalView(
            frame: NSRect(x: 0, y: 0, width: 800, height: 480),
            device: device
        )

        // Size the frame like a real 40 x 10 window.
        let cw = view.metrics.cellWidth
        let ch = view.metrics.cellHeight
        let top = view.titlebarOnlyTopInset
        let inset = TerminalView.horizontalContentInsetPoints
        let width = 2 * inset + CGFloat(gridCols) * cw + 0.5 + rightRemainderCells * cw
        let height = top + CGFloat(gridRows) * ch
            + TerminalView.bottomContentInsetPoints + 0.5 + bottomRemainderRows * ch
        view.setFrameSize(NSSize(width: width, height: height))
        let usable = TerminalView.usableViewSize(
            forBounds: view.bounds.size, titlebarTopInset: top, metrics: view.metrics
        )
        let grid = view.metrics.grid(forPixelSize: usable)
        XCTAssertEqual(
            grid.cols, gridCols,
            "precondition: the view frame must model a real \(gridCols)-column window "
            + "(measured \(grid.cols) cols; bounds \(view.bounds.size), cellWidth \(cw))",
            file: file, line: line
        )
        XCTAssertEqual(
            grid.rows, gridRows,
            "precondition: the view frame must model a real \(gridRows)-row window "
            + "(measured \(grid.rows) rows; bounds \(view.bounds.size), cellHeight \(ch))",
            file: file, line: line
        )

        let session = TerminalSession.makeHeadlessForTests()
        addTeardownBlock { session.terminate() }
        let applied = session.coreQueue.sync {
            session.bbterm.resize(to: .init(cols: UInt16(gridCols), rows: UInt16(gridRows)))
        }
        XCTAssertEqual(
            Int(applied?.cols ?? 0), gridCols,
            "precondition: headless grid resized to \(gridCols) cols",
            file: file, line: line
        )
        XCTAssertEqual(
            Int(applied?.rows ?? 0), gridRows,
            "precondition: headless grid resized to \(gridRows) rows",
            file: file, line: line
        )
        session.feedBytesForTests(Data(decset.utf8))

        // Attach the session BEFORE installing the snapshot (the setter may
        // seed its own), same order as the other headless rigs.
        view.session = session
        let snapshot = try XCTUnwrap(
            session.coreQueue.sync { session.bbterm.snapshot() },
            "snapshot() returned nil", file: file, line: line
        )
        view.currentSnapshot = snapshot

        let recorder = RecordingPTY()
        view.ptyRecorderForTests = recorder

        // Preconditions: without these a mistyped DECSET would leave mouse
        // reporting OFF and every "reports the last row" assertion would fail
        // for the wrong reason.
        XCTAssertEqual(snapshot.cols, gridCols, "precondition: snapshot cols",
                       file: file, line: line)
        XCTAssertEqual(snapshot.rows, gridRows, "precondition: snapshot rows",
                       file: file, line: line)
        XCTAssertTrue(
            snapshot.termMode.contains(expectedProtocol),
            "precondition: \(decset.debugDescription) must select the expected mouse protocol; "
            + "termMode.rawValue = \(snapshot.termMode.rawValue)",
            file: file, line: line
        )
        XCTAssertEqual(
            snapshot.termMode.contains(.sgrMouse), expectSGR,
            "precondition: SGR (?1006) encoding must be \(expectSGR ? "on" : "off"); "
            + "termMode.rawValue = \(snapshot.termMode.rawValue)",
            file: file, line: line
        )
        XCTAssertTrue(
            view.mouseReportingEnabled(),
            "precondition: the view must agree the TUI has mouse reporting on",
            file: file, line: line
        )
        XCTAssertEqual(
            snapshot.displayOffset, 0,
            "precondition: fixture must not be scrolled, so display row == buffer line",
            file: file, line: line
        )

        let rig = Rig(
            view: view, session: session, recorder: recorder,
            gridRight: inset + CGFloat(gridCols) * cw,
            bottomStrip: view.bounds.height - top - CGFloat(gridRows) * ch,
            rightStrip: view.bounds.width - (inset + CGFloat(gridCols) * cw)
        )
        XCTAssertGreaterThanOrEqual(
            rig.bottomStrip, TerminalView.bottomContentInsetPoints,
            "precondition: the bottom strip (\(rig.bottomStrip) pt) must include the bottom inset",
            file: file, line: line
        )
        XCTAssertGreaterThanOrEqual(
            rig.rightStrip, inset,
            "precondition: the right strip (\(rig.rightStrip) pt) must include the horizontal inset",
            file: file, line: line
        )
        return rig
    }

    // MARK: - Geometry helpers

    /// View-local point at the centre of grid cell (`row`, `col`), zero-based.
    private func centre(row: Int, col: Int, in view: TerminalView) -> NSPoint {
        let textAreaHeight = view.bounds.height - view.titlebarOnlyTopInset
        return NSPoint(
            x: TerminalView.horizontalContentInsetPoints
                + (CGFloat(col) + 0.5) * view.metrics.cellWidth,
            y: textAreaHeight - (CGFloat(row) + 0.5) * view.metrics.cellHeight
        )
    }

    /// View-local x at the horizontal centre of column `col` (zero-based).
    private func columnX(_ col: Int, in view: TerminalView) -> CGFloat {
        TerminalView.horizontalContentInsetPoints + (CGFloat(col) + 0.5) * view.metrics.cellWidth
    }

    /// View-local y at the vertical centre of row `row` (zero-based).
    private func rowY(_ row: Int, in view: TerminalView) -> CGFloat {
        let textAreaHeight = view.bounds.height - view.titlebarOnlyTopInset
        return textAreaHeight - (CGFloat(row) + 0.5) * view.metrics.cellHeight
    }

    private func geometry(_ rig: Rig) -> String {
        "view \(rig.view.bounds.width) x \(rig.view.bounds.height) pt, grid \(gridCols) x \(gridRows), "
        + "cell \(rig.view.metrics.cellWidth) x \(rig.view.metrics.cellHeight), "
        + "bottom strip \(rig.bottomStrip) pt, right strip \(rig.rightStrip) pt"
    }

    private func at(_ p: NSPoint) -> String {
        "(x \(p.x), y \(p.y))"
    }

    // MARK: - Event synthesis

    private func mouseEvent(
        _ type: NSEvent.EventType,
        at p: NSPoint,
        timestamp: TimeInterval,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> NSEvent {
        let ev: NSEvent = try XCTUnwrap(
            NSEvent.mouseEvent(
                with: type,
                location: p,
                modifierFlags: [],
                timestamp: timestamp,
                windowNumber: 0,
                context: nil,
                eventNumber: 0,
                clickCount: 1,
                pressure: 1.0
            ),
            "NSEvent.mouseEvent returned nil", file: file, line: line
        )
        XCTAssertEqual(
            ev.type, type,
            "precondition: event type must be what the test asked for",
            file: file, line: line
        )
        XCTAssertEqual(
            Double(ev.locationInWindow.x), Double(p.x), accuracy: 0.001,
            "precondition: locationInWindow.x must equal the requested point",
            file: file, line: line
        )
        XCTAssertEqual(
            Double(ev.locationInWindow.y), Double(p.y), accuracy: 0.001,
            "precondition: locationInWindow.y must equal the requested point",
            file: file, line: line
        )
        return ev
    }

    /// A classic (line-unit) wheel event of `notches` whose `locationInWindow`
    /// is `p`.
    ///
    /// `NSEvent(cgEvent:)` reports `locationInWindow` in Cocoa screen
    /// coordinates (y flipped against the primary screen's height) when there
    /// is no window. Rather than assume that height, probe it: build the event
    /// at CG y = 0, read the y it comes back with (that IS the flip height),
    /// then rebuild at the CG y that lands on `p.y`. The final location is
    /// asserted, so a wrong guess fails the fixture loudly.
    private func wheelEvent(
        notches: Int32,
        at p: NSPoint,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> NSEvent {
        func build(cgY: CGFloat) throws -> NSEvent {
            let cg: CGEvent = try XCTUnwrap(
                CGEvent(
                    scrollWheelEvent2Source: nil, units: .line, wheelCount: 1,
                    wheel1: notches, wheel2: 0, wheel3: 0
                ),
                "CGEvent(scrollWheelEvent2Source:) returned nil", file: file, line: line
            )
            cg.location = CGPoint(x: p.x, y: cgY)
            return try XCTUnwrap(
                NSEvent(cgEvent: cg), "NSEvent(cgEvent:) returned nil", file: file, line: line
            )
        }

        let probe = try build(cgY: 0)
        let flipHeight = probe.locationInWindow.y
        let ev = try build(cgY: flipHeight - p.y)

        XCTAssertEqual(
            ev.type, .scrollWheel,
            "precondition: bridged event must be a scroll wheel",
            file: file, line: line
        )
        XCTAssertEqual(
            ev.scrollingDeltaY, Double(notches), accuracy: 1e-9,
            "precondition: scrollingDeltaY must bridge 1:1 from wheel1 for .line units",
            file: file, line: line
        )
        XCTAssertEqual(
            Double(ev.locationInWindow.x), Double(p.x), accuracy: 0.01,
            "precondition: wheel locationInWindow.x must equal the requested point",
            file: file, line: line
        )
        XCTAssertEqual(
            Double(ev.locationInWindow.y), Double(p.y), accuracy: 0.01,
            "precondition: wheel locationInWindow.y must equal the requested point "
            + "(flip height probed as \(flipHeight))",
            file: file, line: line
        )
        return ev
    }

    // MARK: - PTY-byte oracle

    /// Everything written toward the PTY so far, with ESC rendered `<ESC>` so
    /// an assertion failure prints something a human can read.
    private func pty(_ recorder: RecordingPTY) -> String {
        String(decoding: recorder.sent, as: UTF8.self)
            .replacingOccurrences(of: "\u{1B}", with: "<ESC>")
    }

    private struct SGRReport: CustomStringConvertible {
        let code: Int
        let col: Int
        let row: Int
        let press: Bool
        var description: String {
            "<ESC>[<\(code);\(col);\(row)\(press ? "M" : "m")"
        }
    }

    /// Parse the recorded stream as a sequence of SGR mouse reports. Anything
    /// that is not a well-formed report fails the assertion on `leftover`, so
    /// a stray byte cannot hide.
    private func sgrReports(
        _ recorder: RecordingPTY,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> [SGRReport] {
        let text = String(decoding: recorder.sent, as: UTF8.self)
        let ns: NSString = text as NSString
        let whole = NSRange(location: 0, length: ns.length)
        guard let regex = try? NSRegularExpression(pattern: "\u{1B}\\[<(\\d+);(\\d+);(\\d+)([Mm])") else {
            XCTFail("SGR report regex failed to compile", file: file, line: line)
            return []
        }
        let reports: [SGRReport] = regex.matches(in: text, range: whole).map {
            (m: NSTextCheckingResult) -> SGRReport in
            SGRReport(
                code: Int(ns.substring(with: m.range(at: 1))) ?? -1,
                col: Int(ns.substring(with: m.range(at: 2))) ?? -1,
                row: Int(ns.substring(with: m.range(at: 3))) ?? -1,
                press: ns.substring(with: m.range(at: 4)) == "M"
            )
        }
        let rest: String = regex.stringByReplacingMatches(in: text, range: whole, withTemplate: "")
        XCTAssertEqual(
            rest, "",
            "the PTY stream must consist only of well-formed SGR reports; "
            + "full stream: \(pty(recorder))",
            file: file, line: line
        )
        return reports
    }

    private func descriptions(_ reports: [SGRReport]) -> [String] {
        reports.map { (r: SGRReport) -> String in r.description }
    }

    /// One legacy (X10 / normal) report: `ESC [ M (32+Cb) (32+col) (32+row)`
    /// decoded back to `Cb`, 1-based `col` and 1-based `row`.
    private struct LegacyReport: CustomStringConvertible {
        let cb: Int
        let col: Int
        let row: Int
        var description: String { "legacy(cb: \(cb), col: \(col), row: \(row))" }
    }

    private func legacyReports(
        _ recorder: RecordingPTY,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> [LegacyReport] {
        let bytes: [UInt8] = Array(recorder.sent)
        var out: [LegacyReport] = []
        var i = 0
        while i + 6 <= bytes.count, bytes[i] == 0x1B, bytes[i + 1] == 0x5B, bytes[i + 2] == 0x4D {
            out.append(LegacyReport(
                cb: Int(bytes[i + 3]) - 32,
                col: Int(bytes[i + 4]) - 32,
                row: Int(bytes[i + 5]) - 32
            ))
            i += 6
        }
        XCTAssertEqual(
            i, bytes.count,
            "the PTY stream must consist only of 6-byte ESC [ M reports; "
            + "unparsed tail starts at byte \(i); full stream: \(pty(recorder))",
            file: file, line: line
        )
        return out
    }

    // MARK: - Gesture + assertion helpers

    /// Press + release at `p` under SGR; the stream must be exactly
    /// press(0)/release(0) naming the 1-based cell (`col`, `row`).
    private func assertSGRClick(
        _ rig: Rig,
        at p: NSPoint,
        expectCol: Int,
        expectRow: Int,
        label: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        rig.recorder.sent = Data()
        let t = nextTimestamp()
        rig.view.mouseDown(with: try mouseEvent(.leftMouseDown, at: p, timestamp: t, file: file, line: line))
        rig.view.mouseUp(with: try mouseEvent(.leftMouseUp, at: p, timestamp: t + 0.01, file: file, line: line))

        let got = descriptions(sgrReports(rig.recorder, file: file, line: line))
        let want = descriptions([
            SGRReport(code: 0, col: expectCol, row: expectRow, press: true),
            SGRReport(code: 0, col: expectCol, row: expectRow, press: false),
        ])
        XCTAssertEqual(
            got, want,
            "\(label): a left click at \(at(p)) must report cell (col \(expectCol), row \(expectRow)) "
            + "of the \(gridCols) x \(gridRows) grid. TUI received: \(pty(rig.recorder)) [\(geometry(rig))]",
            file: file, line: line
        )
    }

    /// Press + release at `p` under the legacy encoding.
    private func assertLegacyClick(
        _ rig: Rig,
        at p: NSPoint,
        expectCol: Int,
        expectRow: Int,
        label: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        rig.recorder.sent = Data()
        let t = nextTimestamp()
        rig.view.mouseDown(with: try mouseEvent(.leftMouseDown, at: p, timestamp: t, file: file, line: line))
        rig.view.mouseUp(with: try mouseEvent(.leftMouseUp, at: p, timestamp: t + 0.01, file: file, line: line))

        let got: [String] = legacyReports(rig.recorder, file: file, line: line)
            .map { (r: LegacyReport) -> String in r.description }
        let want: [String] = [
            LegacyReport(cb: 0, col: expectCol, row: expectRow),
            LegacyReport(cb: 3, col: expectCol, row: expectRow),
        ].map { (r: LegacyReport) -> String in r.description }
        XCTAssertEqual(
            got, want,
            "\(label): a legacy-encoded left click at \(at(p)) must report press then release of "
            + "cell (col \(expectCol), row \(expectRow)). TUI received: \(pty(rig.recorder)) "
            + "[\(geometry(rig))]",
            file: file, line: line
        )
    }

    /// One wheel tick at `p` under SGR: at least one report, and every report
    /// is wheel-toward-older (64) naming the 1-based cell (`col`, `row`).
    private func assertSGRWheel(
        _ rig: Rig,
        at p: NSPoint,
        expectCol: Int,
        expectRow: Int,
        label: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        rig.recorder.sent = Data()
        rig.view.scrollWheel(with: try wheelEvent(notches: 1, at: p, file: file, line: line))

        let reports = sgrReports(rig.recorder, file: file, line: line)
        XCTAssertGreaterThan(
            reports.count, 0,
            "\(label): precondition: one wheel notch under ?1000h/?1006h must be reported at all "
            + "(stream: \(pty(rig.recorder)))",
            file: file, line: line
        )
        let want = descriptions(Array(
            repeating: SGRReport(code: 64, col: expectCol, row: expectRow, press: true),
            count: reports.count
        ))
        XCTAssertEqual(
            descriptions(reports), want,
            "\(label): a wheel tick at \(at(p)) must report wheel-up (64) at cell "
            + "(col \(expectCol), row \(expectRow)). TUI received: \(pty(rig.recorder)) [\(geometry(rig))]",
            file: file, line: line
        )
    }

    /// Every report in `reports` must name a cell inside `1...cols` x `1...rows`.
    private func assertAllInsideGrid(
        _ reports: [SGRReport],
        rig: Rig,
        label: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let outside: [SGRReport] = reports.filter { (r: SGRReport) -> Bool in
            r.col < 1 || r.col > gridCols || r.row < 1 || r.row > gridRows
        }
        XCTAssertEqual(
            descriptions(outside), [],
            "\(label): no report may name a cell outside the \(gridCols) x \(gridRows) grid "
            + "(1-based col 1...\(gridCols), row 1...\(gridRows)). Full stream the TUI received: "
            + "\(pty(rig.recorder)) [\(geometry(rig))]",
            file: file, line: line
        )
    }

    /// A left-button drag under `?1002h`/`?1006h`: press at cell
    /// (`downRow`, `downCol`), one drag event to `to`, release at `to`.
    /// Requires press first, release last and exact at (`expectCol`,
    /// `expectRow`), and every report inside the grid.
    private func assertSGRDrag(
        _ rig: Rig,
        downRow: Int,
        downCol: Int,
        to: NSPoint,
        expectCol: Int,
        expectRow: Int,
        label: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        rig.recorder.sent = Data()
        let down = centre(row: downRow, col: downCol, in: rig.view)
        let t = nextTimestamp()
        rig.view.mouseDown(with: try mouseEvent(.leftMouseDown, at: down, timestamp: t, file: file, line: line))
        rig.view.mouseDragged(with: try mouseEvent(.leftMouseDragged, at: to, timestamp: t + 0.01, file: file, line: line))
        rig.view.mouseUp(with: try mouseEvent(.leftMouseUp, at: to, timestamp: t + 0.02, file: file, line: line))

        let reports = sgrReports(rig.recorder, file: file, line: line)
        guard reports.count >= 2 else {
            XCTFail(
                "\(label): expected at least a press and a release report; "
                + "stream: \(pty(rig.recorder)) [\(geometry(rig))]",
                file: file, line: line
            )
            return
        }
        XCTAssertEqual(
            reports.first?.description,
            SGRReport(code: 0, col: downCol + 1, row: downRow + 1, press: true).description,
            "\(label): the first report must be the press at the down cell; "
            + "stream: \(pty(rig.recorder))",
            file: file, line: line
        )
        XCTAssertEqual(
            reports.last?.description,
            SGRReport(code: 0, col: expectCol, row: expectRow, press: false).description,
            "\(label): releasing at \(at(to)) must report the clamped cell "
            + "(col \(expectCol), row \(expectRow)). Stream: \(pty(rig.recorder)) [\(geometry(rig))]",
            file: file, line: line
        )
        assertAllInsideGrid(reports, rig: rig, label: label, file: file, line: line)
    }

    // MARK: - Controls (pass today; prove the rig and that a clamp must not over-clamp)

    /// Geometry control for the whole file: `centre(row: 3, col: 5)` must be
    /// reported as the 1-based cell (6, 4).
    func test_control_sgrClickInInteriorCell_reportsThatCell() throws {
        let rig = try makeRig(decset: click1000SGR, expectSGR: true, expectedProtocol: .mouseReportClick)
        try assertSGRClick(
            rig, at: centre(row: 3, col: 5, in: rig.view),
            expectCol: 6, expectRow: 4, label: "interior cell (row 3, col 5)"
        )
    }

    /// The last cell itself is a real cell: a correct clamp must still report
    /// it as (cols, rows), not one short.
    func test_control_sgrClickInLastCell_reportsLastCell() throws {
        let rig = try makeRig(decset: click1000SGR, expectSGR: true, expectedProtocol: .mouseReportClick)
        try assertSGRClick(
            rig, at: centre(row: gridRows - 1, col: gridCols - 1, in: rig.view),
            expectCol: gridCols, expectRow: gridRows, label: "centre of the last cell"
        )
    }

    /// The left inset already clamps to column 1 today; it must keep doing so.
    func test_control_sgrClickInLeftPadding_reportsFirstColumn() throws {
        let rig = try makeRig(decset: click1000SGR, expectSGR: true, expectedProtocol: .mouseReportClick)
        let y = rowY(3, in: rig.view)
        try assertSGRClick(
            rig, at: NSPoint(x: 2, y: y),
            expectCol: 1, expectRow: 4, label: "left padding, 2 pt from the edge"
        )
        try assertSGRClick(
            rig, at: NSPoint(x: 0.25, y: y),
            expectCol: 1, expectRow: 4, label: "left padding, at the very edge"
        )
    }

    /// A drag that stays inside the grid is press, motion, release on the
    /// claimed cells: proves the rig delivers `mouseDragged` to the reporting
    /// path (so the past-the-edge drag tests below are not vacuous).
    func test_control_sgrDragWithinGrid_reportsPressMotionRelease() throws {
        let rig = try makeRig(decset: drag1002SGR, expectSGR: true, expectedProtocol: .mouseDrag)
        let down = centre(row: 2, col: 2, in: rig.view)
        let moved = centre(row: 6, col: 7, in: rig.view)

        let t = nextTimestamp()
        rig.view.mouseDown(with: try mouseEvent(.leftMouseDown, at: down, timestamp: t))
        rig.view.mouseDragged(with: try mouseEvent(.leftMouseDragged, at: moved, timestamp: t + 0.01))
        rig.view.mouseUp(with: try mouseEvent(.leftMouseUp, at: moved, timestamp: t + 0.02))

        XCTAssertEqual(
            descriptions(sgrReports(rig.recorder)),
            descriptions([
                SGRReport(code: 0, col: 3, row: 3, press: true),
                SGRReport(code: 32, col: 8, row: 7, press: true),
                SGRReport(code: 0, col: 8, row: 7, press: false),
            ]),
            "an in-grid left drag under ?1002h/?1006h must be press(0), motion(32), release(0) "
            + "on the claimed cells. TUI received: \(pty(rig.recorder)) [\(geometry(rig))]"
        )
    }

    /// Past the TOP-LEFT of the window the cell is already clamped to (1, 1)
    /// today (negative cell indices are floored at 0); a correct fix must keep
    /// that.
    func test_control_sgrDragPastTopLeft_staysInsideGrid() throws {
        let rig = try makeRig(decset: drag1002SGR, expectSGR: true, expectedProtocol: .mouseDrag)
        try assertSGRDrag(
            rig, downRow: 2, downCol: 2,
            to: NSPoint(x: -60, y: rig.view.bounds.height + 60),
            expectCol: 1, expectRow: 1, label: "drag past the top-left corner of the window"
        )
    }

    /// A wheel tick over the last cell is reported at the last cell: proves
    /// the wheel path takes its cell from the event location in this rig, so
    /// the padding wheel tests below are about the clamp and nothing else.
    func test_control_sgrWheelOverLastCell_reportsLastCell() throws {
        let rig = try makeRig(decset: click1000SGR, expectSGR: true, expectedProtocol: .mouseReportClick)
        try assertSGRWheel(
            rig, at: centre(row: gridRows - 1, col: gridCols - 1, in: rig.view),
            expectCol: gridCols, expectRow: gridRows, label: "wheel over the last cell"
        )
    }

    // MARK: - Click in the bottom padding (SGR)

    /// The headline case: pointer in the bottom strip (10 pt inset + a sub-row
    /// remainder of 0.9 rows, so the unclamped row is `rows + 1` or `rows + 2`)
    /// must hit the LAST row.
    func test_sgrClick_inBottomPadding_reportsLastRow() throws {
        let rig = try makeRig(
            decset: click1000SGR, expectSGR: true, expectedProtocol: .mouseReportClick,
            bottomRemainderRows: 0.9
        )
        let x = columnX(5, in: rig.view)   // 1-based col 6
        let probes: [(String, CGFloat)] = [
            ("0.25 pt above the bottom edge of the window", 0.25),
            ("middle of the bottom strip", rig.bottomStrip / 2),
            ("1 pt below the last grid row", rig.bottomStrip - 1),
        ]
        for (label, y) in probes {
            try assertSGRClick(
                rig, at: NSPoint(x: x, y: y),
                expectCol: 6, expectRow: gridRows, label: "bottom padding, \(label)"
            )
        }
    }

    /// Same, with NO leftover rows: the 10 pt bottom inset alone puts the
    /// pointer past the last row (a click at view y = 5 used to report
    /// `rows + 1`).
    func test_sgrClick_inBottomPadding_noLeftoverRows_reportsLastRow() throws {
        let rig = try makeRig(
            decset: click1000SGR, expectSGR: true, expectedProtocol: .mouseReportClick,
            bottomRemainderRows: 0
        )
        let x = columnX(5, in: rig.view)
        try assertSGRClick(
            rig, at: NSPoint(x: x, y: 5),
            expectCol: 6, expectRow: gridRows, label: "bottom inset only, click at view y = 5"
        )
        try assertSGRClick(
            rig, at: NSPoint(x: x, y: 0.25),
            expectCol: 6, expectRow: gridRows, label: "bottom inset only, click 0.25 pt above the edge"
        )
    }

    // MARK: - Click in the right padding (SGR)

    /// Pointer in the right strip (8 pt inset + 0.9 cells of remainder, so the
    /// unclamped column is `cols + 1`) must hit the LAST column.
    func test_sgrClick_inRightPadding_reportsLastColumn() throws {
        let rig = try makeRig(
            decset: click1000SGR, expectSGR: true, expectedProtocol: .mouseReportClick,
            rightRemainderCells: 0.9
        )
        let y = rowY(3, in: rig.view)      // 1-based row 4
        let probes: [(String, CGFloat)] = [
            ("1 pt right of the last column", rig.gridRight + 1),
            ("middle of the right strip", rig.gridRight + rig.rightStrip / 2),
            ("0.25 pt inside the right edge of the window", rig.view.bounds.width - 0.25),
        ]
        for (label, x) in probes {
            try assertSGRClick(
                rig, at: NSPoint(x: x, y: y),
                expectCol: gridCols, expectRow: 4, label: "right padding, \(label)"
            )
        }
    }

    /// Same, with NO leftover columns: the 8 pt right inset alone is past the
    /// last column.
    func test_sgrClick_inRightPadding_noLeftoverColumns_reportsLastColumn() throws {
        let rig = try makeRig(
            decset: click1000SGR, expectSGR: true, expectedProtocol: .mouseReportClick,
            rightRemainderCells: 0
        )
        let y = rowY(3, in: rig.view)
        try assertSGRClick(
            rig, at: NSPoint(x: rig.view.bounds.width - 3, y: y),
            expectCol: gridCols, expectRow: 4, label: "right inset only, click 3 pt from the edge"
        )
        try assertSGRClick(
            rig, at: NSPoint(x: rig.gridRight + 1, y: y),
            expectCol: gridCols, expectRow: 4, label: "right inset only, click 1 pt right of the last column"
        )
    }

    // MARK: - Click in the corner (SGR)

    /// Bottom-right corner: both axes are past the grid, both must clamp.
    func test_sgrClick_inBottomRightCorner_reportsLastCell() throws {
        let rig = try makeRig(
            decset: click1000SGR, expectSGR: true, expectedProtocol: .mouseReportClick,
            rightRemainderCells: 0.6, bottomRemainderRows: 0.6
        )
        try assertSGRClick(
            rig, at: NSPoint(x: rig.view.bounds.width - 0.25, y: 0.25),
            expectCol: gridCols, expectRow: gridRows, label: "extreme bottom-right corner of the view"
        )
        try assertSGRClick(
            rig, at: NSPoint(x: rig.gridRight + 1, y: rig.bottomStrip - 1),
            expectCol: gridCols, expectRow: gridRows, label: "corner just past the last cell"
        )
    }

    // MARK: - Click in the padding (legacy X10 / normal encoding)

    func test_legacyClick_inBottomPadding_reportsLastRow() throws {
        let rig = try makeRig(
            decset: click1000Legacy, expectSGR: false, expectedProtocol: .mouseReportClick,
            bottomRemainderRows: 0.5
        )
        let x = columnX(5, in: rig.view)
        try assertLegacyClick(
            rig, at: NSPoint(x: x, y: 5),
            expectCol: 6, expectRow: gridRows, label: "legacy encoding, bottom padding at view y = 5"
        )
        try assertLegacyClick(
            rig, at: NSPoint(x: x, y: 0.25),
            expectCol: 6, expectRow: gridRows, label: "legacy encoding, bottom edge of the window"
        )
    }

    func test_legacyClick_inRightPadding_reportsLastColumn() throws {
        let rig = try makeRig(
            decset: click1000Legacy, expectSGR: false, expectedProtocol: .mouseReportClick,
            rightRemainderCells: 0.5
        )
        let y = rowY(3, in: rig.view)
        try assertLegacyClick(
            rig, at: NSPoint(x: rig.view.bounds.width - 3, y: y),
            expectCol: gridCols, expectRow: 4, label: "legacy encoding, right padding 3 pt from the edge"
        )
        try assertLegacyClick(
            rig, at: NSPoint(x: rig.gridRight + 1, y: y),
            expectCol: gridCols, expectRow: 4, label: "legacy encoding, 1 pt right of the last column"
        )
    }

    // MARK: - Wheel in the padding

    func test_sgrWheel_inBottomPadding_reportsLastRow() throws {
        let rig = try makeRig(
            decset: click1000SGR, expectSGR: true, expectedProtocol: .mouseReportClick,
            bottomRemainderRows: 0.5
        )
        try assertSGRWheel(
            rig, at: NSPoint(x: columnX(5, in: rig.view), y: 5),
            expectCol: 6, expectRow: gridRows, label: "wheel in the bottom padding at view y = 5"
        )
    }

    func test_sgrWheel_inRightPadding_reportsLastColumn() throws {
        let rig = try makeRig(
            decset: click1000SGR, expectSGR: true, expectedProtocol: .mouseReportClick,
            rightRemainderCells: 0.5
        )
        try assertSGRWheel(
            rig, at: NSPoint(x: rig.view.bounds.width - 3, y: rowY(3, in: rig.view)),
            expectCol: gridCols, expectRow: 4, label: "wheel in the right padding 3 pt from the edge"
        )
    }

    // MARK: - Drags past the grid / window edge

    /// Dragging into the bottom-right padding without leaving the window.
    func test_sgrDrag_intoBottomRightPadding_reportsLastCell() throws {
        let rig = try makeRig(
            decset: drag1002SGR, expectSGR: true, expectedProtocol: .mouseDrag,
            rightRemainderCells: 0.5, bottomRemainderRows: 0.5
        )
        try assertSGRDrag(
            rig, downRow: 2, downCol: 2,
            to: NSPoint(x: rig.view.bounds.width - 1, y: 1),
            expectCol: gridCols, expectRow: gridRows,
            label: "drag into the bottom-right padding of the window"
        )
    }

    /// Dragging out of the window past the bottom edge.
    func test_sgrDrag_pastBottomEdge_reportsLastRow() throws {
        let rig = try makeRig(decset: drag1002SGR, expectSGR: true, expectedProtocol: .mouseDrag)
        try assertSGRDrag(
            rig, downRow: 2, downCol: 2,
            to: NSPoint(x: columnX(6, in: rig.view), y: -80),
            expectCol: 7, expectRow: gridRows,
            label: "drag 80 pt below the bottom edge of the window"
        )
    }

    /// Dragging out of the window past the right edge.
    func test_sgrDrag_pastRightEdge_reportsLastColumn() throws {
        let rig = try makeRig(decset: drag1002SGR, expectSGR: true, expectedProtocol: .mouseDrag)
        try assertSGRDrag(
            rig, downRow: 2, downCol: 2,
            to: NSPoint(x: rig.view.bounds.width + 80, y: rowY(5, in: rig.view)),
            expectCol: gridCols, expectRow: 6,
            label: "drag 80 pt right of the right edge of the window"
        )
    }

    /// Dragging out of the window past the bottom-right corner.
    func test_sgrDrag_pastBottomRightCorner_reportsLastCell() throws {
        let rig = try makeRig(decset: drag1002SGR, expectSGR: true, expectedProtocol: .mouseDrag)
        try assertSGRDrag(
            rig, downRow: 2, downCol: 2,
            to: NSPoint(x: rig.view.bounds.width + 80, y: -80),
            expectCol: gridCols, expectRow: gridRows,
            label: "drag 80 pt past the bottom-right corner of the window"
        )
    }
}
