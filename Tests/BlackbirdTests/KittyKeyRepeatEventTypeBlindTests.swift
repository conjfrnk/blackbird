import XCTest
import AppKit
@testable import Blackbird
import BBCore

/// KEY-6 -- Kitty flag 2 (`reportEventTypes`): an auto-repeating key is never
/// reported as event type 2.
///
/// Contract under test (https://sw.kovidgoyal.net/kitty/keyboard-protocol/,
/// "Report event types"). A TUI that pushes flags 1+2 (`CSI > 3 u`; crossterm's
/// DISAMBIGUATE_ESCAPE_CODES | REPORT_EVENT_TYPES) asks the terminal to tell
/// it whether each key event is a press (1), a repeat (2) or a release (3).
/// For a key that is sent as an escape code:
///
///   * the first key-down (a press) is encoded exactly as without flag 2 --
///     the `:1` sub-parameter is omitted (`ESC [ A` for Up);
///   * every auto-repeat key-down that follows (AppKit: `isARepeat == true`)
///     carries event type 2 in the modifier field, which is forced present
///     (`ESC [ 1 ; 1 : 2 A` for Up, `ESC [ 99 ; 5 : 2 u` for Ctrl+C);
///   * the key-up is the same shape with `:3`.
///
/// Text-producing keys are the exception: without flag 8 they are delivered
/// as plain text, which has no room for an event type, so a held `a` stays a
/// stream of `a` bytes. With flag 8 (`reportAllKeysAsEsc`, `CSI > 11 u` for
/// 1+2+8) every key is an escape code, so every key -- Return, Escape, a plain
/// letter -- reports its repeats too.
///
/// The encoder itself already produces these shapes when it is handed
/// `.repeat` (pinned in `KittyKeyboardProtocolTests`); this suite pins the
/// whole `TerminalView.keyDown` path, i.e. that a hardware auto-repeat actually
/// *arrives* at the encoder as a repeat.
///
/// Fixture realism. Hold = the same key-down event delivered three times: the
/// first with `isARepeat == false`, the next two with `isARepeat == true`, as
/// AppKit does for a held key. Function / navigation keys carry the AppKit
/// private-use scalar (`NSUpArrowFunctionKey` ...) as both `characters` and
/// `charactersIgnoringModifiers`, arrows additionally `.numericPad`, as on
/// hardware. The mode bits under test are produced by feeding the real
/// `CSI > n u` pushes to a real `BBTerm` and taking its snapshot (the same
/// authority the product reads at runtime), and every rig asserts them.
///
/// Anchors. Each claim is paired with neighbours that work today (the press
/// of every key under the same flags, the key-up under flag 2, repeats with
/// flag 2 off, repeats of plain text keys without flag 8), so a failure can
/// only be the missing repeat event type and never a dead rig.
///
/// Written blind: no `TerminalView.keyDown` / `KeyEncoder` body was read; only
/// declarations, doc comments and sibling tests.
///
/// Memory/time pre-flight: one headless `TerminalView` + one 40x6 `BBTerm`
/// (scrollback 16) per test; no window, no PTY, no child process, no runloop
/// pumping, no timers. A few hundred KiB per rig.
final class KittyKeyRepeatEventTypeBlindTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        TestHostTermination.shared.register()
    }

    // MARK: - Fixtures

    /// `CSI > 3 u`: kitty flags 1 (disambiguate) + 2 (report event types).
    private let push1and2 = "\u{1B}[>3u"
    /// `CSI > 11 u`: flags 1 + 2 + 8 (report all keys as escape codes).
    private let push1and2and8 = "\u{1B}[>11u"
    /// `CSI > 1 u`: flag 1 only.
    private let push1 = "\u{1B}[>1u"

    /// A physical key plus the exact bytes its press and its repeat must put
    /// on the wire under the mode the test is run in.
    private struct KeySpec {
        let name: String
        let chars: String
        let charsIgnoringModifiers: String
        let keyCode: UInt16
        let flags: NSEvent.ModifierFlags
        let press: String
        let repeating: String
    }

    private func scalar(_ v: UInt32) -> String {
        String(Unicode.Scalar(v)!)
    }

    /// Arrow: private-use scalar, `.numericPad` + `.function` as on hardware.
    private func arrow(
        _ name: String, _ scalarValue: UInt32, _ keyCode: UInt16,
        extra: NSEvent.ModifierFlags = [], press: String, repeating: String
    ) -> KeySpec {
        KeySpec(name: name, chars: scalar(scalarValue), charsIgnoringModifiers: scalar(scalarValue),
                keyCode: keyCode, flags: NSEvent.ModifierFlags([.numericPad, .function]).union(extra),
                press: press, repeating: repeating)
    }

    /// Navigation / function key: private-use scalar, `.function`.
    private func fnKey(
        _ name: String, _ scalarValue: UInt32, _ keyCode: UInt16,
        press: String, repeating: String
    ) -> KeySpec {
        KeySpec(name: name, chars: scalar(scalarValue), charsIgnoringModifiers: scalar(scalarValue),
                keyCode: keyCode, flags: [.function], press: press, repeating: repeating)
    }

    private let ESC = "\u{1B}"

    /// Keys sent as CSI-parameter escape codes (arrows, nav, F-keys). Press is
    /// the legacy shape (kitty omits `:1`); repeat forces the modifier field
    /// and appends `:2`.
    private var specialKeys: [KeySpec] {
        [
            arrow("Up",    0xF700, 126, press: "\(ESC)[A", repeating: "\(ESC)[1;1:2A"),
            arrow("Down",  0xF701, 125, press: "\(ESC)[B", repeating: "\(ESC)[1;1:2B"),
            arrow("Right", 0xF703, 124, press: "\(ESC)[C", repeating: "\(ESC)[1;1:2C"),
            arrow("Left",  0xF702, 123, press: "\(ESC)[D", repeating: "\(ESC)[1;1:2D"),
            fnKey("Home",     0xF729, 115, press: "\(ESC)[H",  repeating: "\(ESC)[1;1:2H"),
            fnKey("End",      0xF72B, 119, press: "\(ESC)[F",  repeating: "\(ESC)[1;1:2F"),
            fnKey("PageUp",   0xF72C, 116, press: "\(ESC)[5~", repeating: "\(ESC)[5;1:2~"),
            fnKey("PageDown", 0xF72D, 121, press: "\(ESC)[6~", repeating: "\(ESC)[6;1:2~"),
            fnKey("Delete",   0xF728, 117, press: "\(ESC)[3~", repeating: "\(ESC)[3;1:2~"),
            // F1 press is the SS3 form `ESC O P`; a repeat has no SS3 form
            // with a modifier field, so it is `CSI 1 ; 1 : 2 P`.
            fnKey("F1",  0xF704, 122, press: "\(ESC)OP", repeating: "\(ESC)[1;1:2P"),
            fnKey("F5",  0xF708,  96, press: "\(ESC)[15~", repeating: "\(ESC)[15;1:2~"),
            fnKey("F12", 0xF70F, 111, press: "\(ESC)[24~", repeating: "\(ESC)[24;1:2~"),
        ]
    }

    /// Modified arrows: the press already carries a modifier field; the repeat
    /// adds `:2` to it.
    private var modifiedArrows: [KeySpec] {
        [
            arrow("Shift+Up",    0xF700, 126, extra: [.shift],   press: "\(ESC)[1;2A", repeating: "\(ESC)[1;2:2A"),
            arrow("Ctrl+Right",  0xF703, 124, extra: [.control], press: "\(ESC)[1;5C", repeating: "\(ESC)[1;5:2C"),
            arrow("Ctrl+Left",   0xF702, 123, extra: [.control], press: "\(ESC)[1;5D", repeating: "\(ESC)[1;5:2D"),
        ]
    }

    /// Ctrl+letter under flag 1 is a CSI-u escape code (`ESC [ <cp> ; 5 u`).
    private var ctrlLetters: [KeySpec] {
        [
            KeySpec(name: "Ctrl+C", chars: "\u{03}", charsIgnoringModifiers: "c", keyCode: 8,
                    flags: [.control], press: "\(ESC)[99;5u", repeating: "\(ESC)[99;5:2u"),
            KeySpec(name: "Ctrl+A", chars: "\u{01}", charsIgnoringModifiers: "a", keyCode: 0,
                    flags: [.control], press: "\(ESC)[97;5u", repeating: "\(ESC)[97;5:2u"),
            KeySpec(name: "Ctrl+Z", chars: "\u{1A}", charsIgnoringModifiers: "z", keyCode: 6,
                    flags: [.control], press: "\(ESC)[122;5u", repeating: "\(ESC)[122;5:2u"),
        ]
    }

    /// Keys that are escape codes ONLY because flag 8 is on (unmodified
    /// Return / Escape / Tab / Backspace).
    private var flag8ControlKeys: [KeySpec] {
        [
            KeySpec(name: "Return", chars: "\r", charsIgnoringModifiers: "\r", keyCode: 36,
                    flags: [], press: "\(ESC)[13u", repeating: "\(ESC)[13;1:2u"),
            KeySpec(name: "Escape", chars: "\u{1B}", charsIgnoringModifiers: "\u{1B}", keyCode: 53,
                    flags: [], press: "\(ESC)[27u", repeating: "\(ESC)[27;1:2u"),
            KeySpec(name: "Tab", chars: "\t", charsIgnoringModifiers: "\t", keyCode: 48,
                    flags: [], press: "\(ESC)[9u", repeating: "\(ESC)[9;1:2u"),
            KeySpec(name: "Backspace", chars: "\u{7F}", charsIgnoringModifiers: "\u{7F}", keyCode: 51,
                    flags: [], press: "\(ESC)[127u", repeating: "\(ESC)[127;1:2u"),
        ]
    }

    // MARK: - Helpers

    private func hex(_ d: Data) -> String {
        d.isEmpty ? "<empty>" : d.map { String(format: "%02X", $0) }.joined(separator: " ")
    }

    /// Human-readable wire form: `ESC` for 0x1B, the character for printable
    /// ASCII, `\xNN` otherwise.
    private func show(_ d: Data) -> String {
        if d.isEmpty { return "<empty>" }
        return d.map { b -> String in
            switch b {
            case 0x1B: return "ESC "
            case 0x20...0x7E: return String(UnicodeScalar(b)) + " "
            default: return String(format: "\\x%02X ", b)
            }
        }.joined().trimmingCharacters(in: .whitespaces)
    }

    private func keyEvent(
        _ type: NSEvent.EventType, _ spec: KeySpec, isARepeat: Bool
    ) throws -> NSEvent {
        try XCTUnwrap(
            NSEvent.keyEvent(
                with: type,
                location: .zero,
                modifierFlags: spec.flags,
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                characters: spec.chars,
                charactersIgnoringModifiers: spec.charsIgnoringModifiers,
                isARepeat: isARepeat,
                keyCode: spec.keyCode
            ),
            "NSEvent.keyEvent returned nil for \(spec.name) (keyCode \(spec.keyCode))"
        )
    }

    /// Counts `keyDown` deliveries that fall off the end of the view's own
    /// handling (NSResponder's default forwards to `nextResponder`; with
    /// nobody to take it the system beeps).
    private final class KeyEventCounter: NSResponder {
        var keyDownCount = 0
        override func keyDown(with event: NSEvent) { keyDownCount += 1 }
    }

    private struct Rig {
        let view: TerminalView
        let term: BBTerm
        let session: TerminalSession
        let recorder: RecordingPTY
        let counter: KeyEventCounter
        let snapshot: BBSnapshot
    }

    /// One headless view + a 40x6 BBTerm. `setup` is fed to the real parser and
    /// the resulting snapshot (and so `termMode`) is installed on the view.
    private func makeRig(
        feeding setup: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> Rig {
        let view = try XCTUnwrap(TerminalView.makeHeadlessForTests(),
                                 "Metal device required", file: file, line: line)
        let term = try XCTUnwrap(BBTerm(size: .init(cols: 40, rows: 6), scrollback: 16),
                                 "BBTerm init failed", file: file, line: line)
        term.input(setup)
        let snapshot = try XCTUnwrap(term.snapshot(), "snapshot() returned nil",
                                     file: file, line: line)
        let session = TerminalSession.makeHeadlessForTests()
        view.session = session
        view.currentSnapshot = snapshot
        let recorder = RecordingPTY()
        view.ptyRecorderForTests = recorder
        let counter = KeyEventCounter()
        view.nextResponder = counter
        return Rig(view: view, term: term, session: session, recorder: recorder,
                   counter: counter, snapshot: snapshot)
    }

    /// Rig whose snapshot mode is asserted to be exactly kitty flags 1+2.
    private func makeFlags1and2Rig(file: StaticString = #filePath, line: UInt = #line) throws -> Rig {
        let rig = try makeRig(feeding: push1and2, file: file, line: line)
        let mode = rig.snapshot.termMode
        XCTAssertTrue(mode.contains(.disambiguateEscCodes),
                      "precondition: CSI > 3 u must set flag 1; termMode.rawValue=\(mode.rawValue)",
                      file: file, line: line)
        XCTAssertTrue(mode.contains(.reportEventTypes),
                      "precondition: CSI > 3 u must set flag 2; termMode.rawValue=\(mode.rawValue)",
                      file: file, line: line)
        XCTAssertFalse(mode.contains(.reportAllKeysAsEsc),
                       "precondition: CSI > 3 u must NOT set flag 8; termMode.rawValue=\(mode.rawValue)",
                       file: file, line: line)
        return rig
    }

    /// Delivers `events` (`false` = first press, `true` = auto-repeat) for
    /// `spec` and returns the bytes each one put on the PTY, one entry per
    /// event, plus how many were forwarded up the responder chain.
    private func deliver(
        _ spec: KeySpec, isARepeat events: [Bool], on rig: Rig
    ) throws -> (perEvent: [Data], forwarded: Int) {
        let forwardedBefore = rig.counter.keyDownCount
        var out: [Data] = []
        for rep in events {
            rig.recorder.sent = Data()
            rig.view.keyDown(with: try keyEvent(.keyDown, spec, isARepeat: rep))
            out.append(rig.recorder.sent)
        }
        return (out, rig.counter.keyDownCount - forwardedBefore)
    }

    /// Holds `spec`: one press then two auto-repeats. Asserts the PTY saw
    /// exactly press, repeat, repeat -- and that every event was consumed.
    private func assertHold(
        _ spec: KeySpec,
        on rig: Rig,
        context: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let pressBytes = Data(spec.press.utf8)
        let repeatBytes = Data(spec.repeating.utf8)
        let (got, forwarded) = try deliver(spec, isARepeat: [false, true, true], on: rig)
        let want = [pressBytes, repeatBytes, repeatBytes]
        XCTAssertEqual(
            got.map(show), want.map(show),
            "\(context): holding \(spec.name) (keyCode \(spec.keyCode)) must report "
            + "press, then repeat(:2), then repeat(:2); wire per event = \(got.map(show)) "
            + "[hex \(got.map(hex))], expected \(want.map(show))",
            file: file, line: line)
        XCTAssertEqual(forwarded, 0,
                       "\(context): \(spec.name) events must be consumed, not forwarded up the "
                       + "responder chain (that path ends in the system beep); forwarded \(forwarded)",
                       file: file, line: line)
    }

    // MARK: - Harness self-checks

    /// The mode pushes really set the bits this suite relies on, so a later
    /// "no event type" result cannot come from a rig that never turned flag 2
    /// on.
    func test_precondition_flagPushes_setTheExpectedModeBits() throws {
        let r12 = try makeRig(feeding: push1and2)
        XCTAssertTrue(r12.snapshot.termMode.contains([.disambiguateEscCodes, .reportEventTypes]),
                      "CSI > 3 u must set flags 1 and 2; rawValue=\(r12.snapshot.termMode.rawValue)")
        XCTAssertFalse(r12.snapshot.termMode.contains(.reportAllKeysAsEsc),
                       "CSI > 3 u must not set flag 8")

        let r128 = try makeRig(feeding: push1and2and8)
        XCTAssertTrue(r128.snapshot.termMode.contains(
            [.disambiguateEscCodes, .reportEventTypes, .reportAllKeysAsEsc]),
                      "CSI > 11 u must set flags 1, 2 and 8; rawValue=\(r128.snapshot.termMode.rawValue)")

        let r1 = try makeRig(feeding: push1)
        XCTAssertTrue(r1.snapshot.termMode.contains(.disambiguateEscCodes),
                      "CSI > 1 u must set flag 1")
        XCTAssertFalse(r1.snapshot.termMode.contains(.reportEventTypes),
                       "CSI > 1 u must not set flag 2")

        let r0 = try makeRig(feeding: "")
        XCTAssertTrue(r0.snapshot.termMode.isDisjoint(
            with: [.disambiguateEscCodes, .reportEventTypes, .reportAllKeysAsEsc]),
                      "a fresh terminal must have no kitty flags")
    }

    /// Anchor: under flags 1+2 the first key-down (press) of every key class
    /// is encoded without an event-type sub-parameter, and a key-up is
    /// reported as event type 3. Both work today; they prove the rig carries
    /// flag-2 framing end to end, so the repeat gap below is not a dead rig.
    func test_anchor_pressAndRelease_underFlags1and2() throws {
        let rig = try makeFlags1and2Rig()
        let samples = [specialKeys[0], specialKeys[6], specialKeys[10]] + [modifiedArrows[1]] + [ctrlLetters[0]]
        for spec in samples {
            let (pressOnly, forwarded) = try deliver(spec, isARepeat: [false], on: rig)
            XCTAssertEqual(show(pressOnly[0]), show(Data(spec.press.utf8)),
                           "anchor: first press of \(spec.name) under flags 1+2 must be \(spec.press.debugDescription); "
                           + "got \(show(pressOnly[0])) [hex \(hex(pressOnly[0]))]")
            XCTAssertEqual(forwarded, 0, "anchor: press of \(spec.name) must be consumed")
        }

        // Release of Up: `ESC [ 1 ; 1 : 3 A`.
        let up = specialKeys[0]
        rig.recorder.sent = Data()
        rig.view.keyUp(with: try keyEvent(.keyUp, up, isARepeat: false))
        XCTAssertEqual(show(rig.recorder.sent), show(Data("\(ESC)[1;1:3A".utf8)),
                       "anchor: key-up of Up under flags 1+2 must be ESC [ 1 ; 1 : 3 A; "
                       + "got \(show(rig.recorder.sent)) [hex \(hex(rig.recorder.sent))]")
    }

    // MARK: - The bug: repeats under flags 1+2

    /// Holding an arrow / nav / F-key sends press, then repeats flagged `:2`.
    func test_hold_specialKeys_flags1and2_repeatsCarryEventType2() throws {
        let rig = try makeFlags1and2Rig()
        for spec in specialKeys {
            try assertHold(spec, on: rig, context: "flags 1+2")
        }
    }

    /// Same for modified arrows: the press modifier field gains `:2`.
    func test_hold_modifiedArrows_flags1and2_repeatsCarryEventType2() throws {
        let rig = try makeFlags1and2Rig()
        for spec in modifiedArrows {
            try assertHold(spec, on: rig, context: "flags 1+2")
        }
    }

    /// Holding Ctrl+letter (a CSI-u escape code under flag 1) reports repeats
    /// as `ESC [ <cp> ; 5 : 2 u`.
    func test_hold_ctrlLetter_flags1and2_repeatsCarryEventType2() throws {
        let rig = try makeFlags1and2Rig()
        for spec in ctrlLetters {
            try assertHold(spec, on: rig, context: "flags 1+2")
        }
    }

    /// With flag 8 on top, every key is an escape code, so unmodified
    /// Return / Escape / Tab / Backspace report repeats too.
    func test_hold_unmodifiedControlKeys_flags1and2and8_repeatsCarryEventType2() throws {
        let rig = try makeRig(feeding: push1and2and8)
        XCTAssertTrue(rig.snapshot.termMode.contains(
            [.disambiguateEscCodes, .reportEventTypes, .reportAllKeysAsEsc]),
                      "precondition: CSI > 11 u must set flags 1+2+8; rawValue=\(rig.snapshot.termMode.rawValue)")
        for spec in flag8ControlKeys {
            try assertHold(spec, on: rig, context: "flags 1+2+8")
        }
    }

    /// A plain letter under flags 1+2+8 is an escape code (`ESC [ 97 u`) and
    /// its held repeats are `ESC [ 97 ; 1 : 2 u`. Plain-letter key-downs reach
    /// the encoder through the text-input path; if this host's headless view
    /// does not route a key-down there at all (no bytes whatsoever) the test
    /// skips rather than blame the repeat handling.
    func test_hold_plainLetter_flags1and2and8_repeatsCarryEventType2() throws {
        let rig = try makeRig(feeding: push1and2and8)
        XCTAssertTrue(rig.snapshot.termMode.contains(
            [.disambiguateEscCodes, .reportEventTypes, .reportAllKeysAsEsc]),
                      "precondition: CSI > 11 u must set flags 1+2+8; rawValue=\(rig.snapshot.termMode.rawValue)")
        let letterA = KeySpec(name: "a", chars: "a", charsIgnoringModifiers: "a", keyCode: 0,
                              flags: [], press: "\(ESC)[97u", repeating: "\(ESC)[97;1:2u")
        let (probe, _) = try deliver(letterA, isARepeat: [false], on: rig)
        if probe[0].isEmpty {
            throw XCTSkip("headless keyDown does not reach insertText in this host; "
                          + "the special-key and Return holds carry the contract")
        }
        XCTAssertEqual(show(probe[0]), show(Data(letterA.press.utf8)),
                       "anchor: first press of 'a' under flags 1+2+8 must be ESC [ 9 7 u; got \(show(probe[0]))")
        try assertHold(letterA, on: rig, context: "flags 1+2+8")
    }

    /// A full hold-and-release of Up: press, two repeats, release.
    func test_lifecycle_pressRepeatRepeatRelease_underFlags1and2() throws {
        let rig = try makeFlags1and2Rig()
        let up = specialKeys[0]
        var wire: [Data] = []
        for rep in [false, true, true] {
            rig.recorder.sent = Data()
            rig.view.keyDown(with: try keyEvent(.keyDown, up, isARepeat: rep))
            wire.append(rig.recorder.sent)
        }
        rig.recorder.sent = Data()
        rig.view.keyUp(with: try keyEvent(.keyUp, up, isARepeat: false))
        wire.append(rig.recorder.sent)

        let want = ["\(ESC)[A", "\(ESC)[1;1:2A", "\(ESC)[1;1:2A", "\(ESC)[1;1:3A"].map { Data($0.utf8) }
        XCTAssertEqual(wire.map(show), want.map(show),
                       "hold-and-release of Up under flags 1+2 must be press, repeat(:2), repeat(:2), "
                       + "release(:3); wire = \(wire.map(show)) [hex \(wire.map(hex))]")
    }

    // MARK: - Must-not-change neighbours

    /// With flag 2 OFF (flag 1 only) a repeat is indistinguishable from a
    /// press by protocol: `ESC [ A`, never an event type.
    func test_hold_flag1Only_repeatsStayIdenticalToPress() throws {
        let rig = try makeRig(feeding: push1)
        XCTAssertTrue(rig.snapshot.termMode.contains(.disambiguateEscCodes)
                      && !rig.snapshot.termMode.contains(.reportEventTypes),
                      "precondition: CSI > 1 u must set flag 1 and not flag 2; "
                      + "rawValue=\(rig.snapshot.termMode.rawValue)")
        let samples = [specialKeys[0], specialKeys[6], ctrlLetters[0]]
        for spec in samples {
            let steady = KeySpec(name: spec.name, chars: spec.chars,
                                 charsIgnoringModifiers: spec.charsIgnoringModifiers,
                                 keyCode: spec.keyCode, flags: spec.flags,
                                 press: spec.press, repeating: spec.press)
            try assertHold(steady, on: rig, context: "flag 1 only")
        }
    }

    /// With no kitty flags at all, holding Up is a stream of `ESC [ A`.
    func test_hold_noKittyFlags_repeatsStayIdenticalToPress() throws {
        let rig = try makeRig(feeding: "")
        XCTAssertTrue(rig.snapshot.termMode.isDisjoint(
            with: [.disambiguateEscCodes, .reportEventTypes, .reportAllKeysAsEsc]),
                      "precondition: fresh terminal has no kitty flags")
        let up = specialKeys[0]
        let steady = KeySpec(name: up.name, chars: up.chars, charsIgnoringModifiers: up.charsIgnoringModifiers,
                             keyCode: up.keyCode, flags: up.flags, press: up.press, repeating: up.press)
        try assertHold(steady, on: rig, context: "no kitty flags")
    }

    /// Without flag 8 a plain text key is delivered as text: a held `a` under
    /// flags 1+2 is a stream of `a` bytes with no event type (text has no
    /// place to carry one). Skips when the headless view never routes a
    /// key-down to the text-input path.
    func test_hold_plainLetter_flags1and2_staysPlainText() throws {
        let rig = try makeFlags1and2Rig()
        let letterA = KeySpec(name: "a", chars: "a", charsIgnoringModifiers: "a", keyCode: 0,
                              flags: [], press: "a", repeating: "a")
        let (probe, _) = try deliver(letterA, isARepeat: [false], on: rig)
        if probe[0].isEmpty {
            throw XCTSkip("headless keyDown does not reach insertText in this host")
        }
        try assertHold(letterA, on: rig, context: "flags 1+2 (no flag 8)")
    }
}
