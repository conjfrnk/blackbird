import XCTest
import AppKit
import Metal
@testable import Blackbird
import BBCore

/// Blind behaviour tests for the DIRECTION of the wheel when it is
/// forwarded to the application (xterm mouse reporting, and DEC 1007
/// "alternate scroll" cursor keys), written from the terminal / macOS
/// conventions without sight of the implementation.
///
/// **The convention under test.**
///  - AppKit has already applied the user's "natural scrolling" preference
///    by the time an event reaches the view: a POSITIVE
///    `NSEvent.scrollingDeltaY` always means "the viewport moves toward the
///    TOP of the document", i.e. the user wants to see OLDER content. It
///    is the same sign that, in normal mode, moves Blackbird's own
///    scrollback into history.
///  - xterm mouse reporting names that wish "wheel up" = button 64; the
///    opposite wish ("newer content", viewport toward the bottom) is
///    "wheel down" = button 65.
///  - With DEC 1007 on the alternate screen the same two wishes are the
///    Up arrow (`ESC [ A`, or `ESC O A` under DECCKM) and the Down arrow
///    (`ESC [ B` / `ESC O B`).
///
/// Therefore, for a given gesture:
///   `scrollingDeltaY > 0`  →  button 64  /  Up arrow
///   `scrollingDeltaY < 0`  →  button 65  /  Down arrow
/// regardless of whether the device is a classic wheel
/// (`hasPreciseScrollingDeltas == false`) or a trackpad (`true`), and
/// regardless of the mouse encoding (SGR 1006 vs the X10 fallback).
///
/// This suite deliberately asserts DIRECTION ONLY — never how many reports
/// or arrows one event produces (that is pinned elsewhere:
/// `AlternateScrollWheelBlindTests`, `WheelScrollAccumulatorBlindTests`).
/// It also contains a cross-check that ties the two worlds together on one
/// view: the very same event that moves local scrollback toward older
/// content (asserted as the reference) must be reported as button 64 once
/// the TUI turns mouse reporting on, and the mirrored event as 65.
///
/// **Event synthesis.** `NSEvent` has no scroll-wheel initializer, so
/// events come from
/// `CGEvent(scrollWheelEvent2Source:units:wheelCount:wheel1:wheel2:wheel3:)`
/// bridged through `NSEvent(cgEvent:)`. `.line` units bridge to a classic
/// event and `.pixel` units to a precise one; each event's
/// `hasPreciseScrollingDeltas` and `scrollingDeltaY` are asserted before
/// use, so a bridge change fails the fixture rather than a behaviour.
///
/// **Memory / time pre-flight** (per `feedback_test_memory_safety`):
///  - One 40 × 6 `BBTerm` per term rig (240 cells), `scrollback: 16`; the
///    session rig is one headless `TerminalSession` (no PTY, no child
///    process) resized to 40 × 6 and fed 40 short lines (~300 bytes).
///  - One 640 × 240 headless `TerminalView` per rig; never added to a
///    window, never drawn; no `NSWindow`, no `MainWindowController`.
///  - Precise events carry at most 4 × cellHeight points (~70) and the
///    per-event cap bounds the output at 64 reports; no runloop pumping,
///    no timers. Wall time is dominated by `MTLCreateSystemDefaultDevice()`.
final class WheelDirectionBlindTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        TestHostTermination.shared.register()
    }

    // MARK: - Constants

    private let buttonWheelTowardOlder = 64   // "wheel up"
    private let buttonWheelTowardNewer = 65   // "wheel down"

    private let esc: UInt8 = 0x1B

    /// Alt screen + click reporting + SGR encoding.
    private let sgrMouseOnAltScreen = "\u{1B}[?1049h\u{1B}[?1000h\u{1B}[?1006h"
    /// Click reporting + SGR encoding on the primary screen.
    private let sgrMousePrimary = "\u{1B}[?1000h\u{1B}[?1006h"
    /// What Claude Code's REPL sends on entry: alt screen, click reporting,
    /// button-event motion, any-event motion, SGR encoding.
    private let claudeCodePreamble =
        "\u{1B}[?1049h\u{1B}[?1000h\u{1B}[?1002h\u{1B}[?1003h\u{1B}[?1006h"
    /// Alt screen only: DEC 1007 is on by default, no mouse protocol.
    private let altScreenOnly = "\u{1B}[?1049h"

    // MARK: - Rig (BBTerm-backed snapshot)

    /// Held together so nothing is deallocated mid-test. `TerminalView.session`
    /// is `weak`, so the strong `session` here is load-bearing.
    private struct Rig {
        let view: TerminalView
        let term: BBTerm
        let session: TerminalSession
        let recorder: RecordingPTY
        let snapshot: BBSnapshot
    }

    private func makeRig(
        feeding setup: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> Rig {
        let device = try requireMetalDevice(file: file, line: line)
        let view = TerminalView(
            frame: NSRect(x: 0, y: 0, width: 640, height: 240),
            device: device
        )
        let term = try XCTUnwrap(
            BBTerm(size: .init(cols: 40, rows: 6), scrollback: 16),
            "BBTerm init failed", file: file, line: line
        )
        term.input(setup)
        let snapshot = try XCTUnwrap(term.snapshot(), "snapshot() returned nil", file: file, line: line)

        let session = TerminalSession.makeHeadlessForTests()
        view.session = session
        view.currentSnapshot = snapshot
        let recorder = RecordingPTY()
        view.ptyRecorderForTests = recorder
        return Rig(view: view, term: term, session: session, recorder: recorder, snapshot: snapshot)
    }

    // MARK: - Event synthesis

    /// Classic (non-precise) wheel event with the given notch delta.
    private func classic(
        notches: Int32,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> NSEvent {
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
        XCTAssertFalse(ev.modifierFlags.contains(.option),
                       "precondition: no Option (that is the local-scroll escape hatch)",
                       file: file, line: line)
        return ev
    }

    /// Precise (trackpad-style) event carrying `points` of vertical travel.
    private func precise(
        points: Int32,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> NSEvent {
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
        XCTAssertFalse(ev.modifierFlags.contains(.option),
                       "precondition: no Option (that is the local-scroll escape hatch)",
                       file: file, line: line)
        return ev
    }

    /// A trackpad swipe long enough to yield several whole lines whatever
    /// the point-per-line scale is (4 cell heights of finger travel).
    private func swipePoints(_ view: TerminalView) -> Int32 {
        Int32((view.metrics.cellHeight * 4).rounded(.up))
    }

    // MARK: - Byte oracles

    private func hex(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
    }

    private func sent(_ recorder: RecordingPTY) -> [UInt8] { [UInt8](recorder.sent) }

    /// One parsed SGR mouse report: `ESC [ < button ; col ; row (M|m)`.
    private struct SGRReport: Equatable {
        let button: Int
        let col: Int
        let row: Int
        let final: UInt8
    }

    /// Parses the recorded bytes as a pure stream of SGR mouse reports.
    /// Any byte that is not part of a well-formed report is itself a
    /// failure (the wheel must not leak anything else toward the shell).
    private func sgrReports(
        _ recorder: RecordingPTY,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> [SGRReport] {
        let bytes = sent(recorder)
        var out: [SGRReport] = []
        var i = 0
        func number(_ stop: UInt8) -> Int? {
            var value = 0
            var digits = 0
            while i < bytes.count, bytes[i] >= 0x30, bytes[i] <= 0x39 {
                value = value * 10 + Int(bytes[i] - 0x30)
                digits += 1
                i += 1
            }
            guard digits > 0, i < bytes.count, bytes[i] == stop else { return nil }
            i += 1
            return value
        }
        while i < bytes.count {
            let start = i
            guard bytes[i] == esc, i + 2 < bytes.count, bytes[i + 1] == 0x5B, bytes[i + 2] == 0x3C else {
                XCTFail("not an SGR mouse report at offset \(start): \(hex(bytes))", file: file, line: line)
                return out
            }
            i += 3
            guard let button = number(0x3B), let col = number(0x3B) else {
                XCTFail("malformed SGR report at offset \(start): \(hex(bytes))", file: file, line: line)
                return out
            }
            // Row digits are terminated by M or m, which `number` cannot
            // express as a single stop byte, so finish by hand.
            var row = 0
            var digits = 0
            while i < bytes.count, bytes[i] >= 0x30, bytes[i] <= 0x39 {
                row = row * 10 + Int(bytes[i] - 0x30)
                digits += 1
                i += 1
            }
            guard digits > 0, i < bytes.count, bytes[i] == 0x4D || bytes[i] == 0x6D else {
                XCTFail("malformed SGR report terminator at offset \(start): \(hex(bytes))", file: file, line: line)
                return out
            }
            out.append(SGRReport(button: button, col: col, row: row, final: bytes[i]))
            i += 1
        }
        return out
    }

    /// Parses the recorded bytes as X10-encoded mouse reports
    /// (`ESC [ M cb cx cy`) and returns each report's button code with the
    /// +32 bias removed.
    private func x10Buttons(
        _ recorder: RecordingPTY,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> [Int] {
        let bytes = sent(recorder)
        XCTAssertEqual(bytes.count % 6, 0,
                       "recorded \(bytes.count) bytes, not a whole number of 6-byte X10 reports: \(hex(bytes))",
                       file: file, line: line)
        var out: [Int] = []
        var i = 0
        while i + 6 <= bytes.count {
            if bytes[i] == esc, bytes[i + 1] == 0x5B, bytes[i + 2] == 0x4D {
                out.append(Int(bytes[i + 3]) - 32)
            } else {
                XCTFail("not an X10 mouse report at offset \(i): \(hex(Array(bytes[i..<i + 6])))",
                        file: file, line: line)
            }
            i += 6
        }
        return out
    }

    private enum Arrow: String { case up = "Up", down = "Down" }

    /// Parses the recorded bytes as a stream of 3-byte cursor-key sequences.
    /// `appCursor` selects `ESC O x` (DECCKM) over `ESC [ x`. Anything else
    /// is a failure.
    private func arrows(
        _ recorder: RecordingPTY,
        appCursor: Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> [Arrow] {
        let bytes = sent(recorder)
        XCTAssertEqual(bytes.count % 3, 0,
                       "recorded \(bytes.count) bytes, not a whole number of 3-byte arrow sequences: \(hex(bytes))",
                       file: file, line: line)
        let introducer: UInt8 = appCursor ? 0x4F : 0x5B
        var out: [Arrow] = []
        var i = 0
        while i + 3 <= bytes.count {
            let c = Array(bytes[i..<i + 3])
            if c[0] == esc, c[1] == introducer, c[2] == 0x41 {
                out.append(.up)
            } else if c[0] == esc, c[1] == introducer, c[2] == 0x42 {
                out.append(.down)
            } else {
                XCTFail("sequence at offset \(i) is \(hex(c)), expected \(appCursor ? "ESC O" : "ESC [") A/B",
                        file: file, line: line)
            }
            i += 3
        }
        return out
    }

    // MARK: - Assertions

    /// Every SGR report in the recorder must be the expected wheel button,
    /// and there must be at least one.
    private func assertSGRWheel(
        _ recorder: RecordingPTY,
        expect button: Int,
        _ gesture: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let reports = sgrReports(recorder, file: file, line: line)
        XCTAssertFalse(reports.isEmpty,
                       "\(gesture): expected at least one SGR wheel report, PTY bytes were [\(hex(sent(recorder)))]",
                       file: file, line: line)
        let buttons = reports.map(\.button)
        XCTAssertEqual(Set(buttons), [button],
                       "\(gesture): expected every report to be button \(button), measured buttons \(buttons)",
                       file: file, line: line)
    }

    private func assertArrowWheel(
        _ recorder: RecordingPTY,
        appCursor: Bool = false,
        expect arrow: Arrow,
        _ gesture: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let got = arrows(recorder, appCursor: appCursor, file: file, line: line)
        XCTAssertFalse(got.isEmpty,
                       "\(gesture): expected at least one arrow key, PTY bytes were [\(hex(sent(recorder)))]",
                       file: file, line: line)
        XCTAssertEqual(Set(got.map(\.rawValue)), [arrow.rawValue],
                       "\(gesture): expected every key to be \(arrow.rawValue), measured \(got.map(\.rawValue))",
                       file: file, line: line)
    }

    private func assertSGRMouseGate(
        _ rig: Rig,
        altScreen: Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let mode = rig.snapshot.termMode
        XCTAssertFalse(mode.isDisjoint(with: [.mouseReportClick, .mouseMotion, .mouseDrag]),
                       "precondition: a mouse-reporting protocol is active", file: file, line: line)
        XCTAssertTrue(mode.contains(.sgrMouse), "precondition: CSI ? 1006 h selects SGR encoding",
                      file: file, line: line)
        XCTAssertEqual(mode.contains(.altScreen), altScreen,
                       "precondition: alt screen is \(altScreen ? "on" : "off")", file: file, line: line)
        XCTAssertTrue(rig.view.mouseReportingEnabled(),
                      "precondition: the view agrees mouse reporting is on", file: file, line: line)
        XCTAssertTrue(rig.view.sgrMouseEnabled(),
                      "precondition: the view agrees SGR encoding is on", file: file, line: line)
    }

    private func assertAltScrollGate(
        _ rig: Rig,
        appCursor: Bool = false,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let mode = rig.snapshot.termMode
        XCTAssertTrue(mode.contains(.altScreen), "precondition: alt screen on", file: file, line: line)
        XCTAssertTrue(mode.contains(.alternateScroll), "precondition: DEC 1007 on (default)", file: file, line: line)
        XCTAssertTrue(mode.isDisjoint(with: [.mouseReportClick, .mouseMotion, .mouseDrag]),
                      "precondition: no mouse protocol (reporting would take precedence over 1007)",
                      file: file, line: line)
        XCTAssertEqual(mode.contains(.appCursor), appCursor,
                       "precondition: DECCKM is \(appCursor ? "on" : "off")", file: file, line: line)
    }

    // MARK: - 1. SGR mouse reporting, classic wheel

    /// Classic wheel notch toward OLDER content (+deltaY) is "wheel up".
    func test_sgrReporting_classicWheelTowardOlder_reportsButton64() throws {
        let rig = try makeRig(feeding: sgrMousePrimary)
        assertSGRMouseGate(rig, altScreen: false)
        rig.view.scrollWheel(with: try classic(notches: 1))
        assertSGRWheel(rig.recorder, expect: buttonWheelTowardOlder,
                       "classic wheel, scrollingDeltaY +1 (toward older content)")
    }

    /// Classic wheel notch toward NEWER content (-deltaY) is "wheel down".
    func test_sgrReporting_classicWheelTowardNewer_reportsButton65() throws {
        let rig = try makeRig(feeding: sgrMousePrimary)
        assertSGRMouseGate(rig, altScreen: false)
        rig.view.scrollWheel(with: try classic(notches: -1))
        assertSGRWheel(rig.recorder, expect: buttonWheelTowardNewer,
                       "classic wheel, scrollingDeltaY -1 (toward newer content)")
    }

    // MARK: - 2. SGR mouse reporting, trackpad

    func test_sgrReporting_trackpadTowardOlder_reportsButton64() throws {
        let rig = try makeRig(feeding: sgrMousePrimary)
        assertSGRMouseGate(rig, altScreen: false)
        rig.view.scrollWheel(with: try precise(points: swipePoints(rig.view)))
        assertSGRWheel(rig.recorder, expect: buttonWheelTowardOlder,
                       "trackpad swipe, positive scrollingDeltaY (toward older content)")
    }

    func test_sgrReporting_trackpadTowardNewer_reportsButton65() throws {
        let rig = try makeRig(feeding: sgrMousePrimary)
        assertSGRMouseGate(rig, altScreen: false)
        rig.view.scrollWheel(with: try precise(points: -swipePoints(rig.view)))
        assertSGRWheel(rig.recorder, expect: buttonWheelTowardNewer,
                       "trackpad swipe, negative scrollingDeltaY (toward newer content)")
    }

    // MARK: - 3. Claude Code's real preamble (alt screen + 1000/1002/1003/1006)

    /// The configuration the headline user hits: a REPL that holds the alt
    /// screen and every mouse mode. Both gestures, both device kinds, in
    /// one session so a stateful bug (accumulator remainder, mode latch)
    /// cannot hide behind a fresh rig per direction.
    func test_claudeCodePreamble_bothDirections_bothDevices() throws {
        let rig = try makeRig(feeding: claudeCodePreamble)
        assertSGRMouseGate(rig, altScreen: true)
        XCTAssertTrue(rig.snapshot.termMode.contains(.mouseMotion),
                      "precondition: 1003 (last protocol set) survives the preamble")
        let swipe = swipePoints(rig.view)

        rig.view.scrollWheel(with: try classic(notches: 1))
        assertSGRWheel(rig.recorder, expect: buttonWheelTowardOlder, "classic +1 under the Claude Code preamble")
        rig.recorder.sent = Data()

        rig.view.scrollWheel(with: try classic(notches: -1))
        assertSGRWheel(rig.recorder, expect: buttonWheelTowardNewer, "classic -1 under the Claude Code preamble")
        rig.recorder.sent = Data()

        rig.view.scrollWheel(with: try precise(points: swipe))
        assertSGRWheel(rig.recorder, expect: buttonWheelTowardOlder, "trackpad + under the Claude Code preamble")
        rig.recorder.sent = Data()

        rig.view.scrollWheel(with: try precise(points: -swipe))
        assertSGRWheel(rig.recorder, expect: buttonWheelTowardNewer, "trackpad - under the Claude Code preamble")
    }

    // MARK: - 4. X10 fallback encoding (no CSI ? 1006 h)

    func test_x10Reporting_classicWheelTowardOlder_reportsButton64() throws {
        let rig = try makeRig(feeding: "\u{1B}[?1000h")
        XCTAssertFalse(rig.snapshot.termMode.contains(.sgrMouse), "precondition: SGR encoding is NOT selected")
        XCTAssertTrue(rig.view.mouseReportingEnabled(), "precondition: mouse reporting on")
        rig.view.scrollWheel(with: try classic(notches: 1))
        let buttons = x10Buttons(rig.recorder)
        XCTAssertFalse(buttons.isEmpty, "expected at least one X10 wheel report, PTY bytes were [\(hex(sent(rig.recorder)))]")
        XCTAssertEqual(Set(buttons), [buttonWheelTowardOlder],
                       "X10 encoding, classic +1 (toward older): expected every cb-32 to be 64, measured \(buttons)")
    }

    func test_x10Reporting_classicWheelTowardNewer_reportsButton65() throws {
        let rig = try makeRig(feeding: "\u{1B}[?1000h")
        XCTAssertFalse(rig.snapshot.termMode.contains(.sgrMouse), "precondition: SGR encoding is NOT selected")
        XCTAssertTrue(rig.view.mouseReportingEnabled(), "precondition: mouse reporting on")
        rig.view.scrollWheel(with: try classic(notches: -1))
        let buttons = x10Buttons(rig.recorder)
        XCTAssertFalse(buttons.isEmpty, "expected at least one X10 wheel report, PTY bytes were [\(hex(sent(rig.recorder)))]")
        XCTAssertEqual(Set(buttons), [buttonWheelTowardNewer],
                       "X10 encoding, classic -1 (toward newer): expected every cb-32 to be 65, measured \(buttons)")
    }

    // MARK: - 5. DEC 1007 alternate scroll (alt screen, no mouse protocol)

    func test_alternateScroll_classicWheelTowardOlder_sendsUpArrow() throws {
        let rig = try makeRig(feeding: altScreenOnly)
        assertAltScrollGate(rig)
        rig.view.scrollWheel(with: try classic(notches: 1))
        assertArrowWheel(rig.recorder, expect: .up, "classic wheel, scrollingDeltaY +1 (toward older content)")
    }

    func test_alternateScroll_classicWheelTowardNewer_sendsDownArrow() throws {
        let rig = try makeRig(feeding: altScreenOnly)
        assertAltScrollGate(rig)
        rig.view.scrollWheel(with: try classic(notches: -1))
        assertArrowWheel(rig.recorder, expect: .down, "classic wheel, scrollingDeltaY -1 (toward newer content)")
    }

    func test_alternateScroll_trackpadTowardOlder_sendsUpArrow() throws {
        let rig = try makeRig(feeding: altScreenOnly)
        assertAltScrollGate(rig)
        rig.view.scrollWheel(with: try precise(points: swipePoints(rig.view)))
        assertArrowWheel(rig.recorder, expect: .up, "trackpad swipe, positive scrollingDeltaY (toward older content)")
    }

    func test_alternateScroll_trackpadTowardNewer_sendsDownArrow() throws {
        let rig = try makeRig(feeding: altScreenOnly)
        assertAltScrollGate(rig)
        rig.view.scrollWheel(with: try precise(points: -swipePoints(rig.view)))
        assertArrowWheel(rig.recorder, expect: .down, "trackpad swipe, negative scrollingDeltaY (toward newer content)")
    }

    // MARK: - 6. DEC 1007 under DECCKM (application cursor keys)

    func test_alternateScroll_appCursor_towardOlder_sendsSS3Up() throws {
        let rig = try makeRig(feeding: altScreenOnly + "\u{1B}[?1h")
        assertAltScrollGate(rig, appCursor: true)
        rig.view.scrollWheel(with: try classic(notches: 1))
        assertArrowWheel(rig.recorder, appCursor: true, expect: .up,
                         "classic wheel +1 under DECCKM (toward older content)")
    }

    func test_alternateScroll_appCursor_towardNewer_sendsSS3Down() throws {
        let rig = try makeRig(feeding: altScreenOnly + "\u{1B}[?1h")
        assertAltScrollGate(rig, appCursor: true)
        rig.view.scrollWheel(with: try classic(notches: -1))
        assertArrowWheel(rig.recorder, appCursor: true, expect: .down,
                         "classic wheel -1 under DECCKM (toward newer content)")
    }

    // MARK: - 7. Same gesture as local scrollback

    /// Everything the cross-check needs on ONE view: a headless session
    /// with real history so the same event can first move local scrollback
    /// (the reference) and then be reported to a mouse-capturing TUI.
    private struct SessionRig {
        let view: TerminalView
        let session: TerminalSession
        let recorder: RecordingPTY
        /// Sign of the `session.scroll(delta:)` argument that INCREASES
        /// `displayOffset` (moves into history). Probed, not assumed.
        let intoHistorySign: Int
    }

    private static let parkedOffset = 10
    private static let historyLinesFed = 40

    private func displayOffset(
        _ session: TerminalSession,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> Int {
        try XCTUnwrap(session.takeSnapshotForTests(), "takeSnapshotForTests() returned nil",
                      file: file, line: line).displayOffset
    }

    private func makeSessionRig(file: StaticString = #filePath, line: UInt = #line) throws -> SessionRig {
        let device = try requireMetalDevice(file: file, line: line)
        let view = TerminalView(
            frame: NSRect(x: 0, y: 0, width: 640, height: 240),
            device: device
        )
        let session = TerminalSession.makeHeadlessForTests()
        session.resize(to: .init(cols: 40, rows: 6))
        var feed = ""
        for n in 1...Self.historyLinesFed { feed += "line \(n)\r\n" }
        session.feedBytesForTests(Data(feed.utf8))

        view.session = session
        let recorder = RecordingPTY()
        view.ptyRecorderForTests = recorder

        let snap = try XCTUnwrap(session.takeSnapshotForTests(), "takeSnapshotForTests() returned nil",
                                 file: file, line: line)
        XCTAssertEqual(snap.rows, 6, "precondition: grid resized to 6 rows", file: file, line: line)
        XCTAssertGreaterThanOrEqual(snap.historySize, Self.parkedOffset * 2 + 4,
                                    "precondition: enough history to park mid-way with headroom",
                                    file: file, line: line)
        XCTAssertEqual(snap.displayOffset, 0, "precondition: fresh session is pinned to the bottom",
                       file: file, line: line)
        XCTAssertFalse(snap.termMode.contains(.altScreen), "precondition: primary screen", file: file, line: line)
        XCTAssertTrue(snap.termMode.isDisjoint(with: [.mouseReportClick, .mouseMotion, .mouseDrag]),
                      "precondition: no mouse protocol yet", file: file, line: line)
        view.render(snapshot: snap)

        // Probe which sign of scroll(delta:) moves into history.
        session.scroll(delta: Int32(Self.parkedOffset))
        var intoHistorySign = 1
        if try displayOffset(session, file: file, line: line) == 0 {
            session.scroll(delta: -Int32(Self.parkedOffset))
            intoHistorySign = -1
        }
        XCTAssertEqual(try displayOffset(session, file: file, line: line), Self.parkedOffset,
                       "precondition: session.scroll(delta:) parks the viewport \(Self.parkedOffset) lines into history",
                       file: file, line: line)
        return SessionRig(view: view, session: session, recorder: recorder, intoHistorySign: intoHistorySign)
    }

    private func repark(_ rig: SessionRig, file: StaticString = #filePath, line: UInt = #line) throws {
        let now = try displayOffset(rig.session, file: file, line: line)
        let delta = (Self.parkedOffset - now) * rig.intoHistorySign
        if delta != 0 { rig.session.scroll(delta: Int32(delta)) }
        XCTAssertEqual(try displayOffset(rig.session, file: file, line: line), Self.parkedOffset,
                       "fixture: viewport re-parked", file: file, line: line)
    }

    /// Switches the TUI's mouse reporting on through the real parser and
    /// hands the view the resulting snapshot.
    private func enableSGRMouseReporting(_ rig: SessionRig, file: StaticString = #filePath, line: UInt = #line) throws {
        rig.session.feedBytesForTests(Data(sgrMousePrimary.utf8))
        let snap = try XCTUnwrap(rig.session.takeSnapshotForTests(), "takeSnapshotForTests() returned nil",
                                 file: file, line: line)
        XCTAssertTrue(snap.termMode.contains(.sgrMouse), "precondition: SGR encoding on", file: file, line: line)
        XCTAssertFalse(snap.termMode.isDisjoint(with: [.mouseReportClick, .mouseMotion, .mouseDrag]),
                       "precondition: a mouse protocol on", file: file, line: line)
        rig.view.currentSnapshot = snap
        XCTAssertTrue(rig.view.mouseReportingEnabled(),
                      "precondition: the view sees mouse reporting on", file: file, line: line)
    }

    /// The gesture that scrolls Blackbird's OWN scrollback toward older
    /// content must be reported as button 64 once the TUI captures the
    /// wheel — same event, same view, same device kind.
    func test_sameGestureThatScrollsScrollbackTowardOlder_isReportedAsButton64() throws {
        let rig = try makeSessionRig()
        let points = swipePoints(rig.view)

        // Reference: in normal mode the positive-deltaY swipe moves the
        // viewport INTO history (older content) and writes nothing.
        rig.view.scrollWheel(with: try precise(points: points))
        let after = try displayOffset(rig.session)
        XCTAssertGreaterThan(after, Self.parkedOffset,
                             "reference: a positive-deltaY swipe in normal mode must scroll local scrollback toward OLDER content (displayOffset \(Self.parkedOffset) -> \(after))")
        XCTAssertTrue(rig.recorder.sent.isEmpty,
                      "reference: normal-mode wheel must not write to the PTY; got [\(hex(sent(rig.recorder)))]")

        // Same view, same event kind, but now the TUI owns the wheel.
        try repark(rig)
        try enableSGRMouseReporting(rig)
        rig.view.scrollWheel(with: try precise(points: points))
        assertSGRWheel(rig.recorder, expect: buttonWheelTowardOlder,
                       "the swipe that scrolled local scrollback toward older content, now under mouse reporting")
    }

    /// Mirror image: the gesture that scrolls local scrollback toward NEWER
    /// content is button 65 under mouse reporting.
    func test_sameGestureThatScrollsScrollbackTowardNewer_isReportedAsButton65() throws {
        let rig = try makeSessionRig()
        let points = swipePoints(rig.view)

        rig.view.scrollWheel(with: try precise(points: -points))
        let after = try displayOffset(rig.session)
        XCTAssertLessThan(after, Self.parkedOffset,
                          "reference: a negative-deltaY swipe in normal mode must scroll local scrollback toward NEWER content (displayOffset \(Self.parkedOffset) -> \(after))")
        XCTAssertTrue(rig.recorder.sent.isEmpty,
                      "reference: normal-mode wheel must not write to the PTY; got [\(hex(sent(rig.recorder)))]")

        try repark(rig)
        try enableSGRMouseReporting(rig)
        rig.view.scrollWheel(with: try precise(points: -points))
        assertSGRWheel(rig.recorder, expect: buttonWheelTowardNewer,
                       "the swipe that scrolled local scrollback toward newer content, now under mouse reporting")
    }
}
