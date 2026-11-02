import XCTest
import AppKit
import Metal
@testable import Blackbird
import BBCore

/// KEY-4 -- numeric-keypad digit and operator keys ignore application-keypad
/// mode (DECPAM).
///
/// Contract under test. A program turns application-keypad mode on with
/// `ESC =` (DECKPAM; ncurses `smkx` does this) and off with `ESC >` (DECKPNM).
/// While it is on, the keys of the Mac numeric keypad send xterm's SS3 keypad
/// sequences instead of their plain characters:
///
///     keypad 0-9  ->  ESC O p .. ESC O y
///     keypad +    ->  ESC O k      keypad -  ->  ESC O m
///     keypad *    ->  ESC O j      keypad /  ->  ESC O o
///     keypad .    ->  ESC O n      keypad =  ->  ESC O X
///     keypad Enter -> ESC O M
///
/// With the mode off every one of those keys sends its plain character. The
/// SS3 table itself is already pinned at the encoder level
/// (`KeyEncoderExtendedTests.test_appKeypad_on_*`); what this suite pins is
/// that a real keypad *keypress* actually reaches that encoding, i.e. the
/// whole `TerminalView.keyDown` path, which is where the digit/operator keys
/// were being lost.
///
/// Fixture realism. A hardware keypad key arrives as a key-down whose
/// `keyCode` is the kVK_ANSI_Keypad* virtual key, whose `characters` are the
/// plain digit/operator, and whose `modifierFlags` carry `.numericPad`.
/// Keypad Enter reports ETX (0x03) as its character. The mode bit under test
/// is produced by feeding the real `ESC =` / `ESC >` bytes to a real `BBTerm`
/// and taking its snapshot (the same authority the product reads at runtime),
/// and every rig asserts that precondition so a mistyped escape fails the
/// fixture rather than the behaviour.
///
/// Anchors. Each claim is paired with neighbours that already work today
/// (keypad Enter under DECPAM, every key with DECPAM off, the top-row
/// digits/operators under DECPAM), so a failure can only be the keypad
/// digit/operator gap and never a dead rig, and a "fix" that keys on the
/// produced character instead of the physical key cannot pass.
///
/// Memory/time pre-flight: one 640x240 headless `TerminalView` + one 40x6
/// `BBTerm` (scrollback 16) per test; no window, no PTY, no child process,
/// no runloop pumping, no timers. A few hundred KiB per rig; wall time is
/// dominated by Metal renderer construction.
final class KeypadApplicationModeBlindTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        TestHostTermination.shared.register()
    }

    // MARK: - Key tables

    /// A physical key: its macOS virtual key code and the character AppKit
    /// reports for it.
    private struct PhysicalKey {
        let name: String
        let keyCode: UInt16
        let chars: String
        let flags: NSEvent.ModifierFlags
    }

    /// kVK_ANSI_Keypad0...9. (Key code 90 is F20, not a keypad key, which is
    /// why 8 and 9 sit at 91 and 92.)
    private let keypadDigits: [(key: PhysicalKey, ss3Final: Character)] = [
        (PhysicalKey(name: "keypad 0", keyCode: 82, chars: "0", flags: [.numericPad]), "p"),
        (PhysicalKey(name: "keypad 1", keyCode: 83, chars: "1", flags: [.numericPad]), "q"),
        (PhysicalKey(name: "keypad 2", keyCode: 84, chars: "2", flags: [.numericPad]), "r"),
        (PhysicalKey(name: "keypad 3", keyCode: 85, chars: "3", flags: [.numericPad]), "s"),
        (PhysicalKey(name: "keypad 4", keyCode: 86, chars: "4", flags: [.numericPad]), "t"),
        (PhysicalKey(name: "keypad 5", keyCode: 87, chars: "5", flags: [.numericPad]), "u"),
        (PhysicalKey(name: "keypad 6", keyCode: 88, chars: "6", flags: [.numericPad]), "v"),
        (PhysicalKey(name: "keypad 7", keyCode: 89, chars: "7", flags: [.numericPad]), "w"),
        (PhysicalKey(name: "keypad 8", keyCode: 91, chars: "8", flags: [.numericPad]), "x"),
        (PhysicalKey(name: "keypad 9", keyCode: 92, chars: "9", flags: [.numericPad]), "y"),
    ]

    /// kVK_ANSI_KeypadPlus / Minus / Multiply / Divide / Decimal / Equals.
    private let keypadOperators: [(key: PhysicalKey, ss3Final: Character)] = [
        (PhysicalKey(name: "keypad +", keyCode: 69, chars: "+", flags: [.numericPad]), "k"),
        (PhysicalKey(name: "keypad -", keyCode: 78, chars: "-", flags: [.numericPad]), "m"),
        (PhysicalKey(name: "keypad *", keyCode: 67, chars: "*", flags: [.numericPad]), "j"),
        (PhysicalKey(name: "keypad /", keyCode: 75, chars: "/", flags: [.numericPad]), "o"),
        (PhysicalKey(name: "keypad .", keyCode: 65, chars: ".", flags: [.numericPad]), "n"),
        (PhysicalKey(name: "keypad =", keyCode: 81, chars: "=", flags: [.numericPad]), "X"),
    ]

    /// kVK_ANSI_KeypadEnter (reports ETX as its character).
    private let keypadEnter = PhysicalKey(name: "keypad Enter", keyCode: 76, chars: "\u{03}", flags: [.numericPad])

    /// Main-block keys that produce the same characters as the keypad keys.
    /// These must NEVER become SS3 sequences, DECPAM or not. (`+` and `*`
    /// need Shift on a US layout, as on a real keyboard.)
    private let topRowKeys: [(key: PhysicalKey, plain: String)] = [
        (PhysicalKey(name: "top-row 0", keyCode: 29, chars: "0", flags: []), "0"),
        (PhysicalKey(name: "top-row 1", keyCode: 18, chars: "1", flags: []), "1"),
        (PhysicalKey(name: "top-row 5", keyCode: 23, chars: "5", flags: []), "5"),
        (PhysicalKey(name: "top-row 9", keyCode: 25, chars: "9", flags: []), "9"),
        (PhysicalKey(name: "top-row -", keyCode: 27, chars: "-", flags: []), "-"),
        (PhysicalKey(name: "top-row =", keyCode: 24, chars: "=", flags: []), "="),
        (PhysicalKey(name: "top-row /", keyCode: 44, chars: "/", flags: []), "/"),
        (PhysicalKey(name: "top-row .", keyCode: 47, chars: ".", flags: []), "."),
        (PhysicalKey(name: "top-row Shift+= (+)", keyCode: 24, chars: "+", flags: [.shift]), "+"),
        (PhysicalKey(name: "top-row Shift+8 (*)", keyCode: 28, chars: "*", flags: [.shift]), "*"),
    ]

    // MARK: - Helpers

    private func bytes(_ s: String) -> Data { Data(s.utf8) }

    private func hex(_ d: Data) -> String {
        d.isEmpty ? "<empty>" : d.map { String(format: "%02X", $0) }.joined(separator: " ")
    }

    /// `ESC O <final>`.
    private func ss3(_ final: Character) -> Data { bytes("\u{1B}O\(final)") }

    private func keyDownEvent(_ key: PhysicalKey, isARepeat: Bool = false) throws -> NSEvent {
        try XCTUnwrap(
            NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: key.flags,
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                characters: key.chars,
                charactersIgnoringModifiers: key.chars,
                isARepeat: isARepeat,
                keyCode: key.keyCode
            ),
            "NSEvent.keyEvent returned nil for \(key.name) (keyCode \(key.keyCode))"
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
    }

    /// One headless view + a 40x6 BBTerm. `setup` is fed to the real parser and
    /// the resulting snapshot (and so `termMode`) is installed on the view.
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
        let term = try XCTUnwrap(BBTerm(size: .init(cols: 40, rows: 6), scrollback: 16),
                                 "BBTerm init failed", file: file, line: line)
        term.input(setup)
        let snapshot = try XCTUnwrap(term.snapshot(), "snapshot() returned nil", file: file, line: line)
        let session = TerminalSession.makeHeadlessForTests()
        view.session = session
        view.currentSnapshot = snapshot
        let recorder = RecordingPTY()
        view.ptyRecorderForTests = recorder
        let counter = KeyEventCounter()
        view.nextResponder = counter
        return Rig(view: view, term: term, session: session, recorder: recorder, counter: counter)
    }

    /// Application keypad on (`ESC =`), with the precondition checked against
    /// the snapshot the view will actually read.
    private func makeDecpamOnRig(file: StaticString = #filePath, line: UInt = #line) throws -> Rig {
        let rig = try makeRig(feeding: "\u{1B}=", file: file, line: line)
        let mode = try XCTUnwrap(rig.view.currentSnapshot, "view has no snapshot", file: file, line: line).termMode
        XCTAssertTrue(mode.contains(.appKeypad),
                      "precondition: feeding ESC = must set .appKeypad in the view's snapshot termMode; "
                      + "termMode.rawValue=\(mode.rawValue)", file: file, line: line)
        return rig
    }

    /// Application keypad off (power-on default, nothing fed).
    private func makeDecpamOffRig(file: StaticString = #filePath, line: UInt = #line) throws -> Rig {
        let rig = try makeRig(feeding: "", file: file, line: line)
        let mode = try XCTUnwrap(rig.view.currentSnapshot, "view has no snapshot", file: file, line: line).termMode
        XCTAssertFalse(mode.contains(.appKeypad),
                       "precondition: a fresh terminal must not have .appKeypad set; "
                       + "termMode.rawValue=\(mode.rawValue)", file: file, line: line)
        return rig
    }

    /// Presses `key` once on a clean recorder and asserts exactly `expected`
    /// reached the PTY and that the event was consumed rather than forwarded
    /// up the responder chain (which ends in the system beep).
    private func assertPress(
        _ key: PhysicalKey,
        on rig: Rig,
        sends expected: Data,
        context: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        rig.recorder.sent = Data()
        let forwardedBefore = rig.counter.keyDownCount
        rig.view.keyDown(with: try keyDownEvent(key))
        XCTAssertEqual(rig.recorder.sent, expected,
                       "\(context): \(key.name) (keyCode \(key.keyCode), chars \(key.chars.debugDescription), "
                       + "flags \(key.flags.rawValue)) must send \(hex(expected)); sent \(hex(rig.recorder.sent))",
                       file: file, line: line)
        XCTAssertEqual(rig.counter.keyDownCount, forwardedBefore,
                       "\(context): \(key.name) must be consumed, not forwarded up the responder chain "
                       + "(that path ends in the system beep); forwarded "
                       + "\(rig.counter.keyDownCount - forwardedBefore) time(s)",
                       file: file, line: line)
    }

    // MARK: - Harness self-checks

    /// `ESC =` / `ESC >` really toggle the mode bit this suite relies on, so
    /// a later "plain digit" result cannot be a rig that never turned DECPAM on.
    func test_precondition_escEquals_setsAppKeypad_andEscGreater_clearsIt() throws {
        let rig = try makeRig(feeding: "")
        func appKeypad() throws -> Bool {
            let snap = try XCTUnwrap(rig.term.snapshot(), "snapshot() returned nil")
            return snap.termMode.contains(.appKeypad)
        }
        XCTAssertFalse(try appKeypad(), "fresh terminal must have application keypad off")
        rig.term.input("\u{1B}=")
        XCTAssertTrue(try appKeypad(), "ESC = (DECKPAM) must turn application keypad on")
        rig.term.input("\u{1B}>")
        XCTAssertFalse(try appKeypad(), "ESC > (DECKPNM) must turn application keypad off")
    }

    /// Anchor 1: keypad Enter already honours DECPAM today (ESC O M), through
    /// the very same keyDown path, so the rig is capable of delivering SS3.
    /// Plain Return stays CR under DECPAM.
    func test_anchor_decpamOn_keypadEnter_sendsSS3M_andMainReturnStaysCR() throws {
        let rig = try makeDecpamOnRig()
        try assertPress(keypadEnter, on: rig, sends: ss3("M"), context: "DECPAM on")
        let mainReturn = PhysicalKey(name: "main Return", keyCode: 36, chars: "\r", flags: [])
        try assertPress(mainReturn, on: rig, sends: bytes("\r"), context: "DECPAM on")
    }

    /// Anchor 2: with DECPAM off every keypad key (digits, operators, Enter)
    /// sends its plain character. This is today's behaviour and must remain.
    func test_anchor_decpamOff_keypadKeys_sendPlainCharacters() throws {
        let rig = try makeDecpamOffRig()
        for (key, _) in keypadDigits + keypadOperators {
            try assertPress(key, on: rig, sends: bytes(key.chars), context: "DECPAM off")
        }
        try assertPress(keypadEnter, on: rig, sends: bytes("\r"), context: "DECPAM off")
    }

    /// Anchor 3: the main-block digits and operators are not keypad keys and
    /// must stay plain under DECPAM. Guards against a fix that decides by the
    /// produced character ("5", "+", ...) instead of the physical key.
    func test_anchor_decpamOn_topRowKeys_stayPlainCharacters() throws {
        let rig = try makeDecpamOnRig()
        for (key, plain) in topRowKeys {
            try assertPress(key, on: rig, sends: bytes(plain), context: "DECPAM on")
        }
    }

    // MARK: - The bug: DECPAM on, keypad digits and operators

    /// Keypad 0-9 under DECPAM must send ESC O p .. ESC O y. Today they send
    /// the bare digit.
    func test_keyDown_decpamOn_keypadDigits_sendSS3_pThroughY() throws {
        let rig = try makeDecpamOnRig()
        for (key, final) in keypadDigits {
            try assertPress(key, on: rig, sends: ss3(final), context: "DECPAM on")
        }
    }

    /// Keypad + - * / . = under DECPAM must send ESC O k / m / j / o / n / X.
    /// Today they send the bare operator.
    func test_keyDown_decpamOn_keypadOperators_sendSS3() throws {
        let rig = try makeDecpamOnRig()
        for (key, final) in keypadOperators {
            try assertPress(key, on: rig, sends: ss3(final), context: "DECPAM on")
        }
    }

    /// Holding a keypad key (auto-repeat key-downs) keeps producing the SS3
    /// sequence, one per event -- not a one-shot, not a plain digit.
    func test_keyDown_decpamOn_keypadDigitAutoRepeat_sendsOneSS3PerEvent() throws {
        let rig = try makeDecpamOnRig()
        let kp5 = keypadDigits[5].key
        XCTAssertEqual(kp5.keyCode, 87, "fixture sanity: keypad 5 is key code 87")
        rig.recorder.sent = Data()
        for repeatFlag in [false, true, true] {
            rig.view.keyDown(with: try keyDownEvent(kp5, isARepeat: repeatFlag))
        }
        XCTAssertEqual(rig.recorder.sent, bytes("\u{1B}Ou\u{1B}Ou\u{1B}Ou"),
                       "three keypad-5 key-downs under DECPAM must send three ESC O u; sent \(hex(rig.recorder.sent))")
        XCTAssertEqual(rig.counter.keyDownCount, 0,
                       "no keypad event may be forwarded up the responder chain; "
                       + "forwarded \(rig.counter.keyDownCount) time(s)")
    }

    /// The mode is read live from the current snapshot: the same key flips
    /// from plain to SS3 when the program sends ESC =, and back to plain when
    /// it sends ESC >.
    func test_keyDown_decpamToggled_keypadFollowsTheCurrentMode() throws {
        let rig = try makeDecpamOffRig()
        let kp7 = keypadDigits[7].key
        let kpPlus = keypadOperators[0].key
        XCTAssertEqual(kp7.keyCode, 89, "fixture sanity: keypad 7 is key code 89")
        XCTAssertEqual(kpPlus.keyCode, 69, "fixture sanity: keypad + is key code 69")

        try assertPress(kp7, on: rig, sends: bytes("7"), context: "before ESC =")
        try assertPress(kpPlus, on: rig, sends: bytes("+"), context: "before ESC =")

        rig.term.input("\u{1B}=")
        rig.view.currentSnapshot = try XCTUnwrap(rig.term.snapshot(), "snapshot() returned nil after ESC =")
        XCTAssertTrue(rig.view.currentSnapshot?.termMode.contains(.appKeypad) ?? false,
                      "precondition: ESC = must set .appKeypad")
        try assertPress(kp7, on: rig, sends: ss3("w"), context: "after ESC =")
        try assertPress(kpPlus, on: rig, sends: ss3("k"), context: "after ESC =")

        rig.term.input("\u{1B}>")
        rig.view.currentSnapshot = try XCTUnwrap(rig.term.snapshot(), "snapshot() returned nil after ESC >")
        XCTAssertFalse(rig.view.currentSnapshot?.termMode.contains(.appKeypad) ?? true,
                       "precondition: ESC > must clear .appKeypad")
        try assertPress(kp7, on: rig, sends: bytes("7"), context: "after ESC >")
        try assertPress(kpPlus, on: rig, sends: bytes("+"), context: "after ESC >")
    }
}
