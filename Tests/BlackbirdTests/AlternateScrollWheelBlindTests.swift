import XCTest
import AppKit
import Metal
@testable import Blackbird
import BBCore

/// Blind behaviour tests for DEC 1007 "alternate scroll" in
/// `TerminalView.scrollWheel`, written from the v0.8.1 spec without sight
/// of the implementation.
///
/// Contract under test: when the current snapshot's `termMode` has
/// `.altScreen` AND `.alternateScroll`, and NO mouse-reporting protocol bit
/// (`.mouseReportClick` / `.mouseMotion` / `.mouseDrag`), a classic wheel
/// event (`hasPreciseScrollingDeltas == false`) with `scrollingDeltaY == -1`
/// writes exactly three `ESC [ A` to the session and `+1` writes three
/// `ESC [ B`. With `.appCursor` the bytes are `ESC O A` / `ESC O B`.
/// Nothing is written when: Option is held; `.alternateScroll` is clear
/// (the TUI sent `CSI ? 1007 l`); `.altScreen` is clear; or a mouse protocol
/// is on. A single event never produces more than 64 arrow presses.
///
/// **Why a real `BBTerm`.** `termMode` is the gate under test, so every
/// bit is produced by feeding the real DECSET bytes to the real parser
/// rather than hand-assembling an `OptionSet` — the same authority the
/// product reads at runtime. Each rig asserts its preconditions so a
/// mistyped escape fails the fixture, not silently the behaviour.
///
/// **Event synthesis.** `NSEvent` has no scroll-wheel initializer, so
/// events come from
/// `CGEvent(scrollWheelEvent2Source:units:wheelCount:wheel1:wheel2:wheel3:)`
/// with `.line` units bridged through `NSEvent(cgEvent:)`. Each event's
/// `scrollingDeltaY` / `hasPreciseScrollingDeltas` are asserted before
/// use, so if the bridge ever changes scaling the fixture fails first.
///
/// **Memory / time pre-flight** (per `feedback_test_memory_safety`):
///  - One 40 × 6 `BBTerm` per rig (240 cells), `scrollback: 16`.
///  - One 640 × 240 headless `TerminalView` per rig; never added to a
///    window, never drawn; no `NSWindow`, no `MainWindowController`, no
///    PTY. `TerminalSession.makeHeadlessForTests()` has no pty, and
///    `ptyRecorderForTests` captures every byte the view would send.
///  - No runloop pumping, no timers. Wall time dominated by
///    `MTLCreateSystemDefaultDevice()`.
final class AlternateScrollWheelBlindTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        TestHostTermination.shared.register()
    }

    private let cursorUp: [UInt8] = [0x1B, 0x5B, 0x41]   // ESC [ A
    private let cursorDown: [UInt8] = [0x1B, 0x5B, 0x42] // ESC [ B
    private let appUp: [UInt8] = [0x1B, 0x4F, 0x41]      // ESC O A
    private let appDown: [UInt8] = [0x1B, 0x4F, 0x42]    // ESC O B

    // MARK: - Rig

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

    /// The "happy" fixture: alt screen on, 1007 at its default (on), no
    /// mouse protocol.
    private let altScreenOnly = "\u{1B}[?1049h"

    // MARK: - Event synthesis

    /// Classic (non-precise) wheel event with the given line delta.
    private func wheel(
        deltaY: Int32,
        flags: CGEventFlags = [],
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> NSEvent {
        let cg = try XCTUnwrap(
            CGEvent(
                scrollWheelEvent2Source: nil, units: .line, wheelCount: 1,
                wheel1: deltaY, wheel2: 0, wheel3: 0
            ),
            "CGEvent(scrollWheelEvent2Source:) returned nil", file: file, line: line
        )
        cg.flags = flags
        let ev = try XCTUnwrap(NSEvent(cgEvent: cg), "NSEvent(cgEvent:) returned nil", file: file, line: line)
        XCTAssertEqual(ev.type, .scrollWheel, file: file, line: line)
        XCTAssertFalse(ev.hasPreciseScrollingDeltas,
                       "precondition: .line units must bridge to a classic (non-precise) wheel event",
                       file: file, line: line)
        XCTAssertEqual(ev.scrollingDeltaY, Double(deltaY), accuracy: 1e-9,
                       "precondition: scrollingDeltaY must bridge 1:1 from wheel1 for .line units",
                       file: file, line: line)
        return ev
    }

    // MARK: - Byte oracle

    /// Splits the recorded bytes into fixed-width chunks. Fails if the total
    /// length is not a multiple of `width` — a stray byte is itself a bug.
    private func chunks(_ recorder: RecordingPTY, width: Int,
                        file: StaticString = #filePath, line: UInt = #line) -> [[UInt8]] {
        let bytes = [UInt8](recorder.sent)
        XCTAssertEqual(bytes.count % width, 0,
                       "recorded \(bytes.count) bytes, not a whole number of \(width)-byte sequences: \(hex(bytes))",
                       file: file, line: line)
        return stride(from: 0, to: bytes.count - bytes.count % width, by: width).map { Array(bytes[$0..<$0 + width]) }
    }

    private func hex(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
    }

    private func assertSent(_ recorder: RecordingPTY, exactly count: Int, of seq: [UInt8],
                            file: StaticString = #filePath, line: UInt = #line) {
        let got = chunks(recorder, width: seq.count, file: file, line: line)
        XCTAssertEqual(got.count, count,
                       "expected \(count) × \(hex(seq)), got \(got.count) sequences: \(hex([UInt8](recorder.sent)))",
                       file: file, line: line)
        for (i, c) in got.enumerated() {
            XCTAssertEqual(c, seq, "sequence #\(i) was \(hex(c)), expected \(hex(seq))", file: file, line: line)
        }
    }

    private func assertNothingSent(_ recorder: RecordingPTY, _ why: String,
                                   file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(recorder.sent.isEmpty,
                      "\(why): expected no PTY bytes, got \(hex([UInt8](recorder.sent)))",
                      file: file, line: line)
    }

    // MARK: - Preconditions on the fixture

    private func assertHappyGate(_ snap: BBSnapshot, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(snap.termMode.contains(.altScreen), "precondition: alt screen on", file: file, line: line)
        XCTAssertTrue(snap.termMode.contains(.alternateScroll), "precondition: 1007 on by default", file: file, line: line)
        XCTAssertTrue(snap.termMode.isDisjoint(with: [.mouseReportClick, .mouseMotion, .mouseDrag]),
                      "precondition: no mouse protocol", file: file, line: line)
        XCTAssertFalse(snap.termMode.contains(.appCursor), "precondition: DECCKM off", file: file, line: line)
    }

    // MARK: - 1. Normal cursor keys

    func test_altScreen_wheelUp_sendsThreeCursorUp() throws {
        let rig = try makeRig(feeding: altScreenOnly)
        assertHappyGate(rig.snapshot)
        rig.view.scrollWheel(with: try wheel(deltaY: -1))
        assertSent(rig.recorder, exactly: 3, of: cursorUp)
    }

    func test_altScreen_wheelDown_sendsThreeCursorDown() throws {
        let rig = try makeRig(feeding: altScreenOnly)
        assertHappyGate(rig.snapshot)
        rig.view.scrollWheel(with: try wheel(deltaY: 1))
        assertSent(rig.recorder, exactly: 3, of: cursorDown)
    }

    func test_altScreen_twoNotches_sendsSixArrows() throws {
        let rig = try makeRig(feeding: altScreenOnly)
        assertHappyGate(rig.snapshot)
        rig.view.scrollWheel(with: try wheel(deltaY: -2))
        assertSent(rig.recorder, exactly: 6, of: cursorUp)
    }

    func test_altScreen_successiveEvents_eachSendThree() throws {
        let rig = try makeRig(feeding: altScreenOnly)
        assertHappyGate(rig.snapshot)
        rig.view.scrollWheel(with: try wheel(deltaY: -1))
        rig.view.scrollWheel(with: try wheel(deltaY: 1))
        let got = chunks(rig.recorder, width: 3)
        XCTAssertEqual(got, Array(repeating: cursorUp, count: 3) + Array(repeating: cursorDown, count: 3),
                       "classic events are stateless: 3 up then 3 down, in order")
    }

    // MARK: - 2. Application cursor keys (DECCKM)

    func test_altScreen_appCursor_wheelUp_sendsSSthreeA() throws {
        let rig = try makeRig(feeding: altScreenOnly + "\u{1B}[?1h")
        XCTAssertTrue(rig.snapshot.termMode.contains(.appCursor), "precondition: CSI ? 1 h sets DECCKM")
        XCTAssertTrue(rig.snapshot.termMode.contains(.altScreen))
        XCTAssertTrue(rig.snapshot.termMode.contains(.alternateScroll))
        rig.view.scrollWheel(with: try wheel(deltaY: -1))
        assertSent(rig.recorder, exactly: 3, of: appUp)
    }

    func test_altScreen_appCursor_wheelDown_sendsSSthreeB() throws {
        let rig = try makeRig(feeding: altScreenOnly + "\u{1B}[?1h")
        XCTAssertTrue(rig.snapshot.termMode.contains(.appCursor), "precondition: CSI ? 1 h sets DECCKM")
        rig.view.scrollWheel(with: try wheel(deltaY: 1))
        assertSent(rig.recorder, exactly: 3, of: appDown)
    }

    // MARK: - 3. Suppression cases

    func test_optionHeld_sendsNothing() throws {
        let rig = try makeRig(feeding: altScreenOnly)
        assertHappyGate(rig.snapshot)
        let ev = try wheel(deltaY: -1, flags: .maskAlternate)
        XCTAssertTrue(ev.modifierFlags.contains(.option), "precondition: Option must bridge onto the NSEvent")
        rig.view.scrollWheel(with: ev)
        assertNothingSent(rig.recorder, "Option-wheel means local scrollback, not arrow keys")
    }

    func test_alternateScrollDisabledByTUI_sendsNothing() throws {
        let rig = try makeRig(feeding: altScreenOnly + "\u{1B}[?1007l")
        XCTAssertTrue(rig.snapshot.termMode.contains(.altScreen), "precondition: still on alt screen")
        XCTAssertFalse(rig.snapshot.termMode.contains(.alternateScroll), "precondition: CSI ? 1007 l clears 1007")
        rig.view.scrollWheel(with: try wheel(deltaY: -1))
        rig.view.scrollWheel(with: try wheel(deltaY: 1))
        assertNothingSent(rig.recorder, "a TUI that opted out of 1007 must not receive arrow keys")
    }

    func test_primaryScreen_sendsNothing() throws {
        // Fresh terminal: 1007 is on by default but the alt screen is not.
        let rig = try makeRig(feeding: "")
        XCTAssertFalse(rig.snapshot.termMode.contains(.altScreen), "precondition: primary screen")
        XCTAssertTrue(rig.snapshot.termMode.contains(.alternateScroll), "precondition: 1007 default on")
        rig.view.scrollWheel(with: try wheel(deltaY: -1))
        rig.view.scrollWheel(with: try wheel(deltaY: 1))
        assertNothingSent(rig.recorder, "on the primary screen the wheel scrolls history, never the shell")
    }

    func test_mouseReportingOn_sendsNoArrowKeys() throws {
        // Click reporting alone. No SGR, so any report the view might emit
        // is X10-encoded and starts with ESC [ M — never ESC [ A/B.
        let rig = try makeRig(feeding: altScreenOnly + "\u{1B}[?1000h")
        XCTAssertTrue(rig.snapshot.termMode.contains(.altScreen))
        XCTAssertTrue(rig.snapshot.termMode.contains(.alternateScroll))
        XCTAssertFalse(rig.snapshot.termMode.isDisjoint(with: [.mouseReportClick, .mouseMotion, .mouseDrag]),
                       "precondition: CSI ? 1000 h enables a mouse protocol")
        rig.view.scrollWheel(with: try wheel(deltaY: -1))
        let bytes = [UInt8](rig.recorder.sent)
        XCTAssertFalse(contains(bytes, cursorUp) || contains(bytes, appUp),
                       "with a mouse protocol on, the wheel belongs to the mouse encoder, not alternate scroll: \(hex(bytes))")
    }

    func test_anyEventMotionReporting_sendsNoArrowKeys() throws {
        let rig = try makeRig(feeding: altScreenOnly + "\u{1B}[?1003h\u{1B}[?1006h")
        XCTAssertTrue(rig.snapshot.termMode.contains(.mouseMotion), "precondition: CSI ? 1003 h")
        rig.view.scrollWheel(with: try wheel(deltaY: 1))
        let bytes = [UInt8](rig.recorder.sent)
        XCTAssertFalse(contains(bytes, cursorDown) || contains(bytes, appDown),
                       "with any-event motion on, no arrow keys: \(hex(bytes))")
    }

    // MARK: - 4. Per-event cap

    func test_hugeDelta_capsAtSixtyFourArrows() throws {
        let rig = try makeRig(feeding: altScreenOnly)
        assertHappyGate(rig.snapshot)
        rig.view.scrollWheel(with: try wheel(deltaY: 1000))
        let got = chunks(rig.recorder, width: 3)
        XCTAssertLessThanOrEqual(got.count, 64, "a single event must never send more than 64 arrow presses")
        XCTAssertGreaterThan(got.count, 0, "a huge delta must still send something")
        for c in got { XCTAssertEqual(c, cursorDown) }
    }

    func test_hugeNegativeDelta_capsAtSixtyFourArrows() throws {
        let rig = try makeRig(feeding: altScreenOnly)
        assertHappyGate(rig.snapshot)
        rig.view.scrollWheel(with: try wheel(deltaY: -1000))
        let got = chunks(rig.recorder, width: 3)
        XCTAssertLessThanOrEqual(got.count, 64)
        XCTAssertGreaterThan(got.count, 0)
        for c in got { XCTAssertEqual(c, cursorUp) }
    }

    // MARK: - Helpers

    private func contains(_ haystack: [UInt8], _ needle: [UInt8]) -> Bool {
        guard haystack.count >= needle.count else { return false }
        return (0...(haystack.count - needle.count)).contains { i in
            Array(haystack[i..<i + needle.count]) == needle
        }
    }
}
