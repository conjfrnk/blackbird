import XCTest
import AppKit
import Metal
@testable import Blackbird
import BBCore

/// Right / middle button parity under terminal mouse reporting (DEC 1002 /
/// 1003 + SGR 1006).
///
/// **The bug this suite exists for.** The left button is the reference
/// implementation of the xterm mouse protocol contract; the right and the
/// "other" (middle) buttons were observed to follow different policies in
/// four ways:
///
///  1. **The right release does not mirror the right press.** A TUI is
///     promised a press/release PAIR. The release must be reported if and
///     only if the press was, no matter what happened in between: the app
///     switched its mouse mode off (`CSI ? 1002 l`) while the button was
///     down, or the user pressed Option (Blackbird's reporting bypass)
///     before letting go. Today the left button honours that; the right
///     button re-evaluates "is reporting on / is Option held" at release
///     time, so the TUI sees a press without a release (stuck drag, stuck
///     `<RightMouse>` state) — or a release for a press it never saw.
///  2. **A stale window-resize context swallows a plain right drag.** The
///     modifier-right-drag window resize latches a context at the
///     modifier-press and drops it at the matching release. If that release
///     is lost (the app deactivated mid-drag), the context stays latched
///     forever, and the NEXT plain right drag in a mouse-reporting TUI is
///     treated as the continuation of the old resize instead of a drag to
///     report. A fresh `rightMouseDown` starts a new gesture and must clear
///     any latched resize state first.
///  3. **Shift+wheel is never reported.** The xterm button code is
///     `64/65 + 4·Shift + 8·Meta + 16·Ctrl`; `<S-ScrollWheelUp>` is `68`
///     (Ctrl is `80`). nvim / tmux / helix bind page-scrolling to these.
///  4. **Middle (and other) button drag motion has its own, weaker policy.**
///     The left and right drag handlers report motion only (a) for a gesture
///     whose press actually reached the TUI, (b) once per newly entered
///     cell, and (c) under button-event / any-event tracking (`?1002` /
///     `?1003`), never under click-only `?1000`. The middle button's drag
///     handler lacks (a) and (b); (c) already holds and is pinned as a
///     control so a fix cannot over-report.
///
/// **The contract pinned here** (decided from the xterm protocol and from
/// the left button's behaviour, not from Blackbird's current code):
///
///  - Left and right: press reported ⇒ release reported with the same
///    button, at the release cell, even if mouse mode was turned off or
///    Option is held at release time. No press ⇒ no release.
///  - After a stale resize latch, a plain right press clears it
///    (`windowResizeController.isResizing == false`) and the gesture is
///    reported exactly like an ordinary right drag: `2 / 34 per new cell /
///    2`.
///  - Shift+wheel toward older content is code 68, toward newer content 69
///    (Ctrl+wheel is 80 — pinned as a control).
///  - Middle drag: `1 / 33 per new cell / 1` under `?1002` and `?1003`;
///    `1 / 1` under `?1000`; nothing at all for a drag whose press the TUI
///    never saw.
///
/// Left-button controls (which pass today) prove the rig delivers each event
/// type to the reporting path and that the probed cells map to the cells the
/// test claims, so the right / middle failures can only be about the
/// asymmetry.
///
/// **Event synthesis.** Left / right mouse events come from
/// `NSEvent.mouseEvent(with:…)`. `NSEvent.mouseEvent` cannot make a middle
/// button event (an `otherMouse*` event built that way claims
/// `buttonNumber` 0), so middle events come from an unposted
/// `CGEvent(mouseEventSource:…)` with `.mouseEventButtonNumber` = 2 bridged
/// through `NSEvent(cgEvent:)` — the technique
/// `MouseSideButtonReportingBlindTests` uses. Wheel events come from an
/// unposted `CGEvent(scrollWheelEvent2Source:…)` with `flags` set, bridged
/// the same way. Nothing is posted to the window server, so this is not
/// event injection and nothing can route back to the outer terminal. Each
/// event's type, button number, modifier state and scroll deltas are
/// asserted before use.
///
/// **Shift+wheel and the axis swap.** When Shift is held, macOS turns a
/// classic (line-unit) vertical wheel notch into a HORIZONTAL one: the
/// bridged event carries the notch in `scrollingDeltaX` and
/// `scrollingDeltaY == 0`. A precise (pixel-unit, trackpad-style) event
/// keeps its vertical delta. The precise Shift+wheel tests are therefore
/// controls (they pass today); the classic-wheel Shift tests are the ones
/// that exercise the bug — a real mouse's Shift+wheel is the swapped event,
/// and the TUI must still receive it as `<S-ScrollWheelUp/Down>` (68 / 69),
/// not lose it because the vertical delta is zero.
///
/// **Why no "right press that was never reported" tests.** Producing one
/// needs a `rightMouseDown` with mouse reporting off or Option held, which
/// falls back to AppKit's context-menu tracking — not safe in a headless
/// view. The "no press ⇒ no release" half of contract 1 is pinned with a
/// release that arrives without any press instead (the press happened
/// somewhere the view never saw it).
///
/// **Memory / time pre-flight** (per `feedback_test_memory_safety`):
///  - One 60 × 8 `BBTerm` per rig — 480 cells, a few KB — `scrollback: 16`.
///  - One 800 × 480 headless `TerminalView` per rig; never added to a
///    window, never shown, never drawn. No `NSWindow`, no
///    `MainWindowController`, no PTY, no shell.
///    `TerminalSession.makeHeadlessForTests()` has no pty, so only the
///    `RecordingPTY` observes writes.
///  - Precise wheel events carry ~3 × cellHeight points; the per-event cap
///    bounds the output at 64 reports. No runloop pumping, no timers. Wall
///    time is dominated by `MTLCreateSystemDefaultDevice()`.
final class MouseButtonParityBlindTests: XCTestCase {

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

