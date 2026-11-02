import XCTest
import AppKit
import Metal
@testable import Blackbird
import BBCore

/// Right-button drags under terminal mouse reporting (DEC 1002 / 1003).
///
/// **The bug this suite exists for.** A TUI that enables button-event
/// tracking (`?1002h`) or any-event tracking (`?1003h`) is promised, by the
/// xterm mouse protocol, a *motion* report every time the pointer enters a
/// new cell while a button is held. The motion code is
///
///     Cb = 32 + button (+ 4·Shift + 8·Meta + 16·Ctrl)
///
/// so a right-button drag is `press(2)`, `motion(34)` per new cell,
/// `release(2)`; with Ctrl held (the macOS spelling of "right button" for a
/// Ctrl+left-click, delivered as `rightMouse*` events) it is `18 / 50 / 18`.
/// That is how nvim's `mousemodel=extend` implements `<RightDrag>` /
/// `<C-RightDrag>`, how TUIs extend a range selection with the right button,
/// and how any-event (`?1003`) hover highlighting is kept in step while a
/// button is down.
///
/// Left drags (`32`) and middle drags (`33`) already report motion. The right
/// button was observed to deliver the press and the release but nothing in
/// between: the TUI sees a right click at the start cell and a right release
/// at the end cell, with no `ESC[<34;c;rM` reports in the middle. (The sibling
/// suite `MouseModifierBitsReportBlindTests` deliberately tolerates the
/// missing right-button motion because it is about modifier bits; THIS suite
/// is where right-button motion is required.)
///
/// **The contract pinned here** (decided from the xterm protocol, not from
/// Blackbird's current code):
///
///  1. `?1002h` + `?1006h`, plain right drag crossing three new cells:
///     `2 / 34 / 34 / 34 / 2` (press, one motion per new cell, release at the
///     drop cell).
///  2. Same under `?1003h` + `?1006h` (any-event tracking also reports
///     button-held motion, using the held button's code, not the 35
///     "no button" hover code).
///  3. Ctrl+right drag: `18 / 50 / 50 / 50 / 18`.
///  4. Pointer jitter inside one cell does not produce extra motion reports
///     (motion is per cell, exactly like the left button).
///  5. `?1000h` (click reporting only) never reports motion: a right drag is
///     just press + release. (Control: protects against a fix that
///     over-reports.)
///  6. Legacy X10/normal encoding (no `?1006`) carries the same: the motion
///     byte is `32 + (32 + 2)` = `B`.
///
/// Left-button controls (which pass today) prove the rig delivers drag events
/// to the reporting path, that each probed cell maps to the cell the test
/// claims, and that per-cell de-duplication behaves as contract 4 describes,
/// so the right-button failures can only be about right-button motion.
///
/// **Event synthesis.** `NSEvent.mouseEvent(with:…)` with the right event type
/// and modifier flags. Nothing is posted to the window server; this is not
/// event injection and nothing can route back to the outer terminal. Each
/// event's `type` and Control state are asserted before use.
///
/// **Geometry.** The view is never added to a window, so its frame origin is
/// (0, 0) and `locationInWindow` equals the view-local point. The press and
/// release reports name the cells the test claims to have touched.
///
/// **Memory / time pre-flight** (per `feedback_test_memory_safety`):
///  - One 60 × 8 `BBTerm` per rig — 480 cells, a few KB — `scrollback: 16`.
///  - One 800 × 480 headless `TerminalView` per rig; never added to a window,
///    never shown, never drawn. No `NSWindow`, no `MainWindowController`, no
///    PTY, no shell. `TerminalSession.makeHeadlessForTests()` has no pty, so
///    only the `RecordingPTY` observes writes.
///  - No runloop pumping, no timers. Wall time is dominated by
///    `MTLCreateSystemDefaultDevice()`.
final class MouseRightDragReportBlindTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        TestHostTermination.shared.register()
    }

    // MARK: - Fixture constants

    private let gridCols: UInt16 = 60
    private let gridRows: UInt16 = 8

    /// A zero-based grid cell.
    private struct Cell: Equatable {
        let row: Int
        let col: Int
    }

    /// Press cell. Interior row/column so a drag can move in every direction.
    private let downCell = Cell(row: 2, col: 2)

    /// Three successive, all-distinct, all-new cells: a horizontal step, a
    /// vertical step, and a long horizontal step.
    private let pathCells: [Cell] = [
        Cell(row: 2, col: 4),
        Cell(row: 3, col: 4),
        Cell(row: 3, col: 9),
    ]

    // MARK: - Mouse-mode preambles

    /// Click reporting (DEC 1000) + SGR encoding.
    private let click1000SGR = "\u{1B}[?1000h\u{1B}[?1006h"
    /// Button-event tracking (DEC 1002) + SGR encoding.
    private let drag1002SGR = "\u{1B}[?1002h\u{1B}[?1006h"
    /// Any-event tracking (DEC 1003) + SGR encoding.
    private let any1003SGR = "\u{1B}[?1003h\u{1B}[?1006h"
    /// Button-event tracking with the legacy (X10 / normal) encoding.
    private let drag1002Legacy = "\u{1B}[?1002h"

    // MARK: - Rig

    /// Held together so nothing is deallocated mid-test. `TerminalView.session`
    /// is `weak`, so the strong `session` here is load-bearing.
    private struct Rig {
        let view: TerminalView
        let term: BBTerm
        let session: TerminalSession
        let recorder: RecordingPTY
    }

    private func makeRig(
        decset: String,
        expectSGR: Bool,
        expectedProtocol: BBTermMode,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> Rig {
        let device = try requireMetalDevice(file: file, line: line)
        let view = TerminalView(
            frame: NSRect(x: 0, y: 0, width: 800, height: 480),
            device: device
        )
        let term = try XCTUnwrap(
            BBTerm(size: .init(cols: gridCols, rows: gridRows), scrollback: 16),
            "BBTerm init failed", file: file, line: line
        )
        term.input(decset)
        let snapshot = try XCTUnwrap(
            term.snapshot(), "snapshot() returned nil", file: file, line: line
        )

        let session = TerminalSession.makeHeadlessForTests()
        view.session = session
        view.currentSnapshot = snapshot

        let recorder = RecordingPTY()
        view.ptyRecorderForTests = recorder

        // Preconditions: without these a mistyped DECSET would leave mouse
        // reporting OFF (or on the wrong protocol) and the stream assertions
        // would be about the wrong thing.
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
        XCTAssertEqual(
            recorder.sent.count, 0,
            "precondition: the recorder must start empty",
            file: file, line: line
        )
        return Rig(view: view, term: term, session: session, recorder: recorder)
    }

    // MARK: - Geometry + event synthesis

    /// View-local (== window-local, the view has no window) point at the
    /// centre of grid cell `cell`, nudged horizontally by `dxCells` cell
    /// widths (use a fraction below 0.5 to stay inside the same cell).
    private func point(
        _ cell: Cell, dxCells: CGFloat = 0, in view: TerminalView
    ) -> NSPoint {
        let textAreaHeight: CGFloat = view.bounds.height - view.titlebarOnlyTopInset
        return NSPoint(
            x: TerminalView.horizontalContentInsetPoints
                + (CGFloat(cell.col) + 0.5 + dxCells) * view.metrics.cellWidth,
            y: textAreaHeight - (CGFloat(cell.row) + 0.5) * view.metrics.cellHeight
        )
    }

    private enum Button {
        case left
        case right

        var downType: NSEvent.EventType { self == .left ? .leftMouseDown : .rightMouseDown }
        var draggedType: NSEvent.EventType { self == .left ? .leftMouseDragged : .rightMouseDragged }
        var upType: NSEvent.EventType { self == .left ? .leftMouseUp : .rightMouseUp }

        /// The xterm base button code (before the +32 motion bit and the
        /// modifier bits).
        var xtermCode: Int { self == .left ? 0 : 2 }

        var label: String { self == .left ? "left" : "right" }
    }

    private func mouseEvent(
        _ type: NSEvent.EventType,
        at p: NSPoint,
        modifiers: NSEvent.ModifierFlags,
        timestamp: TimeInterval,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> NSEvent {
        let ev: NSEvent = try XCTUnwrap(
            NSEvent.mouseEvent(
                with: type,
                location: p,
                modifierFlags: modifiers,
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
        let held: NSEvent.ModifierFlags = ev.modifierFlags.intersection(.deviceIndependentFlagsMask)
        XCTAssertEqual(
            held.contains(.control), modifiers.contains(.control),
            "precondition: Control state must survive event construction (flags \(held.rawValue))",
            file: file, line: line
        )
        XCTAssertFalse(
            held.contains(.option) || held.contains(.command) || held.contains(.shift),
            "precondition: no Option (reporting bypass), Command (link / window-drag modifier) "
            + "or Shift may be held (flags \(held.rawValue))",
            file: file, line: line
        )
        return ev
    }

    /// Press at `downCell`, drag through `points` in order, release at the
    /// last point (or at the press point when `points` is empty).
    private func performDrag(
        _ button: Button,
        on rig: Rig,
        modifiers: NSEvent.ModifierFlags = [],
        points: [NSPoint],
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        var t: TimeInterval = 1.0
        let down: NSPoint = point(downCell, in: rig.view)

        let downEvent: NSEvent = try mouseEvent(button.downType, at: down, modifiers: modifiers, timestamp: t, file: file, line: line)
        switch button {
        case .left: rig.view.mouseDown(with: downEvent)
        case .right: rig.view.rightMouseDown(with: downEvent)
        }

        for p in points {
            t += 0.01
            let dragEvent: NSEvent = try mouseEvent(button.draggedType, at: p, modifiers: modifiers, timestamp: t, file: file, line: line)
            switch button {
            case .left: rig.view.mouseDragged(with: dragEvent)
            case .right: rig.view.rightMouseDragged(with: dragEvent)
            }
        }

        t += 0.01
        let upEvent: NSEvent = try mouseEvent(button.upType, at: points.last ?? down, modifiers: modifiers, timestamp: t, file: file, line: line)
        switch button {
        case .left: rig.view.mouseUp(with: upEvent)
        case .right: rig.view.rightMouseUp(with: upEvent)
        }
    }

    /// Centre points of `pathCells`.
    private func pathPoints(in view: TerminalView) -> [NSPoint] {
        pathCells.map { (c: Cell) -> NSPoint in point(c, in: view) }
    }

    // MARK: - PTY-byte oracle

    /// Everything written toward the PTY so far, with ESC rendered `<ESC>` so
    /// an assertion failure prints something a human can read.
    private func pty(_ recorder: RecordingPTY) -> String {
        String(decoding: recorder.sent, as: UTF8.self)
            .replacingOccurrences(of: "\u{1B}", with: "<ESC>")
    }

    /// The SGR (`?1006`) mouse report for `code` at a zero-based `cell`.
    private func sgrReport(code: Int, cell: Cell, press: Bool) -> String {
        "<ESC>[<\(code);\(cell.col + 1);\(cell.row + 1)\(press ? "M" : "m")"
    }

    /// The legacy (X10 / normal) mouse report: `ESC [ M` then three bytes
    /// `32 + Cb`, `32 + col + 1`, `32 + row + 1`. Every value used here stays
    /// well inside printable ASCII.
    private func legacyReport(cb: Int, cell: Cell) -> String {
        func ch(_ v: Int) -> String { String(UnicodeScalar(UInt8(32 + v))) }
        return "<ESC>[M" + ch(cb) + ch(cell.col + 1) + ch(cell.row + 1)
    }

    /// The SGR stream a TUI must receive for a drag with `base` button code
    /// (modifier bits included) that presses at `downCell`, then enters each
    /// of `cells` in turn, then releases at the last of them.
    private func expectedSGRStream(base: Int, cells: [Cell], reportMotion: Bool) -> String {
        var s: String = sgrReport(code: base, cell: downCell, press: true)
        if reportMotion {
            for c in cells {
                s += sgrReport(code: base + 32, cell: c, press: true)
            }
        }
        s += sgrReport(code: base, cell: cells.last ?? downCell, press: false)
        return s
    }

    /// Parse the recorded stream as SGR mouse reports; leftover bytes are
    /// asserted empty so a stray byte cannot hide from the assertions.
    private func sgrCodes(
        _ recorder: RecordingPTY,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> [Int] {
        let text: String = String(decoding: recorder.sent, as: UTF8.self)
        let ns: NSString = text as NSString
        let whole = NSRange(location: 0, length: ns.length)
        guard let regex = try? NSRegularExpression(pattern: "\u{1B}\\[<(\\d+);(\\d+);(\\d+)([Mm])") else {
            XCTFail("SGR report regex failed to compile", file: file, line: line)
            return []
        }
        let codes: [Int] = regex.matches(in: text, range: whole).map { (m: NSTextCheckingResult) -> Int in
            Int(ns.substring(with: m.range(at: 1))) ?? -1
        }
        let rest: String = regex.stringByReplacingMatches(in: text, range: whole, withTemplate: "")
        XCTAssertEqual(
            rest, "",
            "the PTY stream must consist only of well-formed SGR reports; "
            + "full stream: \(pty(recorder))",
            file: file, line: line
        )
        return codes
    }

    /// Assert both the button-code sequence (readable failure) and the exact
    /// byte stream (cells, press/release finals) for an SGR drag.
    private func assertSGRDrag(
        _ rig: Rig,
        base: Int,
        reportMotion: Bool,
        gesture: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        var expectedCodes: [Int] = [base]
        if reportMotion {
            expectedCodes += pathCells.map { (_: Cell) -> Int in base + 32 }
        }
        expectedCodes.append(base)
        XCTAssertEqual(
            sgrCodes(rig.recorder, file: file, line: line), expectedCodes,
            "\(gesture): expected button codes press(\(base))"
            + (reportMotion ? ", one motion(\(base + 32)) per new cell (\(pathCells.count))" : ", no motion")
            + ", release(\(base)); full stream the TUI received: \(pty(rig.recorder))",
            file: file, line: line
        )
        XCTAssertEqual(
            pty(rig.recorder),
            expectedSGRStream(base: base, cells: pathCells, reportMotion: reportMotion),
            "\(gesture): the reports must name the cells the pointer actually entered",
            file: file, line: line
        )
    }

    // MARK: - Controls: left drags already report per-cell motion

    /// Proves the rig delivers drag events to the reporting path, that the
    /// probed cells map as claimed, and the exact shape (press, one motion per
    /// new cell, release at the drop cell) the right-button tests then demand.
    func test_control_leftDrag_1002SGR_reportsMotion32PerNewCell() throws {
        let rig = try makeRig(decset: drag1002SGR, expectSGR: true, expectedProtocol: .mouseDrag)
        try performDrag(.left, on: rig, points: pathPoints(in: rig.view))
        assertSGRDrag(rig, base: 0, reportMotion: true, gesture: "left drag under ?1002h/?1006h")
    }

    func test_control_leftDrag_1003SGR_reportsMotion32PerNewCell() throws {
        let rig = try makeRig(decset: any1003SGR, expectSGR: true, expectedProtocol: .mouseMotion)
        try performDrag(.left, on: rig, points: pathPoints(in: rig.view))
        assertSGRDrag(rig, base: 0, reportMotion: true, gesture: "left drag under ?1003h/?1006h")
    }

    /// Control for contract 4: the left button does not report jitter inside a
    /// cell. If this ever fails the de-dup expectation below is unfounded.
    func test_control_leftDrag_1002SGR_jitterInsideOneCellReportsOneMotion() throws {
        let rig = try makeRig(decset: drag1002SGR, expectSGR: true, expectedProtocol: .mouseDrag)
        let target = Cell(row: 2, col: 6)
        let points: [NSPoint] = [
            point(target, in: rig.view),
            point(target, dxCells: 0.2, in: rig.view),
            point(target, dxCells: -0.2, in: rig.view),
            point(target, in: rig.view),
        ]
        try performDrag(.left, on: rig, points: points)
        XCTAssertEqual(
            pty(rig.recorder),
            sgrReport(code: 0, cell: downCell, press: true)
                + sgrReport(code: 32, cell: target, press: true)
                + sgrReport(code: 0, cell: target, press: false),
            "left-button jitter inside one cell under ?1002h/?1006h must produce exactly one motion report"
        )
    }

    /// Control: the legacy encoding of a left drag, so the legacy right-drag
    /// expectation below is built from byte arithmetic already proven here.
    func test_control_leftDrag_1002Legacy_reportsMotionByte() throws {
        let rig = try makeRig(decset: drag1002Legacy, expectSGR: false, expectedProtocol: .mouseDrag)
        try performDrag(.left, on: rig, points: pathPoints(in: rig.view))

        var expected: String = legacyReport(cb: 0, cell: downCell)
        for c in pathCells {
            expected += legacyReport(cb: 32, cell: c)
        }
        expected += legacyReport(cb: 3, cell: pathCells[pathCells.count - 1])
        XCTAssertEqual(
            pty(rig.recorder), expected,
            "left drag under legacy ?1002h must be press Cb=0, motion Cb=32 per new cell, release Cb=3"
        )
    }

    // MARK: - Control: ?1000 never reports motion for any button

    func test_control_rightDrag_1000SGR_reportsNoMotion() throws {
        let rig = try makeRig(decset: click1000SGR, expectSGR: true, expectedProtocol: .mouseReportClick)
        try performDrag(.right, on: rig, points: pathPoints(in: rig.view))
        assertSGRDrag(
            rig, base: 2, reportMotion: false,
            gesture: "right drag under ?1000h/?1006h (click-only tracking: press + release, never motion)"
        )
    }

    // MARK: - The bug: right-button motion is never reported

    func test_rightDrag_1002SGR_reportsMotion34PerNewCell() throws {
        let rig = try makeRig(decset: drag1002SGR, expectSGR: true, expectedProtocol: .mouseDrag)
        try performDrag(.right, on: rig, points: pathPoints(in: rig.view))
        assertSGRDrag(
            rig, base: 2, reportMotion: true,
            gesture: "right drag under ?1002h/?1006h (press 2, motion 32+2 = 34, release 2)"
        )
    }

    func test_rightDrag_1003SGR_reportsMotion34PerNewCell() throws {
        let rig = try makeRig(decset: any1003SGR, expectSGR: true, expectedProtocol: .mouseMotion)
        try performDrag(.right, on: rig, points: pathPoints(in: rig.view))
        assertSGRDrag(
            rig, base: 2, reportMotion: true,
            gesture: "right drag under ?1003h/?1006h (button-held motion is 34, never the 35 hover code)"
        )
    }

    /// Ctrl+left-click is delivered by macOS as the right button with Control
    /// held, so this is the Ctrl+left drag gesture as well.
    func test_ctrlRightDrag_1002SGR_reportsMotion50PerNewCell() throws {
        let rig = try makeRig(decset: drag1002SGR, expectSGR: true, expectedProtocol: .mouseDrag)
        try performDrag(.right, on: rig, modifiers: [.control], points: pathPoints(in: rig.view))
        assertSGRDrag(
            rig, base: 18, reportMotion: true,
            gesture: "Ctrl+right drag under ?1002h/?1006h (press 2+16, motion 32+2+16 = 50, release 2+16)"
        )
    }

    func test_rightDrag_1002SGR_jitterInsideOneCellReportsOneMotion() throws {
        let rig = try makeRig(decset: drag1002SGR, expectSGR: true, expectedProtocol: .mouseDrag)
        let target = Cell(row: 2, col: 6)
        let points: [NSPoint] = [
            point(target, in: rig.view),
            point(target, dxCells: 0.2, in: rig.view),
            point(target, dxCells: -0.2, in: rig.view),
            point(target, in: rig.view),
        ]
        try performDrag(.right, on: rig, points: points)
        XCTAssertEqual(
            pty(rig.recorder),
            sgrReport(code: 2, cell: downCell, press: true)
                + sgrReport(code: 34, cell: target, press: true)
                + sgrReport(code: 2, cell: target, press: false),
            "right-button jitter inside one cell under ?1002h/?1006h must produce exactly one "
            + "motion report (34), like the left button"
        )
    }

    func test_rightDrag_1002Legacy_reportsMotionByteB() throws {
        let rig = try makeRig(decset: drag1002Legacy, expectSGR: false, expectedProtocol: .mouseDrag)
        try performDrag(.right, on: rig, points: pathPoints(in: rig.view))

        var expected: String = legacyReport(cb: 2, cell: downCell)
        for c in pathCells {
            expected += legacyReport(cb: 34, cell: c)
        }
        expected += legacyReport(cb: 3, cell: pathCells[pathCells.count - 1])
        XCTAssertEqual(
            pty(rig.recorder), expected,
            "right drag under legacy ?1002h must be press Cb=2, motion Cb=32+2 (byte 'B') per new "
            + "cell, release Cb=3"
        )
    }
}
