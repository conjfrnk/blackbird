import XCTest
import AppKit
import Metal
@testable import Blackbird
import BBCore

/// Shift / Ctrl modifier bits in xterm mouse reports.
///
/// **The bug this suite exists for.** A TUI that enables mouse reporting
/// (`vim -c 'set mouse=a'`, tmux `mouse on`, micro, helix) learns about the
/// pointer through the xterm mouse protocol. That protocol does not only
/// carry the button: the report's button code (`Cb`) is
///
///     Cb = button + 4·Shift + 8·Meta + 16·Ctrl (+ 32 if this is motion)
///
/// in both the SGR (`?1006`) encoding (`ESC [ < Cb ; col ; row M/m`) and the
/// legacy X10/normal encoding (`ESC [ M (32+Cb) (32+col) (32+row)`). That is
/// how nvim distinguishes `<LeftMouse>` from `<S-LeftMouse>` (extend the
/// selection), `<C-RightMouse>`, `<S-ScrollWheel>` / `<C-ScrollWheel>`
/// (page scrolling), and how tmux copy-mode and micro/helix implement
/// shift-click selection extension.
///
/// A terminal that sends the same bytes for a Shift-click as for a plain
/// click silently disables every one of those gestures: the TUI sees a plain
/// click (selection collapses) and the user has no way to produce the
/// modified gesture. Ctrl+click is the macOS spelling of a secondary click:
/// AppKit delivers it as `rightMouseDown` with `.control` in
/// `modifierFlags`, so the matching report is button 2 + 16 = 18, i.e. what a
/// TUI calls `<C-RightMouse>`.
///
/// **The contract pinned here** (decided from the xterm protocol, not from
/// Blackbird's current code):
///
///  - Shift + left click, SGR: press `ESC [ < 4 ; c ; r M`, release
///    `ESC [ < 4 ; c ; r m` (never `0`).
///  - Shift + left click, legacy X10: the press byte is `32 + 4 = '$'`.
///  - Ctrl + (right-button, as macOS delivers Ctrl+click) click, SGR: press
///    code `2 + 16 = 18`, release code 18.
///  - Shift + left drag under `?1002`: press 4, motion `32 + 4 = 36`,
///    release 4.
///  - Ctrl + right drag under `?1002`: press 18 and release 18; any motion
///    report in between is `32 + 2 + 16 = 50`. (Motion for the right button
///    is tolerated-but-optional: today an unmodified right drag emits no
///    motion at all, which is a separate matter from the modifier bits.)
///  - Ctrl + wheel: `64 + 16 = 80`.
///
/// The unmodified versions of every gesture are pinned as controls (they pass
/// today): they prove the rig delivers each event type to the reporting path
/// and that the claimed cell is the reported cell, so the modified-gesture
/// failures can only be about the modifier bits.
///
/// Not pinned, deliberately: Option/Meta (Option is Blackbird's documented
/// reporting bypass); the modifier bits on the legacy-encoding RELEASE byte
/// (xterm keeps them, but the legacy release is a lossy `3` code and
/// reasonable encoders differ); and Shift + wheel — macOS turns a Shift'd
/// vertical wheel into a HORIZONTAL scroll (the CGEvent -> NSEvent bridge
/// reports `scrollingDeltaY == 0` for it), so there is no vertical Shift+wheel
/// event to assert on.
///
/// **Event synthesis.** Mouse events come from `NSEvent.mouseEvent(with:…)`
/// with the modifier flags passed in, which also yields the right event type
/// per button (left vs right). Wheel events come from an unposted
/// `CGEvent(scrollWheelEvent2Source:…)` with `flags` set, bridged through
/// `NSEvent(cgEvent:)` — the same technique `WheelDirectionBlindTests` uses.
/// Nothing is posted to the window server, so this is not event injection and
/// nothing can route back to the outer terminal. Each event's `type`,
/// `modifierFlags` and (wheel) `scrollingDeltaY` are asserted before use.
///
/// **Geometry.** The view is never added to a window, so its frame origin is
/// (0, 0) and `locationInWindow` equals the view-local point. The unmodified
/// control asserts the report names the cell the test claims to have clicked.
///
/// **Memory / time pre-flight** (per `feedback_test_memory_safety`):
///  - One 60 × 8 `BBTerm` per rig — 480 cells, a few KB — `scrollback: 16`.
///  - One 800 × 480 headless `TerminalView` per rig; never added to a window,
///    never shown, never drawn. No `NSWindow`, no `MainWindowController`, no
///    PTY, no shell. `TerminalSession.makeHeadlessForTests()` has no pty, so
///    only the `RecordingPTY` observes writes.
///  - No runloop pumping, no timers. Wall time is dominated by
///    `MTLCreateSystemDefaultDevice()`.
final class MouseModifierBitsReportBlindTests: XCTestCase {

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