    /// Press cell, and a cell a few columns away so a drag crosses cell
    /// boundaries and de-duplication cannot swallow the report under test.
    private let downCell = Cell(row: 2, col: 2)
    private let targetCell = Cell(row: 2, col: 7)

    /// Three successive, all-distinct, all-new cells.
    private let pathCells: [Cell] = [
        Cell(row: 2, col: 4),
        Cell(row: 3, col: 4),
        Cell(row: 3, col: 9),
    ]

    private let rightCode = 2

    // MARK: - Mouse-mode preambles

    /// Click reporting (DEC 1000) + SGR encoding.
    private let click1000SGR = "\u{1B}[?1000h\u{1B}[?1006h"
    /// Button-event tracking (DEC 1002) + SGR encoding.
    private let drag1002SGR = "\u{1B}[?1002h\u{1B}[?1006h"
    /// Any-event tracking (DEC 1003) + SGR encoding.
    private let any1003SGR = "\u{1B}[?1003h\u{1B}[?1006h"
    /// SGR encoding selected but NO tracking mode: reporting is off.
    private let sgrOnlyNoTracking = "\u{1B}[?1006h"
    /// Turns button-event tracking off again (the SGR encoding stays on).
    private let drag1002Off = "\u{1B}[?1002l"

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
        expectReporting: Bool,
        expectedProtocol: BBTermMode?,
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
        // reporting in the wrong state and the stream assertions would be
        // about the wrong thing.
        if let expectedProtocol {
            XCTAssertTrue(
                snapshot.termMode.contains(expectedProtocol),
                "precondition: \(decset.debugDescription) must select the expected mouse protocol; "
                + "termMode.rawValue = \(snapshot.termMode.rawValue)",
                file: file, line: line
            )
        }
        XCTAssertTrue(
            snapshot.termMode.contains(.sgrMouse),
            "precondition: SGR (?1006) encoding must be on; termMode.rawValue = \(snapshot.termMode.rawValue)",
            file: file, line: line
        )
        XCTAssertEqual(
            view.mouseReportingEnabled(), expectReporting,
            "precondition: the view's mouse-reporting state must be \(expectReporting ? "on" : "off")",
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

    /// The TUI changes its mouse mode mid-gesture: feed `sequence` to the
    /// real parser and hand the view the resulting snapshot, exactly as the
    /// render path does.
    private func changeMode(
        _ rig: Rig,
        feeding sequence: String,
        expectReporting: Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        rig.term.input(sequence)
        rig.view.currentSnapshot = try XCTUnwrap(
            rig.term.snapshot(), "snapshot() returned nil", file: file, line: line
        )
        XCTAssertEqual(
            rig.view.mouseReportingEnabled(), expectReporting,
            "precondition: after \(sequence.debugDescription) mouse reporting must be "
            + "\(expectReporting ? "on" : "off")",
            file: file, line: line
        )
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
        case middle
        case right

        var downType: NSEvent.EventType {
            switch self {
            case .left: return .leftMouseDown
            case .middle: return .otherMouseDown
            case .right: return .rightMouseDown
            }
        }
        var draggedType: NSEvent.EventType {
            switch self {
            case .left: return .leftMouseDragged
            case .middle: return .otherMouseDragged
            case .right: return .rightMouseDragged
            }
        }
        var upType: NSEvent.EventType {
            switch self {
            case .left: return .leftMouseUp
            case .middle: return .otherMouseUp
            case .right: return .rightMouseUp
            }
        }
        /// The xterm base button code (before the +32 motion bit and the
        /// modifier bits).
        var xtermCode: Int {
            switch self {
            case .left: return 0
            case .middle: return 1
            case .right: return 2
            }
        }
        var label: String {
            switch self {
            case .left: return "left"
            case .middle: return "middle"
            case .right: return "right"
            }
        }
    }

    private func mouseEvent(
        _ type: NSEvent.EventType,
        at p: NSPoint,
        modifiers: NSEvent.ModifierFlags = [],
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
        let relevant: NSEvent.ModifierFlags = [.shift, .control, .option, .command]
        let held: NSEvent.ModifierFlags = ev.modifierFlags.intersection(relevant)
        XCTAssertEqual(
            held.rawValue, modifiers.intersection(relevant).rawValue,
            "precondition: modifier state must survive event construction",
            file: file, line: line
        )
        return ev
    }

    /// A genuine middle-button (`buttonNumber` 2) `otherMouse*` NSEvent whose
    /// `locationInWindow` is `p`.
    ///
    /// `NSEvent(cgEvent:)` reports `locationInWindow` in Cocoa screen
    /// coordinates (y flipped against the primary screen's height) when there
    /// is no window. Probe that height (build at CG y = 0 and read the y it
    /// comes back with), then rebuild at the CG y that lands on `p.y`. The
    /// final location is asserted, so a wrong guess fails the fixture loudly.
    private func middleMouseEvent(
        _ type: NSEvent.EventType,
        at p: NSPoint,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> NSEvent {
        let cgType: CGEventType
        switch type {
        case .otherMouseDown: cgType = .otherMouseDown
        case .otherMouseUp: cgType = .otherMouseUp
        case .otherMouseDragged: cgType = .otherMouseDragged
        default:
            XCTFail("unsupported event type \(type)", file: file, line: line)
            throw XCTSkip("unsupported event type")
        }

        func build(cgY: CGFloat) throws -> NSEvent {
            let cg: CGEvent = try XCTUnwrap(
                CGEvent(
                    mouseEventSource: nil,
                    mouseType: cgType,
                    mouseCursorPosition: CGPoint(x: p.x, y: cgY),
                    mouseButton: .center
                ),
                "CGEvent(mouseEventSource:) returned nil", file: file, line: line
            )
            cg.setIntegerValueField(.mouseEventButtonNumber, value: 2)
            cg.setIntegerValueField(.mouseEventClickState, value: 1)
            return try XCTUnwrap(
                NSEvent(cgEvent: cg), "NSEvent(cgEvent:) returned nil", file: file, line: line
            )
        }

        let probe: NSEvent = try build(cgY: 0)
        let flipHeight: CGFloat = probe.locationInWindow.y
        let ev: NSEvent = try build(cgY: flipHeight - p.y)

        XCTAssertEqual(
            ev.type, type,
            "precondition: event type must survive the CGEvent bridge",
            file: file, line: line
        )
        XCTAssertEqual(
            ev.buttonNumber, 2,
            "precondition: buttonNumber must survive the CGEvent bridge (middle button == 2)",
            file: file, line: line
        )
        XCTAssertEqual(
            Double(ev.locationInWindow.x), Double(p.x), accuracy: 0.01,
            "precondition: locationInWindow.x must equal the requested point",
            file: file, line: line
        )
        XCTAssertEqual(
            Double(ev.locationInWindow.y), Double(p.y), accuracy: 0.01,
            "precondition: locationInWindow.y must equal the requested point "
            + "(flip height probed as \(flipHeight))",
            file: file, line: line
        )
        return ev
    }

    /// The event for `button` of `type` at `p`: middle through the CGEvent
    /// bridge, left / right through `NSEvent.mouseEvent`.
    private func buttonEvent(
        _ button: Button,
        _ type: NSEvent.EventType,
        at p: NSPoint,
        modifiers: NSEvent.ModifierFlags,
        t: TimeInterval,
        file: StaticString,
        line: UInt
    ) throws -> NSEvent {
        if button == .middle {
            return try middleMouseEvent(type, at: p, file: file, line: line)
        }
        return try mouseEvent(type, at: p, modifiers: modifiers, timestamp: t, file: file, line: line)
    }

    private func down(
        _ button: Button, on view: TerminalView, at p: NSPoint,
        modifiers: NSEvent.ModifierFlags = [], t: TimeInterval,
        file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let ev: NSEvent = try buttonEvent(button, button.downType, at: p, modifiers: modifiers, t: t, file: file, line: line)
        switch button {
        case .left: view.mouseDown(with: ev)
        case .middle: view.otherMouseDown(with: ev)
        case .right: view.rightMouseDown(with: ev)
        }
    }

    private func dragged(
        _ button: Button, on view: TerminalView, at p: NSPoint,
        modifiers: NSEvent.ModifierFlags = [], t: TimeInterval,
        file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let ev: NSEvent = try buttonEvent(button, button.draggedType, at: p, modifiers: modifiers, t: t, file: file, line: line)
        switch button {
        case .left: view.mouseDragged(with: ev)
        case .middle: view.otherMouseDragged(with: ev)
        case .right: view.rightMouseDragged(with: ev)
        }
    }

    private func up(
        _ button: Button, on view: TerminalView, at p: NSPoint,
        modifiers: NSEvent.ModifierFlags = [], t: TimeInterval,
        file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let ev: NSEvent = try buttonEvent(button, button.upType, at: p, modifiers: modifiers, t: t, file: file, line: line)
        switch button {
        case .left: view.mouseUp(with: ev)
        case .middle: view.otherMouseUp(with: ev)
        case .right: view.rightMouseUp(with: ev)
        }
    }

    /// Pointer samples that jitter inside one cell.
    private func jitterPoints(in cell: Cell, view: TerminalView) -> [NSPoint] {
        [
            point(cell, in: view),
            point(cell, dxCells: 0.2, in: view),
            point(cell, dxCells: -0.2, in: view),
            point(cell, in: view),
        ]
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

    private struct SGRReport: Equatable, CustomStringConvertible {
        let code: Int
        let col: Int
        let row: Int
        let press: Bool
        var description: String {
            "<ESC>[<\(code);\(col);\(row)\(press ? "M" : "m")"
        }
    }

    /// Parse the recorded stream as SGR mouse reports; leftover bytes are
    /// asserted empty so a stray byte cannot hide from the assertions.
    private func sgrReports(
        _ recorder: RecordingPTY,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> [SGRReport] {
        let text: String = String(decoding: recorder.sent, as: UTF8.self)
        let ns: NSString = text as NSString
        let whole = NSRange(location: 0, length: ns.length)
        guard let regex = try? NSRegularExpression(pattern: "\u{1B}\\[<(\\d+);(\\d+);(\\d+)([Mm])") else {
            XCTFail("SGR report regex failed to compile", file: file, line: line)
            return []
        }
        let reports: [SGRReport] = regex.matches(in: text, range: whole).map { (m: NSTextCheckingResult) -> SGRReport in
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

    private func sgrCodes(
        _ recorder: RecordingPTY,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> [Int] {
        sgrReports(recorder, file: file, line: line).map { (r: SGRReport) -> Int in r.code }
    }

    /// Assert the press/release pair the TUI must see for a click that
    /// pressed AND released at `downCell`: exactly two reports, the press
    /// with `code` (final `M`) and the release with `code` (final `m`), or
    /// for `allowMetaOnRelease` a release code that is `code` or `code + 8`
    /// (Option reads as the Meta bit when it is held at release time).
    private func assertPressReleasePair(
        _ rig: Rig,
        code: Int,
        allowMetaOnRelease: Bool = false,
        gesture: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let reports: [SGRReport] = sgrReports(rig.recorder, file: file, line: line)
        let stream: String = pty(rig.recorder)
        XCTAssertEqual(
            reports.count, 2,
            "\(gesture): the TUI must receive exactly a press and a release; stream: \(stream)",
            file: file, line: line
        )
        guard reports.count == 2 else { return }
        XCTAssertEqual(
            reports[0].description,
            SGRReport(code: code, col: downCell.col + 1, row: downCell.row + 1, press: true).description,
            "\(gesture): first report must be the press (code \(code)); stream: \(stream)",
            file: file, line: line
        )
        let releaseCodeOK: Bool = allowMetaOnRelease
            ? (reports[1].code == code || reports[1].code == code + 8)
            : (reports[1].code == code)
        XCTAssertTrue(
            releaseCodeOK && !reports[1].press
                && reports[1].col == downCell.col + 1 && reports[1].row == downCell.row + 1,
            "\(gesture): second report must be the release of button code \(code) at the press cell "
            + "(\(downCell.col + 1);\(downCell.row + 1)) with final 'm'; got \(reports[1]); stream: \(stream)",
            file: file, line: line
        )
    }

    // MARK: - (1) The release mirrors the press — mode turned off mid-gesture

    private func runReleaseAfterModeOff(
        _ button: Button, file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let rig = try makeRig(
            decset: drag1002SGR, expectReporting: true, expectedProtocol: .mouseDrag,
            file: file, line: line
        )
        let p: NSPoint = point(downCell, in: rig.view)

        try down(button, on: rig.view, at: p, t: 1.0, file: file, line: line)
        XCTAssertEqual(
            pty(rig.recorder), sgrReport(code: button.xtermCode, cell: downCell, press: true),
            "precondition: the \(button.label) press under ?1002h/?1006h must reach the TUI",
            file: file, line: line
        )

        try changeMode(rig, feeding: drag1002Off, expectReporting: false, file: file, line: line)
        try up(button, on: rig.view, at: p, t: 1.02, file: file, line: line)

        assertPressReleasePair(
            rig, code: button.xtermCode,
            gesture: "\(button.label) press reported, then the TUI sent ?1002l, then release "
                + "(the release must follow the press, not the current mode)",
            file: file, line: line
        )
    }

    func test_control_leftRelease_followsReportedPress_afterMouseModeTurnedOff() throws {
        try runReleaseAfterModeOff(.left)
    }

    func test_rightRelease_followsReportedPress_afterMouseModeTurnedOff() throws {
        try runReleaseAfterModeOff(.right)
    }

    // MARK: - (1) The release mirrors the press — Option held at release

    private func runReleaseWithOptionHeld(
        _ button: Button, file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let rig = try makeRig(
            decset: drag1002SGR, expectReporting: true, expectedProtocol: .mouseDrag,
            file: file, line: line
        )
        let p: NSPoint = point(downCell, in: rig.view)

        try down(button, on: rig.view, at: p, t: 1.0, file: file, line: line)
        XCTAssertEqual(
            pty(rig.recorder), sgrReport(code: button.xtermCode, cell: downCell, press: true),
            "precondition: the \(button.label) press under ?1002h/?1006h must reach the TUI",
            file: file, line: line
        )

        try up(button, on: rig.view, at: p, modifiers: [.option], t: 1.02, file: file, line: line)

        assertPressReleasePair(
            rig, code: button.xtermCode, allowMetaOnRelease: true,
            gesture: "\(button.label) press reported, then Option pressed, then release "
                + "(Option bypasses NEW gestures; a reported press still gets its release)",
            file: file, line: line
        )
    }

    func test_control_leftRelease_followsReportedPress_whenOptionHeldAtRelease() throws {
        try runReleaseWithOptionHeld(.left)
    }

    func test_rightRelease_followsReportedPress_whenOptionHeldAtRelease() throws {
        try runReleaseWithOptionHeld(.right)
    }

    // MARK: - (1) No press ⇒ no release

    func test_control_leftRelease_withoutAnyPress_isNotReported() throws {
        let rig = try makeRig(decset: drag1002SGR, expectReporting: true, expectedProtocol: .mouseDrag)
        try up(.left, on: rig.view, at: point(downCell, in: rig.view), t: 1.0)
        XCTAssertEqual(
            pty(rig.recorder), "",
            "a left release whose press the view never saw must not be reported (orphan release)"
        )
    }

    func test_rightRelease_withoutAnyPress_isNotReported() throws {
        let rig = try makeRig(decset: drag1002SGR, expectReporting: true, expectedProtocol: .mouseDrag)
        try up(.right, on: rig.view, at: point(downCell, in: rig.view), t: 1.0)
        XCTAssertEqual(
            pty(rig.recorder), "",
            "a right release whose press the view never saw must not be reported (orphan release); "
            + "the TUI would see a release for a press it never received"
        )
    }

    // MARK: - (2) A stale window-resize latch must not swallow a plain right drag

    /// Latch a window-resize context exactly as a ⌘-right-press does, and
    /// never deliver its release (the app deactivated mid-drag).
    private func latchStaleResize(on view: TerminalView, file: StaticString = #filePath, line: UInt = #line) {
        view.windowResizeController.begin(
            localPoint: CGPoint(x: view.bounds.width - 10, y: view.bounds.height - 10),
            in: view.bounds,
            startMouseGlobal: CGPoint(x: 1000, y: 700),
            windowFrame: NSRect(x: 100, y: 100, width: 800, height: 520)
        )
        XCTAssertTrue(
            view.windowResizeController.isResizing,
            "precondition: the fixture must have a latched window-resize context",
            file: file, line: line
        )
    }

    /// Press at `downCell`, drag through `pathCells`, release at the last.
    private func plainRightDrag(
        on rig: Rig,
        file: StaticString = #filePath, line: UInt = #line
    ) throws {
        var t: TimeInterval = 2.0
        try down(.right, on: rig.view, at: point(downCell, in: rig.view), t: t, file: file, line: line)
        for c in pathCells {
            t += 0.01
            try dragged(.right, on: rig.view, at: point(c, in: rig.view), t: t, file: file, line: line)
        }
        t += 0.01
        try up(.right, on: rig.view, at: point(pathCells[pathCells.count - 1], in: rig.view), t: t, file: file, line: line)
    }

    private var expectedPlainRightDragStream: String {
        var s: String = sgrReport(code: rightCode, cell: downCell, press: true)
        for c in pathCells {
            s += sgrReport(code: rightCode + 32, cell: c, press: true)
        }
        s += sgrReport(code: rightCode, cell: pathCells[pathCells.count - 1], press: false)
        return s
    }

    /// Control: with no latch, the same gesture is reported in full, so the
    /// latch tests below can only fail because of the latch.
    func test_control_plainRightDrag_withoutLatch_isReportedAsPressMotionRelease() throws {
        let rig = try makeRig(decset: drag1002SGR, expectReporting: true, expectedProtocol: .mouseDrag)
        XCTAssertFalse(rig.view.windowResizeController.isResizing, "precondition: no resize latched")
        try plainRightDrag(on: rig)
        XCTAssertEqual(
            pty(rig.recorder), expectedPlainRightDragStream,
            "right drag under ?1002h/?1006h with no latched resize: press 2, motion 34 per new cell, release 2"
        )
    }

    func test_freshRightMouseDown_clearsLatchedWindowResize() throws {
        let rig = try makeRig(decset: drag1002SGR, expectReporting: true, expectedProtocol: .mouseDrag)
        latchStaleResize(on: rig.view)

        try down(.right, on: rig.view, at: point(downCell, in: rig.view), t: 2.0)

        XCTAssertFalse(
            rig.view.windowResizeController.isResizing,
            "a fresh plain rightMouseDown starts a new gesture and must clear any latched "
            + "window-resize context left behind by a lost rightMouseUp"
        )
    }

    func test_plainRightDrag_afterStaleResizeLatch_isReportedAsMotion() throws {
        let rig = try makeRig(decset: drag1002SGR, expectReporting: true, expectedProtocol: .mouseDrag)
        latchStaleResize(on: rig.view)

        try plainRightDrag(on: rig)

        XCTAssertEqual(
            pty(rig.recorder), expectedPlainRightDragStream,
            "a plain right drag after a stale (never-released) window-resize latch must be reported "
            + "to the TUI exactly like an ordinary right drag: press 2, motion 34 per new cell, release 2"
        )
        XCTAssertFalse(
            rig.view.windowResizeController.isResizing,
            "no window-resize context may survive a completed plain right gesture"
        )
    }

    // MARK: - (3) Shift / Ctrl + wheel

    /// A precise (pixel-unit, trackpad-style) wheel event of `pixels` points
    /// carrying `flags`. Positive = toward older content.
    private func preciseWheelEvent(
        pixels: Int32,
        flags: CGEventFlags,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> NSEvent {
        let cg: CGEvent = try XCTUnwrap(
            CGEvent(
                scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1,
                wheel1: pixels, wheel2: 0, wheel3: 0
            ),
            "CGEvent(scrollWheelEvent2Source:) returned nil", file: file, line: line
        )
        cg.flags = flags
        let ev: NSEvent = try XCTUnwrap(
            NSEvent(cgEvent: cg), "NSEvent(cgEvent:) returned nil", file: file, line: line
        )
        let held: NSEvent.ModifierFlags = ev.modifierFlags.intersection(.deviceIndependentFlagsMask)
        XCTAssertEqual(ev.type, .scrollWheel, "precondition: bridged event must be a scroll wheel", file: file, line: line)
        XCTAssertTrue(
            ev.hasPreciseScrollingDeltas,
            "precondition: .pixel units must bridge to a precise wheel event",
            file: file, line: line
        )
        XCTAssertEqual(
            ev.scrollingDeltaY, Double(pixels), accuracy: 1e-9,
            "precondition: scrollingDeltaY must bridge 1:1 from wheel1 for .pixel units "
            + "(scrollingDeltaX = \(ev.scrollingDeltaX))",
            file: file, line: line
        )
        XCTAssertEqual(
            held.contains(.shift), flags.contains(.maskShift),
            "precondition: Shift state must survive the CGEvent bridge (flags \(held.rawValue))",
            file: file, line: line
        )
        XCTAssertEqual(
            held.contains(.control), flags.contains(.maskControl),
            "precondition: Control state must survive the CGEvent bridge (flags \(held.rawValue))",
            file: file, line: line
        )
        XCTAssertFalse(
            held.contains(.option) || held.contains(.command),
            "precondition: no Option (local-scroll escape hatch) or Command may be held (flags \(held.rawValue))",
            file: file, line: line
        )
        return ev
    }

    /// Enough points for several whole lines at the view's cell height.
    private func wheelPixels(_ view: TerminalView) -> Int32 {
        Int32((view.metrics.cellHeight * 3).rounded(.up))
    }

    private func runPreciseWheel(
        up: Bool, flags: CGEventFlags, expectedCode: Int, label: String,
        file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let rig = try makeRig(
            decset: click1000SGR, expectReporting: true, expectedProtocol: .mouseReportClick,
            file: file, line: line
        )
        let magnitude: Int32 = wheelPixels(rig.view)
        let pixels: Int32 = up ? magnitude : -magnitude
        rig.view.scrollWheel(with: try preciseWheelEvent(pixels: pixels, flags: flags, file: file, line: line))

        let codes: [Int] = sgrCodes(rig.recorder, file: file, line: line)
        XCTAssertFalse(
            codes.isEmpty,
            "\(label): a precise wheel gesture of \(pixels) points must be reported to the TUI; "
            + "PTY bytes: \(pty(rig.recorder))",
            file: file, line: line
        )
        XCTAssertEqual(
            Set(codes), [expectedCode],
            "\(label): every report must carry SGR code \(expectedCode); measured codes \(codes)",
            file: file, line: line
        )
    }

    func test_control_preciseWheelUp_1000SGR_isCode64() throws {
        try runPreciseWheel(up: true, flags: [], expectedCode: 64, label: "plain precise wheel toward older content")
    }

    func test_control_preciseCtrlWheelUp_1000SGR_isCode80() throws {
        try runPreciseWheel(
            up: true, flags: .maskControl, expectedCode: 80,
            label: "Ctrl+precise wheel toward older content (64 + 16)"
        )
    }

    /// Control: with a precise event (vertical delta preserved under Shift)
    /// the Shift bit is already reported, so the classic-wheel failures below
    /// are about the swapped axis, not about the modifier bit.
    func test_control_preciseShiftWheelUp_1000SGR_isCode68() throws {
        try runPreciseWheel(
            up: true, flags: .maskShift, expectedCode: 68,
            label: "Shift+precise wheel toward older content (64 + 4, <S-ScrollWheelUp>)"
        )
    }

    func test_control_preciseShiftWheelDown_1000SGR_isCode69() throws {
        try runPreciseWheel(
            up: false, flags: .maskShift, expectedCode: 69,
            label: "Shift+precise wheel toward newer content (65 + 4, <S-ScrollWheelDown>)"
        )
    }

    /// A classic (line-unit) wheel event of `notches` carrying `flags`, as a
    /// real mouse wheel produces. The notch may land on either axis (macOS
    /// swaps it to X under Shift); the precondition only pins that the notch
    /// is present, with its sign, on exactly one of the two axes.
    private func classicWheelEvent(
        notches: Int32,
        flags: CGEventFlags,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> NSEvent {
        let cg: CGEvent = try XCTUnwrap(
            CGEvent(
                scrollWheelEvent2Source: nil, units: .line, wheelCount: 1,
                wheel1: notches, wheel2: 0, wheel3: 0
            ),
            "CGEvent(scrollWheelEvent2Source:) returned nil", file: file, line: line
        )
        cg.flags = flags
        let ev: NSEvent = try XCTUnwrap(
            NSEvent(cgEvent: cg), "NSEvent(cgEvent:) returned nil", file: file, line: line
        )
        let held: NSEvent.ModifierFlags = ev.modifierFlags.intersection(.deviceIndependentFlagsMask)
        XCTAssertEqual(ev.type, .scrollWheel, "precondition: bridged event must be a scroll wheel", file: file, line: line)
        XCTAssertFalse(
            ev.hasPreciseScrollingDeltas,
            "precondition: .line units must bridge to a classic wheel event",
            file: file, line: line
        )
        let notch: Double = ev.scrollingDeltaY != 0 ? ev.scrollingDeltaY : ev.scrollingDeltaX
        XCTAssertEqual(
            notch, Double(notches), accuracy: 1e-9,
            "precondition: the notch must survive the bridge on exactly one axis "
            + "(scrollingDeltaY = \(ev.scrollingDeltaY), scrollingDeltaX = \(ev.scrollingDeltaX))",
            file: file, line: line
        )
        XCTAssertEqual(
            held.contains(.shift), flags.contains(.maskShift),
            "precondition: Shift state must survive the CGEvent bridge (flags \(held.rawValue))",
            file: file, line: line
        )
        XCTAssertFalse(
            held.contains(.option) || held.contains(.command) || held.contains(.control),
            "precondition: no Option / Command / Control may be held (flags \(held.rawValue))",
            file: file, line: line
        )
        return ev
    }

    private func runClassicWheel(
        notches: Int32, flags: CGEventFlags, expectedCode: Int, label: String,
        file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let rig = try makeRig(
            decset: click1000SGR, expectReporting: true, expectedProtocol: .mouseReportClick,
            file: file, line: line
        )
        rig.view.scrollWheel(with: try classicWheelEvent(notches: notches, flags: flags, file: file, line: line))

        let codes: [Int] = sgrCodes(rig.recorder, file: file, line: line)
        XCTAssertFalse(
            codes.isEmpty,
            "\(label): a classic wheel notch (\(notches)) must be reported to the TUI; "
            + "PTY bytes: \(pty(rig.recorder))",
            file: file, line: line
        )
        XCTAssertEqual(
            Set(codes), [expectedCode],
            "\(label): every report must carry SGR code \(expectedCode); measured codes \(codes)",
            file: file, line: line
        )
    }

    /// Control: a plain classic notch is reported as 64 / 65.
    func test_control_classicWheelUp_1000SGR_isCode64() throws {
        try runClassicWheel(notches: 1, flags: [], expectedCode: 64, label: "plain classic wheel toward older content")
    }

    func test_classicShiftWheelUp_1000SGR_isCode68() throws {
        try runClassicWheel(
            notches: 1, flags: .maskShift, expectedCode: 68,
            label: "Shift+classic wheel toward older content (64 + 4, <S-ScrollWheelUp>)"
        )
    }

    func test_classicShiftWheelDown_1000SGR_isCode69() throws {
        try runClassicWheel(
            notches: -1, flags: .maskShift, expectedCode: 69,
            label: "Shift+classic wheel toward newer content (65 + 4, <S-ScrollWheelDown>)"
        )
    }

    // MARK: - (4) Middle-button drag follows the left/right drag policy

    /// Press at `downCell`, drag through `points`, release at the last
    /// point (or at the press point when `points` is empty).
    private func performDrag(
        _ button: Button, on rig: Rig, points: [NSPoint],
        file: StaticString = #filePath, line: UInt = #line
    ) throws {
        var t: TimeInterval = 1.0
        let start: NSPoint = point(downCell, in: rig.view)
        try down(button, on: rig.view, at: start, t: t, file: file, line: line)
        for p in points {
            t += 0.01
            try dragged(button, on: rig.view, at: p, t: t, file: file, line: line)
        }
        t += 0.01
        try up(button, on: rig.view, at: points.last ?? start, t: t, file: file, line: line)
    }

    /// Control: the left button reports exactly one motion for jitter inside
    /// one cell.
    func test_control_leftDrag_1002SGR_jitterInsideOneCell_reportsOneMotion() throws {
        let rig = try makeRig(decset: drag1002SGR, expectReporting: true, expectedProtocol: .mouseDrag)
        try performDrag(.left, on: rig, points: jitterPoints(in: targetCell, view: rig.view))
        XCTAssertEqual(
            pty(rig.recorder),
            sgrReport(code: 0, cell: downCell, press: true)
                + sgrReport(code: 32, cell: targetCell, press: true)
                + sgrReport(code: 0, cell: targetCell, press: false),
            "left-button jitter inside one cell under ?1002h/?1006h must produce exactly one motion report"
        )
    }

    func test_middleDrag_1002SGR_jitterInsideOneCell_reportsOneMotion() throws {
        let rig = try makeRig(decset: drag1002SGR, expectReporting: true, expectedProtocol: .mouseDrag)
        try performDrag(.middle, on: rig, points: jitterPoints(in: targetCell, view: rig.view))
        XCTAssertEqual(
            pty(rig.recorder),
            sgrReport(code: 1, cell: downCell, press: true)
                + sgrReport(code: 33, cell: targetCell, press: true)
                + sgrReport(code: 1, cell: targetCell, press: false),
            "middle-button jitter inside one cell under ?1002h/?1006h must produce exactly one "
            + "motion report (33), like the left button — one per pointer sample floods the TUI"
        )
    }

    func test_middleDrag_1003SGR_jitterInsideOneCell_reportsOneMotion() throws {
        let rig = try makeRig(decset: any1003SGR, expectReporting: true, expectedProtocol: .mouseMotion)
        try performDrag(.middle, on: rig, points: jitterPoints(in: targetCell, view: rig.view))
        XCTAssertEqual(
            pty(rig.recorder),
            sgrReport(code: 1, cell: downCell, press: true)
                + sgrReport(code: 33, cell: targetCell, press: true)
                + sgrReport(code: 1, cell: targetCell, press: false),
            "middle-button jitter inside one cell under ?1003h/?1006h must produce exactly one "
            + "motion report (33), like the left button"
        )
    }

    /// Control: under click-only tracking the left button never reports motion.
    func test_control_leftDrag_1000SGR_reportsNoMotion() throws {
        let rig = try makeRig(decset: click1000SGR, expectReporting: true, expectedProtocol: .mouseReportClick)
        let points: [NSPoint] = pathCells.map { (c: Cell) -> NSPoint in point(c, in: rig.view) }
        try performDrag(.left, on: rig, points: points)
        XCTAssertEqual(
            sgrCodes(rig.recorder), [0, 0],
            "a left drag under click-only ?1000h/?1006h is press + release, never motion; "
            + "stream: \(pty(rig.recorder))"
        )
    }

    /// Control: the mode predicate (c) already holds for the middle button.
    func test_control_middleDrag_1000SGR_reportsNoMotion() throws {
        let rig = try makeRig(decset: click1000SGR, expectReporting: true, expectedProtocol: .mouseReportClick)
        let points: [NSPoint] = pathCells.map { (c: Cell) -> NSPoint in point(c, in: rig.view) }
        try performDrag(.middle, on: rig, points: points)
        XCTAssertEqual(
            sgrCodes(rig.recorder), [1, 1],
            "a middle drag under click-only ?1000h/?1006h is press(1) + release(1), never motion(33); "
            + "stream: \(pty(rig.recorder))"
        )
    }

    /// Control for the press-flag tests: a gesture whose press the TUI never
    /// saw (mouse reporting was off at press time) produces no motion for the
    /// left button, even though reporting is on by the time it drags.
    func test_control_leftDrag_whosePressWasNeverReported_reportsNoMotion() throws {
        let rig = try makeRig(decset: sgrOnlyNoTracking, expectReporting: false, expectedProtocol: nil)
        try down(.left, on: rig.view, at: point(downCell, in: rig.view), t: 1.0)
        XCTAssertEqual(pty(rig.recorder), "", "precondition: with reporting off the press reaches no one")

        try changeMode(rig, feeding: drag1002SGR, expectReporting: true)
        var t: TimeInterval = 1.0
        for c in pathCells {
            t += 0.01
            try dragged(.left, on: rig.view, at: point(c, in: rig.view), t: t)
        }
        XCTAssertEqual(
            pty(rig.recorder), "",
            "a left drag whose press was never reported must not produce motion reports"
        )
    }

    func test_middleDrag_whosePressWasNeverReported_reportsNoMotion() throws {
        let rig = try makeRig(decset: sgrOnlyNoTracking, expectReporting: false, expectedProtocol: nil)
        try down(.middle, on: rig.view, at: point(downCell, in: rig.view), t: 1.0)
        XCTAssertEqual(pty(rig.recorder), "", "precondition: with reporting off the press reaches no one")

        try changeMode(rig, feeding: drag1002SGR, expectReporting: true)
        var t: TimeInterval = 1.0
        for c in pathCells {
            t += 0.01
            try dragged(.middle, on: rig.view, at: point(c, in: rig.view), t: t)
        }
        XCTAssertEqual(
            pty(rig.recorder), "",
            "a middle drag whose press was never reported (reporting was off at press time) must "
            + "not produce motion(33) reports for a button the TUI never saw go down"
        )
    }

    /// The same policy for a drag event that arrives with no press at all
    /// (the press landed on another view).
    func test_middleDrag_withoutAnyPress_reportsNoMotion() throws {
        let rig = try makeRig(decset: drag1002SGR, expectReporting: true, expectedProtocol: .mouseDrag)
        var t: TimeInterval = 1.0
        for c in pathCells {
            t += 0.01
            try dragged(.middle, on: rig.view, at: point(c, in: rig.view), t: t)
        }
        XCTAssertEqual(
            pty(rig.recorder), "",
            "a middle-button drag event with no preceding reported press must not be reported"
        )
    }
}
