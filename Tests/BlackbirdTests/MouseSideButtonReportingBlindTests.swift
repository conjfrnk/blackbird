import XCTest
import AppKit
import Metal
@testable import Blackbird
import BBCore

/// Mouse side buttons (Back / Forward) under terminal mouse reporting.
///
/// **The bug this suite exists for.** A TUI that enables mouse reporting
/// (tmux with `mouse on`, vim with `mouse=a`, Claude Code's REPL) is told
/// about the pointer through the xterm mouse protocol, which has a fixed
/// vocabulary for buttons: 0 = left, 1 = middle, 2 = right (plus 64/65 for the
/// wheel). The two thumb buttons on a typical mouse (Back / Forward) arrive in
/// AppKit as `otherMouseDown` / `otherMouseDragged` / `otherMouseUp` with
/// `NSEvent.buttonNumber` 3 and 4 — the *same* event types the genuine middle
/// button uses (`buttonNumber` 2). A handler that treats "any other mouse
/// button" as "the middle button" reports every thumb-button click as a
/// middle-click: vim fires `<MiddleMouse>` and pastes a register, tmux's
/// `MouseDown2Pane` pastes its buffer into the active pane. A stray thumb
/// click inserts text the user never asked for. Dragging with a thumb button
/// held additionally produces middle-button motion reports (SGR button 33).
///
/// **The contract pinned here** (decided from the xterm protocol and from the
/// way other terminals behave, not from Blackbird's current code):
///
///  1. A genuine middle click (`buttonNumber` 2) is still reported as xterm
///     button 1 — press then release, same cell. (Control: proves the rig
///     really delivers `otherMouse*` events to the reporting path, so the
///     side-button silence below is not vacuous.)
///  2. A Back (3) or Forward (4) click is NEVER reported as left / middle /
///     right. The SGR (`?1006`) stream for such a click may be empty, or may
///     carry the extended-button code space (button codes with bit 7 set,
///     i.e. >= 128, which is what xterm-family terminals use for buttons
///     8…11); it may not contain any code below 128. Code 1 is the bug.
///  3. Under the legacy X10/normal encoding (no `?1006`) there is no way to
///     name a side button, so the only correct output is nothing at all —
///     in particular no middle-button press (`ESC [ M !`) and no orphan
///     release (`ESC [ M #`).
///  4. Dragging with a side button held (`?1002` button-event or `?1003`
///     any-event tracking) emits no motion report in the left/middle/right
///     space either — button 33 (`32 + middle`) is the bug.
///
/// Contract 2 is deliberately stated as "nothing below 128" rather than "the
/// stream is empty": whether a fix suppresses side buttons entirely or
/// forwards them as extended buttons is a product choice, but reporting them
/// as one of the three real buttons is wrong under both.
///
/// **Event synthesis.** `NSEvent.mouseEvent(with:…)` has no `buttonNumber`
/// parameter, so a synthesised `otherMouseDown` would always claim to be the
/// middle button. Events therefore come from an unposted
/// `CGEvent(mouseEventSource:mouseType:mouseCursorPosition:mouseButton:)` with
/// `.mouseEventButtonNumber` set, bridged through `NSEvent(cgEvent:)` — the
/// same technique `AlternateScrollWheelBlindTests` uses for scroll wheels.
/// Nothing is posted to the window server, so this is not event injection and
/// nothing can route back to the outer terminal. Each event's `type`,
/// `buttonNumber` and `locationInWindow` are asserted before use, so if the
/// bridge ever changes the fixture fails first.
///
/// **Geometry.** Identical to `LinkClickUnderMouseReportingBlindTests`: the
/// view is never added to a window, so its frame origin is (0, 0) and
/// `locationInWindow` equals the view-local point. The control test asserts
/// the report names the cell the test claims to have clicked.
///
/// **Memory / time pre-flight** (per `feedback_test_memory_safety`):
///  - One 60 × 8 `BBTerm` per rig — 480 cells, a few KB — `scrollback: 16`.
///  - One 800 × 480 headless `TerminalView` per rig; never added to a window,
///    never shown, never drawn. No `NSWindow`, no `MainWindowController`, no
///    PTY, no shell. `TerminalSession.makeHeadlessForTests()` has no pty, so
///    only the `RecordingPTY` observes writes.
///  - No runloop pumping, no timers. Wall time is dominated by
///    `MTLCreateSystemDefaultDevice()`.
final class MouseSideButtonReportingBlindTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        TestHostTermination.shared.register()
    }

    // MARK: - Fixture constants

    private let gridCols: UInt16 = 60
    private let gridRows: UInt16 = 8

    /// Press cell and drag-target cell (zero-based). Interior rows/columns, a
    /// few cells apart so a drag crosses a cell boundary and any motion-report
    /// de-duplication cannot swallow the report the drag tests look for.
    private let downRow = 2
    private let downCol = 2
    private let dragCol = 7

    private let backButton = 3
    private let forwardButton = 4
    private let middleButton = 2

    // MARK: - Mouse-mode preambles

    /// Click reporting (DEC 1000) + SGR encoding.
    private let click1000SGR = "\u{1B}[?1000h\u{1B}[?1006h"
    /// Button-event tracking (DEC 1002) + SGR encoding.
    private let drag1002SGR = "\u{1B}[?1002h\u{1B}[?1006h"
    /// Any-event tracking (DEC 1003) + SGR encoding.
    private let any1003SGR = "\u{1B}[?1003h\u{1B}[?1006h"
    /// Click reporting with the legacy (X10 / normal) encoding: no `?1006`.
    private let click1000Legacy = "\u{1B}[?1000h"
    /// Any-event tracking with the legacy encoding.
    private let any1003Legacy = "\u{1B}[?1003h"

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
        // reporting OFF and every "no report" assertion below would be green
        // for the wrong reason.
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
        return Rig(view: view, term: term, session: session, recorder: recorder)
    }

    // MARK: - Geometry + event synthesis

    /// View-local (== window-local, the view has no window) point at the
    /// centre of grid cell (`row`, `col`).
    private func point(row: Int, col: Int, in view: TerminalView) -> NSPoint {
        let textAreaHeight = view.bounds.height - view.titlebarOnlyTopInset
        return NSPoint(
            x: TerminalView.horizontalContentInsetPoints
                + (CGFloat(col) + 0.5) * view.metrics.cellWidth,
            y: textAreaHeight - (CGFloat(row) + 0.5) * view.metrics.cellHeight
        )
    }

    /// An `otherMouse*` NSEvent carrying `buttonNumber`, whose
    /// `locationInWindow` is `p`.
    ///
    /// `NSEvent(cgEvent:)` reports `locationInWindow` in Cocoa screen
    /// coordinates (y flipped against the primary screen's height) when there
    /// is no window. Rather than assume that height, probe it: build the event
    /// at CG y = 0, read the y it comes back with (that IS the flip height),
    /// then rebuild at the CG y that lands on `p.y`. The final location is
    /// asserted, so a wrong guess fails the fixture loudly.
    private func otherMouseEvent(
        _ type: NSEvent.EventType,
        button: Int,
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
            let cg = try XCTUnwrap(
                CGEvent(
                    mouseEventSource: nil,
                    mouseType: cgType,
                    mouseCursorPosition: CGPoint(x: p.x, y: cgY),
                    mouseButton: .center
                ),
                "CGEvent(mouseEventSource:) returned nil", file: file, line: line
            )
            cg.setIntegerValueField(.mouseEventButtonNumber, value: Int64(button))
            cg.setIntegerValueField(.mouseEventClickState, value: 1)
            return try XCTUnwrap(
                NSEvent(cgEvent: cg), "NSEvent(cgEvent:) returned nil", file: file, line: line
            )
        }

        let probe = try build(cgY: 0)
        let flipHeight = probe.locationInWindow.y
        let ev = try build(cgY: flipHeight - p.y)

        XCTAssertEqual(
            ev.type, type,
            "precondition: event type must survive the CGEvent bridge",
            file: file, line: line
        )
        XCTAssertEqual(
            ev.buttonNumber, button,
            "precondition: buttonNumber must survive the CGEvent bridge",
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

    // MARK: - PTY-byte oracle

    /// Everything written toward the PTY so far, with ESC rendered `<ESC>` so
    /// an assertion failure prints something a human can read.
    private func pty(_ recorder: RecordingPTY) -> String {
        String(decoding: recorder.sent, as: UTF8.self)
            .replacingOccurrences(of: "\u{1B}", with: "<ESC>")
    }

    /// The SGR (`?1006`) mouse report for `code` at zero-based (`row`, `col`).
    private func sgrReport(code: Int, row: Int, col: Int, press: Bool) -> String {
        "<ESC>[<\(code);\(col + 1);\(row + 1)\(press ? "M" : "m")"
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

    /// Parse the recorded stream as a sequence of SGR mouse reports.
    /// Anything that is not a well-formed report is returned as `leftover` so
    /// a stray byte cannot hide from the assertions.
    private func parseSGR(_ recorder: RecordingPTY) -> (reports: [SGRReport], leftover: String) {
        let text = String(decoding: recorder.sent, as: UTF8.self)
        let ns = text as NSString
        let whole = NSRange(location: 0, length: ns.length)
        // ESC [ < code ; col ; row (M|m)
        guard let regex = try? NSRegularExpression(pattern: "\u{1B}\\[<(\\d+);(\\d+);(\\d+)([Mm])") else {
            XCTFail("SGR report regex failed to compile")
            return ([], text)
        }
        let reports = regex.matches(in: text, range: whole).map { m in
            SGRReport(
                code: Int(ns.substring(with: m.range(at: 1))) ?? -1,
                col: Int(ns.substring(with: m.range(at: 2))) ?? -1,
                row: Int(ns.substring(with: m.range(at: 3))) ?? -1,
                press: ns.substring(with: m.range(at: 4)) == "M"
            )
        }
        let rest = regex.stringByReplacingMatches(in: text, range: whole, withTemplate: "")
        return (reports, rest.replacingOccurrences(of: "\u{1B}", with: "<ESC>"))
    }

    /// Contract 2 / 4 in one place: a side-button gesture may produce no SGR
    /// report, or reports in the extended-button space (code >= 128); it may
    /// never produce a report a TUI would read as left / middle / right /
    /// motion / wheel (any code < 128).
    private func assertNoPlainButtonReports(
        _ recorder: RecordingPTY,
        gesture: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let parsed = parseSGR(recorder)
        XCTAssertEqual(
            parsed.leftover, "",
            "\(gesture): the PTY stream must consist only of well-formed SGR reports; "
            + "unparsed remainder shown (full stream: \(pty(recorder)))",
            file: file, line: line
        )
        let plain = parsed.reports.filter { $0.code < 128 }
        XCTAssertEqual(
            plain.map(\.description), [],
            "\(gesture): a mouse side button must not be reported as left/middle/right "
            + "(SGR code < 128). Full stream the TUI received: \(pty(recorder))",
            file: file, line: line
        )
    }

    // MARK: - (1) Control: the real middle button still reports as button 1

    /// Proves the rig delivers `otherMouseDown` / `otherMouseUp` to the
    /// reporting path and that the point maps to the claimed cell. If this
    /// fails, the side-button tests below say nothing.
    func test_control_middleClick_isReportedAsButton1_pressThenRelease() throws {
        let rig = try makeRig(decset: click1000SGR, expectSGR: true, expectedProtocol: .mouseReportClick)
        let p = point(row: downRow, col: downCol, in: rig.view)

        rig.view.otherMouseDown(with: try otherMouseEvent(.otherMouseDown, button: middleButton, at: p))
        XCTAssertEqual(
            pty(rig.recorder),
            sgrReport(code: 1, row: downRow, col: downCol, press: true),
            "a genuine middle-button press under ?1000h/?1006h must emit exactly one SGR "
            + "button-1 press naming the clicked cell"
        )

        rig.view.otherMouseUp(with: try otherMouseEvent(.otherMouseUp, button: middleButton, at: p))
        XCTAssertEqual(
            pty(rig.recorder),
            sgrReport(code: 1, row: downRow, col: downCol, press: true)
                + sgrReport(code: 1, row: downRow, col: downCol, press: false),
            "the middle-button release must add exactly one SGR button-1 release for the same cell"
        )
    }

    /// Control for the drag tests: a real middle-button drag under ?1002h is
    /// reported as press (1), motion with the middle button held (33), release
    /// (1). If the rig could not produce motion reports for `otherMouseDragged`
    /// at all, the side-button drag test would pass vacuously.
    func test_control_middleDrag_1002_isReportedAsButton1_withButton33Motion() throws {
        let rig = try makeRig(decset: drag1002SGR, expectSGR: true, expectedProtocol: .mouseDrag)
        let down = point(row: downRow, col: downCol, in: rig.view)
        let moved = point(row: downRow, col: dragCol, in: rig.view)

        rig.view.otherMouseDown(with: try otherMouseEvent(.otherMouseDown, button: middleButton, at: down))
        rig.view.otherMouseDragged(with: try otherMouseEvent(.otherMouseDragged, button: middleButton, at: moved))
        rig.view.otherMouseUp(with: try otherMouseEvent(.otherMouseUp, button: middleButton, at: moved))

        XCTAssertEqual(
            pty(rig.recorder),
            sgrReport(code: 1, row: downRow, col: downCol, press: true)
                + sgrReport(code: 33, row: downRow, col: dragCol, press: true)
                + sgrReport(code: 1, row: downRow, col: dragCol, press: false),
            "a middle-button drag under ?1002h/?1006h must be press(1), motion(33), release(1)"
        )
    }

    // MARK: - (2) Back / Forward clicks are not middle-clicks (SGR)

    private func runSideClick(
        button: Int,
        label: String,
        decset: String,
        expectedProtocol: BBTermMode,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let rig = try makeRig(
            decset: decset, expectSGR: true, expectedProtocol: expectedProtocol,
            file: file, line: line
        )
        let p = point(row: downRow, col: downCol, in: rig.view)

        rig.view.otherMouseDown(with: try otherMouseEvent(.otherMouseDown, button: button, at: p, file: file, line: line))
        assertNoPlainButtonReports(rig.recorder, gesture: "\(label) press", file: file, line: line)

        rig.view.otherMouseUp(with: try otherMouseEvent(.otherMouseUp, button: button, at: p, file: file, line: line))
        assertNoPlainButtonReports(rig.recorder, gesture: "\(label) press+release", file: file, line: line)
    }

    func test_backButtonClick_1000SGR_isNotReportedAsMiddleClick() throws {
        try runSideClick(
            button: backButton, label: "Back (button 3) click under ?1000h/?1006h",
            decset: click1000SGR, expectedProtocol: .mouseReportClick
        )
    }

    func test_forwardButtonClick_1000SGR_isNotReportedAsMiddleClick() throws {
        try runSideClick(
            button: forwardButton, label: "Forward (button 4) click under ?1000h/?1006h",
            decset: click1000SGR, expectedProtocol: .mouseReportClick
        )
    }

    func test_backButtonClick_1002SGR_isNotReportedAsMiddleClick() throws {
        try runSideClick(
            button: backButton, label: "Back (button 3) click under ?1002h/?1006h",
            decset: drag1002SGR, expectedProtocol: .mouseDrag
        )
    }

    func test_forwardButtonClick_1003SGR_isNotReportedAsMiddleClick() throws {
        try runSideClick(
            button: forwardButton, label: "Forward (button 4) click under ?1003h/?1006h",
            decset: any1003SGR, expectedProtocol: .mouseMotion
        )
    }

    // MARK: - (3) Legacy encoding: a side button cannot be named, so say nothing

    /// Control for the legacy tests: a genuine middle click under the legacy
    /// encoding is `ESC [ M` + (32+1) + (32+col+1) + (32+row+1) for the press
    /// and `ESC [ M` + (32+3) + … for the release (legacy encodings have a
    /// single "release" code). At (row 2, col 2) both coordinate bytes are
    /// 35 = `#`.
    func test_control_middleClick_legacyEncoding_isReportedAsButton1() throws {
        let rig = try makeRig(decset: click1000Legacy, expectSGR: false, expectedProtocol: .mouseReportClick)
        let p = point(row: downRow, col: downCol, in: rig.view)

        rig.view.otherMouseDown(with: try otherMouseEvent(.otherMouseDown, button: middleButton, at: p))
        rig.view.otherMouseUp(with: try otherMouseEvent(.otherMouseUp, button: middleButton, at: p))

        XCTAssertEqual(
            pty(rig.recorder),
            "<ESC>[M!##" + "<ESC>[M###",
            "a genuine middle click under legacy ?1000h must be press 'ESC [ M ! # #' (button 1) "
            + "then release 'ESC [ M # # #'"
        )
    }

    func test_backButtonClick_1000Legacy_emitsNothing() throws {
        let rig = try makeRig(decset: click1000Legacy, expectSGR: false, expectedProtocol: .mouseReportClick)
        let p = point(row: downRow, col: downCol, in: rig.view)

        rig.view.otherMouseDown(with: try otherMouseEvent(.otherMouseDown, button: backButton, at: p))
        rig.view.otherMouseUp(with: try otherMouseEvent(.otherMouseUp, button: backButton, at: p))

        XCTAssertEqual(
            pty(rig.recorder), "",
            "a Back-button click under the legacy encoding cannot be named in that protocol, so "
            + "nothing may be sent (a middle press 'ESC [ M ! # #' fires <MiddleMouse>)"
        )
    }

    func test_forwardButtonClick_1000Legacy_emitsNothing() throws {
        let rig = try makeRig(decset: click1000Legacy, expectSGR: false, expectedProtocol: .mouseReportClick)
        let p = point(row: downRow, col: downCol, in: rig.view)

        rig.view.otherMouseDown(with: try otherMouseEvent(.otherMouseDown, button: forwardButton, at: p))
        rig.view.otherMouseUp(with: try otherMouseEvent(.otherMouseUp, button: forwardButton, at: p))

        XCTAssertEqual(
            pty(rig.recorder), "",
            "a Forward-button click under the legacy encoding cannot be named in that protocol, so "
            + "nothing may be sent (a middle press 'ESC [ M ! # #' fires <MiddleMouse>)"
        )
    }

    // MARK: - (4) Dragging with a side button held

    private func runSideDrag(
        button: Int,
        label: String,
        decset: String,
        expectedProtocol: BBTermMode,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let rig = try makeRig(
            decset: decset, expectSGR: true, expectedProtocol: expectedProtocol,
            file: file, line: line
        )
        let down = point(row: downRow, col: downCol, in: rig.view)
        let moved = point(row: downRow, col: dragCol, in: rig.view)

        rig.view.otherMouseDown(with: try otherMouseEvent(.otherMouseDown, button: button, at: down, file: file, line: line))
        rig.view.otherMouseDragged(with: try otherMouseEvent(.otherMouseDragged, button: button, at: moved, file: file, line: line))
        rig.view.otherMouseUp(with: try otherMouseEvent(.otherMouseUp, button: button, at: moved, file: file, line: line))

        assertNoPlainButtonReports(rig.recorder, gesture: label, file: file, line: line)
    }

    func test_backButtonDrag_1002SGR_emitsNoMiddleButtonMotion() throws {
        try runSideDrag(
            button: backButton, label: "Back (button 3) press-drag-release under ?1002h/?1006h",
            decset: drag1002SGR, expectedProtocol: .mouseDrag
        )
    }

    func test_forwardButtonDrag_1003SGR_emitsNoMiddleButtonMotion() throws {
        try runSideDrag(
            button: forwardButton, label: "Forward (button 4) press-drag-release under ?1003h/?1006h",
            decset: any1003SGR, expectedProtocol: .mouseMotion
        )
    }

    func test_backButtonDrag_1003Legacy_emitsNothing() throws {
        let rig = try makeRig(decset: any1003Legacy, expectSGR: false, expectedProtocol: .mouseMotion)
        let down = point(row: downRow, col: downCol, in: rig.view)
        let moved = point(row: downRow, col: dragCol, in: rig.view)

        rig.view.otherMouseDown(with: try otherMouseEvent(.otherMouseDown, button: backButton, at: down))
        rig.view.otherMouseDragged(with: try otherMouseEvent(.otherMouseDragged, button: backButton, at: moved))
        rig.view.otherMouseUp(with: try otherMouseEvent(.otherMouseUp, button: backButton, at: moved))

        XCTAssertEqual(
            pty(rig.recorder), "",
            "a Back-button press-drag-release under legacy ?1003h cannot be named in that protocol, "
            + "so nothing may be sent (a middle press, motion 'ESC [ M A …' and release all fire "
            + "mouse bindings)"
        )
    }
}