    // MARK: - Mouse-mode preambles

    /// Click reporting (DEC 1000) + SGR encoding.
    private let click1000SGR = "\u{1B}[?1000h\u{1B}[?1006h"
    /// Button-event tracking (DEC 1002) + SGR encoding.
    private let drag1002SGR = "\u{1B}[?1002h\u{1B}[?1006h"
    /// Click reporting with the legacy (X10 / normal) encoding: no `?1006`.
    private let click1000Legacy = "\u{1B}[?1000h"

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
        // reporting OFF and the modified-gesture assertions would fail for
        // the wrong reason (or, for the controls, pass vacuously).
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

    /// A left- or right-button mouse event at `p` carrying `modifiers`.
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
            held.contains(.shift), modifiers.contains(.shift),
            "precondition: Shift state must survive event construction (flags \(held.rawValue))",
            file: file, line: line
        )
        XCTAssertEqual(
            held.contains(.control), modifiers.contains(.control),
            "precondition: Control state must survive event construction (flags \(held.rawValue))",
            file: file, line: line
        )
        XCTAssertFalse(
            held.contains(.option),
            "precondition: Option is the reporting bypass and must not be held",
            file: file, line: line
        )
        XCTAssertFalse(
            held.contains(.command),
            "precondition: Command is the link / window-drag modifier and must not be held",
            file: file, line: line
        )
        return ev
    }

    /// A classic (line-unit) wheel event of `notches` carrying `flags`.
    private func wheelEvent(
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
        XCTAssertEqual(
            ev.type, .scrollWheel,
            "precondition: bridged event must be a scroll wheel", file: file, line: line
        )
        XCTAssertEqual(
            ev.scrollingDeltaY, Double(notches), accuracy: 1e-9,
            "precondition: scrollingDeltaY must bridge 1:1 from wheel1 for .line units",
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
            held.contains(.option),
            "precondition: no Option (that is the local-scroll escape hatch)",
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

    private struct SGRReport: Equatable, CustomStringConvertible {
        let code: Int
        let col: Int
        let row: Int
        let press: Bool
        var description: String {
            "<ESC>[<\(code);\(col);\(row)\(press ? "M" : "m")"
        }
    }

    /// Parse the recorded stream as a sequence of SGR mouse reports.
    /// Leftover (unparsed) bytes are asserted empty so a stray byte cannot
    /// hide from the assertions.
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

    /// A right-button press / drag / release as the TUI saw it: the first
    /// report must be the `press` code at the down cell, the last must be the
    /// `release` code at the drop cell, and any report in between (motion) must
    /// be the `motion` code at press-state `M`. Motion for the right button is
    /// optional (see the class comment), so the middle may be empty.
    private func assertRightDragStream(
        _ recorder: RecordingPTY,
        press: Int,
        motion: Int,
        release: Int,
        gesture: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let reports = sgrReports(recorder, file: file, line: line)
        let stream = pty(recorder)
        guard reports.count >= 2 else {
            XCTFail("\(gesture): expected at least a press and a release report; stream: \(stream)",
                    file: file, line: line)
            return
        }
        XCTAssertEqual(
            reports.first?.description,
            SGRReport(code: press, col: downCol + 1, row: downRow + 1, press: true).description,
            "\(gesture): first report must be the press (code \(press)); stream: \(stream)",
            file: file, line: line
        )
        XCTAssertEqual(
            reports.last?.description,
            SGRReport(code: release, col: dragCol + 1, row: downRow + 1, press: false).description,
            "\(gesture): last report must be the release (code \(release)); stream: \(stream)",
            file: file, line: line
        )
        let middle: [SGRReport] = Array(reports.dropFirst().dropLast())
        XCTAssertEqual(
            middle.map { (r: SGRReport) -> Int in r.code }.filter { $0 != motion },
            [],
            "\(gesture): any motion report between press and release must be code \(motion); "
            + "stream: \(stream)",
            file: file, line: line
        )
    }

    // MARK: - Controls: unmodified gestures report plain codes

    /// Also the geometry control for the whole file: the asserted report
    /// names `col + 1 = 3` and `row + 1 = 3`, which is only true if the point
    /// built by `point(row: 2, col: 2, in:)` really maps to grid cell (2, 2).
    func test_control_plainLeftClick_1000SGR_isCode0() throws {
        let rig = try makeRig(decset: click1000SGR, expectSGR: true, expectedProtocol: .mouseReportClick)
        let p = point(row: downRow, col: downCol, in: rig.view)

        rig.view.mouseDown(with: try mouseEvent(.leftMouseDown, at: p, modifiers: [], timestamp: 1.0))
        rig.view.mouseUp(with: try mouseEvent(.leftMouseUp, at: p, modifiers: [], timestamp: 1.01))

        XCTAssertEqual(
            pty(rig.recorder),
            sgrReport(code: 0, row: downRow, col: downCol, press: true)
                + sgrReport(code: 0, row: downRow, col: downCol, press: false),
            "an unmodified left click under ?1000h/?1006h must be press(0) then release(0) "
            + "naming the clicked cell"
        )
    }

    func test_control_plainRightClick_1000SGR_isCode2() throws {
        let rig = try makeRig(decset: click1000SGR, expectSGR: true, expectedProtocol: .mouseReportClick)
        let p = point(row: downRow, col: downCol, in: rig.view)

        rig.view.rightMouseDown(with: try mouseEvent(.rightMouseDown, at: p, modifiers: [], timestamp: 1.0))
        rig.view.rightMouseUp(with: try mouseEvent(.rightMouseUp, at: p, modifiers: [], timestamp: 1.01))

        XCTAssertEqual(
            pty(rig.recorder),
            sgrReport(code: 2, row: downRow, col: downCol, press: true)
                + sgrReport(code: 2, row: downRow, col: downCol, press: false),
            "an unmodified right click under ?1000h/?1006h must be press(2) then release(2)"
        )
    }

    func test_control_plainLeftDrag_1002SGR_isCode0_withMotion32() throws {
        let rig = try makeRig(decset: drag1002SGR, expectSGR: true, expectedProtocol: .mouseDrag)
        let down = point(row: downRow, col: downCol, in: rig.view)
        let moved = point(row: downRow, col: dragCol, in: rig.view)

        rig.view.mouseDown(with: try mouseEvent(.leftMouseDown, at: down, modifiers: [], timestamp: 1.0))
        rig.view.mouseDragged(with: try mouseEvent(.leftMouseDragged, at: moved, modifiers: [], timestamp: 1.01))
        rig.view.mouseUp(with: try mouseEvent(.leftMouseUp, at: moved, modifiers: [], timestamp: 1.02))

        XCTAssertEqual(
            pty(rig.recorder),
            sgrReport(code: 0, row: downRow, col: downCol, press: true)
                + sgrReport(code: 32, row: downRow, col: dragCol, press: true)
                + sgrReport(code: 0, row: downRow, col: dragCol, press: false),
            "an unmodified left drag under ?1002h/?1006h must be press(0), motion(32), release(0)"
        )
    }

    /// Control for the Ctrl+right-drag test: proves the rig delivers
    /// `rightMouseDragged` / `rightMouseUp` to the reporting path and the
    /// press/release land on the claimed cells.
    func test_control_plainRightDrag_1002SGR_isCode2() throws {
        let rig = try makeRig(decset: drag1002SGR, expectSGR: true, expectedProtocol: .mouseDrag)
        let down = point(row: downRow, col: downCol, in: rig.view)
        let moved = point(row: downRow, col: dragCol, in: rig.view)

        rig.view.rightMouseDown(with: try mouseEvent(.rightMouseDown, at: down, modifiers: [], timestamp: 1.0))
        rig.view.rightMouseDragged(with: try mouseEvent(.rightMouseDragged, at: moved, modifiers: [], timestamp: 1.01))
        rig.view.rightMouseUp(with: try mouseEvent(.rightMouseUp, at: moved, modifiers: [], timestamp: 1.02))

        assertRightDragStream(
            rig.recorder, press: 2, motion: 34, release: 2,
            gesture: "unmodified right drag under ?1002h/?1006h"
        )
    }

    func test_control_plainWheelUp_1000SGR_isCode64() throws {
        let rig = try makeRig(decset: click1000SGR, expectSGR: true, expectedProtocol: .mouseReportClick)

        rig.view.scrollWheel(with: try wheelEvent(notches: 1, flags: []))

        let codes = sgrCodes(rig.recorder)
        XCTAssertFalse(
            codes.isEmpty,
            "an unmodified wheel notch toward older content must produce at least one report; "
            + "PTY bytes: \(pty(rig.recorder))"
        )
        XCTAssertEqual(
            Set(codes), [64],
            "every unmodified wheel-up report must be button 64; measured codes \(codes)"
        )
    }

    // MARK: - Shift + click

    func test_shiftLeftClick_1000SGR_carriesShiftBit() throws {
        let rig = try makeRig(decset: click1000SGR, expectSGR: true, expectedProtocol: .mouseReportClick)
        let p = point(row: downRow, col: downCol, in: rig.view)

        rig.view.mouseDown(with: try mouseEvent(.leftMouseDown, at: p, modifiers: [.shift], timestamp: 1.0))
        XCTAssertEqual(
            pty(rig.recorder),
            sgrReport(code: 4, row: downRow, col: downCol, press: true),
            "Shift+left press under ?1000h/?1006h must be SGR code 0 + 4 (Shift) = 4 so the TUI "
            + "sees <S-LeftMouse>, not a plain click"
        )

        rig.view.mouseUp(with: try mouseEvent(.leftMouseUp, at: p, modifiers: [.shift], timestamp: 1.01))
        XCTAssertEqual(
            pty(rig.recorder),
            sgrReport(code: 4, row: downRow, col: downCol, press: true)
                + sgrReport(code: 4, row: downRow, col: downCol, press: false),
            "Shift+left release must carry the Shift bit too (code 4, final 'm')"
        )
    }

    func test_shiftLeftClick_1000Legacy_pressCarriesShiftBit() throws {
        let rig = try makeRig(decset: click1000Legacy, expectSGR: false, expectedProtocol: .mouseReportClick)
        let p = point(row: downRow, col: downCol, in: rig.view)

        rig.view.mouseDown(with: try mouseEvent(.leftMouseDown, at: p, modifiers: [.shift], timestamp: 1.0))

        // Cb = 32 + (0 + 4) = 36 = '$'; at (row 2, col 2) both coordinate
        // bytes are 32 + 3 = 35 = '#'.
        XCTAssertEqual(
            pty(rig.recorder),
            "<ESC>[M$##",
            "Shift+left press under legacy ?1000h must be ESC [ M '$' '#' '#' (Cb = 32 + 4); "
            + "(the plain-click bytes ESC [ M <space> # # mean the Shift bit was dropped)"
        )
    }

    // MARK: - Ctrl + click (macOS delivers it as the right button)

    func test_ctrlClick_deliveredAsRightMouse_1000SGR_carriesCtrlBit() throws {
        let rig = try makeRig(decset: click1000SGR, expectSGR: true, expectedProtocol: .mouseReportClick)
        let p = point(row: downRow, col: downCol, in: rig.view)

        rig.view.rightMouseDown(with: try mouseEvent(.rightMouseDown, at: p, modifiers: [.control], timestamp: 1.0))
        XCTAssertEqual(
            pty(rig.recorder),
            sgrReport(code: 18, row: downRow, col: downCol, press: true),
            "Ctrl+click arrives as rightMouseDown with .control; under ?1000h/?1006h the press "
            + "must be SGR code 2 + 16 (Ctrl) = 18 so the TUI sees <C-RightMouse>"
        )

        rig.view.rightMouseUp(with: try mouseEvent(.rightMouseUp, at: p, modifiers: [.control], timestamp: 1.01))
        XCTAssertEqual(
            pty(rig.recorder),
            sgrReport(code: 18, row: downRow, col: downCol, press: true)
                + sgrReport(code: 18, row: downRow, col: downCol, press: false),
            "the Ctrl+right release must carry the Ctrl bit too (code 18, final 'm')"
        )
    }

    // MARK: - Shift / Ctrl + drag

    func test_shiftLeftDrag_1002SGR_carriesShiftBitOnPressMotionAndRelease() throws {
        let rig = try makeRig(decset: drag1002SGR, expectSGR: true, expectedProtocol: .mouseDrag)
        let down = point(row: downRow, col: downCol, in: rig.view)
        let moved = point(row: downRow, col: dragCol, in: rig.view)

        rig.view.mouseDown(with: try mouseEvent(.leftMouseDown, at: down, modifiers: [.shift], timestamp: 1.0))
        rig.view.mouseDragged(with: try mouseEvent(.leftMouseDragged, at: moved, modifiers: [.shift], timestamp: 1.01))
        rig.view.mouseUp(with: try mouseEvent(.leftMouseUp, at: moved, modifiers: [.shift], timestamp: 1.02))

        XCTAssertEqual(
            pty(rig.recorder),
            sgrReport(code: 4, row: downRow, col: downCol, press: true)
                + sgrReport(code: 36, row: downRow, col: dragCol, press: true)
                + sgrReport(code: 4, row: downRow, col: dragCol, press: false),
            "Shift+left drag under ?1002h/?1006h must be press(4), motion(32 + 4 = 36), release(4)"
        )
    }

    func test_ctrlRightDrag_1002SGR_carriesCtrlBitOnPressMotionAndRelease() throws {
        let rig = try makeRig(decset: drag1002SGR, expectSGR: true, expectedProtocol: .mouseDrag)
        let down = point(row: downRow, col: downCol, in: rig.view)
        let moved = point(row: downRow, col: dragCol, in: rig.view)

        rig.view.rightMouseDown(with: try mouseEvent(.rightMouseDown, at: down, modifiers: [.control], timestamp: 1.0))
        rig.view.rightMouseDragged(with: try mouseEvent(.rightMouseDragged, at: moved, modifiers: [.control], timestamp: 1.01))
        rig.view.rightMouseUp(with: try mouseEvent(.rightMouseUp, at: moved, modifiers: [.control], timestamp: 1.02))

        assertRightDragStream(
            rig.recorder, press: 18, motion: 50, release: 18,
            gesture: "Ctrl+right drag under ?1002h/?1006h (press 2+16, motion 32+2+16, release 2+16)"
        )
    }

    // MARK: - Ctrl + wheel

    func test_ctrlWheelUp_1000SGR_isCode80() throws {
        let rig = try makeRig(decset: click1000SGR, expectSGR: true, expectedProtocol: .mouseReportClick)

        rig.view.scrollWheel(with: try wheelEvent(notches: 1, flags: .maskControl))

        let codes = sgrCodes(rig.recorder)
        XCTAssertFalse(
            codes.isEmpty,
            "a Ctrl+wheel notch must still be reported to the TUI; PTY bytes: \(pty(rig.recorder))"
        )
        XCTAssertEqual(
            Set(codes), [80],
            "Ctrl+wheel toward older content must be SGR code 64 + 16 = 80 (<C-ScrollWheelUp>); "
            + "measured codes \(codes)"
        )
    }
}
