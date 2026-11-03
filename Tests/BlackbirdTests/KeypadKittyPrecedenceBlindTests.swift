import XCTest
import AppKit
import Metal
@testable import Blackbird
import BBCore

/// KEY-4b -- application-keypad mode (DECPAM) must not override the kitty
/// keyboard protocol for numeric-keypad digit and operator keys.
///
/// Contract under test. The SS3 keypad forms (`ESC O p` .. `ESC O y`,
/// `ESC O k/m/j/o/n/X`) are the *legacy* application-keypad encoding. They
/// are for programs that did NOT opt into the kitty keyboard protocol. A
/// program that pushed kitty flags (`CSI > 1 u` disambiguate and/or
/// `CSI > 8 u` report-all-keys) has asked for keys to be reported through the
/// kitty path, and that request wins over DECPAM no matter which of the two
/// the program enabled first:
///
///   * flag 1 only      -> keypad digits/operators are text-producing keys
///                         with no modifier: the bare character ("5", "+").
///   * flag 8 (+/- 1)   -> report-all-keys: `CSI <codepoint> u`, i.e. exactly
///                         what the same key sends with DECPAM *off*.
///   * never            -> `ESC O <letter>` while kitty flags are active.
///
/// Without kitty flags, DECPAM keypad keys stay SS3 (the KEY-4 fix, pinned
/// in `KeypadApplicationModeBlindTests`); the pop test here pins that the
/// SS3 form comes back when the program pops its kitty flags, so a "fix" that
/// simply stops emitting SS3 for keypad keys cannot pass.
///
/// Oracle. The expected bytes are never "whatever the view sent with DECPAM
/// on". They are (a) hard-coded wire bytes for the digit cases, and (b) the
/// independently tested `KeyEncoder.encode(chars:modifiers:mode:)` result for
/// the key's plain character under the snapshot's real mode bits (the same
/// authority `KeyEncoderKeypadModifierTests` uses for the DECPAM-off parity
/// contract: "a DECPAM-off keypad key encodes identically to its plain
/// character"). The DECPAM-off anchors prove the rig delivers those exact
/// bytes today, so a failure in a DECPAM-on test can only be the
/// DECPAM-overrides-kitty precedence bug and never a dead rig or a wrong
/// oracle.
///
/// Fixture realism. A hardware keypad key arrives as a key-down whose
/// `keyCode` is the kVK_ANSI_Keypad* virtual key, whose `characters` are the
/// plain digit/operator, and whose `modifierFlags` carry `.numericPad`. The
/// kitty and DECPAM state are produced by feeding the real `CSI > N u` /
/// `ESC =` bytes to a real `BBTerm` and installing its snapshot on the view
/// (the same authority the product reads at runtime); every rig asserts the
/// resulting mode bits so a mistyped escape fails the fixture rather than the
/// behaviour.
///
/// Memory/time pre-flight: one 640x240 headless `TerminalView` + one 40x6
/// `BBTerm` (scrollback 16) per rig; the busiest test builds ~9 rigs. No
/// window, no PTY, no child process, no runloop pumping, no timers. A few
/// hundred KiB per rig; wall time is dominated by Metal renderer
/// construction.
final class KeypadKittyPrecedenceBlindTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        TestHostTermination.shared.register()
    }

    // MARK: - Escape sequences that build the rigs

    /// `CSI > 1 u` -- push kitty flags: disambiguate escape codes.
    private let kittyFlag1 = "\u{1B}[>1u"
    /// `CSI > 8 u` -- push kitty flags: report all keys as escape codes.
    private let kittyFlag8 = "\u{1B}[>8u"
    /// `CSI > 9 u` -- push kitty flags 1 + 8.
    private let kittyFlag1and8 = "\u{1B}[>9u"
    /// `ESC =` -- DECKPAM, application keypad on.
    private let decpamOn = "\u{1B}="
    /// `CSI < u` -- pop one kitty flag stack entry.
    private let kittyPop = "\u{1B}[<u"

    // MARK: - Key tables

    private struct PhysicalKey {
        let name: String
        let keyCode: UInt16
        let chars: String
        let flags: NSEvent.ModifierFlags
        /// The `ESC O <final>` byte DECPAM sends without kitty flags (nil for
        /// non-keypad control keys).
        let ss3Final: Character?
    }

    /// kVK_ANSI_Keypad0...9. (Key code 90 is F20, not a keypad key, which is
    /// why 8 and 9 sit at 91 and 92.)
    private let keypadDigits: [PhysicalKey] = [
        PhysicalKey(name: "keypad 0", keyCode: 82, chars: "0", flags: [.numericPad], ss3Final: "p"),
        PhysicalKey(name: "keypad 1", keyCode: 83, chars: "1", flags: [.numericPad], ss3Final: "q"),
        PhysicalKey(name: "keypad 2", keyCode: 84, chars: "2", flags: [.numericPad], ss3Final: "r"),
        PhysicalKey(name: "keypad 3", keyCode: 85, chars: "3", flags: [.numericPad], ss3Final: "s"),
        PhysicalKey(name: "keypad 4", keyCode: 86, chars: "4", flags: [.numericPad], ss3Final: "t"),
        PhysicalKey(name: "keypad 5", keyCode: 87, chars: "5", flags: [.numericPad], ss3Final: "u"),
        PhysicalKey(name: "keypad 6", keyCode: 88, chars: "6", flags: [.numericPad], ss3Final: "v"),
        PhysicalKey(name: "keypad 7", keyCode: 89, chars: "7", flags: [.numericPad], ss3Final: "w"),
        PhysicalKey(name: "keypad 8", keyCode: 91, chars: "8", flags: [.numericPad], ss3Final: "x"),
        PhysicalKey(name: "keypad 9", keyCode: 92, chars: "9", flags: [.numericPad], ss3Final: "y"),
    ]

    /// kVK_ANSI_KeypadPlus / Minus / Multiply / Divide / Decimal / Equals.
    private let keypadOperators: [PhysicalKey] = [
        PhysicalKey(name: "keypad +", keyCode: 69, chars: "+", flags: [.numericPad], ss3Final: "k"),
        PhysicalKey(name: "keypad -", keyCode: 78, chars: "-", flags: [.numericPad], ss3Final: "m"),
        PhysicalKey(name: "keypad *", keyCode: 67, chars: "*", flags: [.numericPad], ss3Final: "j"),
        PhysicalKey(name: "keypad /", keyCode: 75, chars: "/", flags: [.numericPad], ss3Final: "o"),
        PhysicalKey(name: "keypad .", keyCode: 65, chars: ".", flags: [.numericPad], ss3Final: "n"),
        PhysicalKey(name: "keypad =", keyCode: 81, chars: "=", flags: [.numericPad], ss3Final: "X"),
    ]

    /// Main-block digit keys: not keypad keys, never SS3, kitty-encoded like
    /// any other printable under flag 8.
    private let topRowDigits: [PhysicalKey] = [
        PhysicalKey(name: "top-row 1", keyCode: 18, chars: "1", flags: [], ss3Final: nil),
        PhysicalKey(name: "top-row 5", keyCode: 23, chars: "5", flags: [], ss3Final: nil),
        PhysicalKey(name: "top-row 9", keyCode: 25, chars: "9", flags: [], ss3Final: nil),
    ]

    // MARK: - Helpers

    private func bytes(_ s: String) -> Data { Data(s.utf8) }

    private func hex(_ d: Data) -> String {
        if d.isEmpty { return "<empty>" }
        let parts: [String] = d.map { (b: UInt8) -> String in String(format: "%02X", b) }
        return parts.joined(separator: " ")
    }

    /// `ESC O <final>`.
    private func ss3(_ final: Character) -> Data { bytes("\u{1B}O\(final)") }

    /// `ESC [ <codepoint> u` for a single-scalar character, no modifiers.
    private func csiU(_ chars: String) -> Data {
        let cp: UInt32 = chars.unicodeScalars.first?.value ?? 0
        return bytes("\u{1B}[\(cp)u")
    }

    private func keyDownEvent(_ key: PhysicalKey) throws -> NSEvent {
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
                isARepeat: false,
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
        let setup: String

        var mode: BBTermMode { view.currentSnapshot?.termMode ?? [] }
    }

    /// One headless view + a 40x6 BBTerm. `setup` is fed to the real parser
    /// and the resulting snapshot (and so `termMode`) is installed on the view.
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
        return Rig(view: view, term: term, session: session, recorder: recorder,
                   counter: counter, setup: setup)
    }

    private func modeDescription(_ mode: BBTermMode) -> String {
        "termMode.rawValue=\(mode.rawValue) "
        + "(appKeypad=\(mode.contains(.appKeypad)), "
        + "disambiguate=\(mode.contains(.disambiguateEscCodes)), "
        + "allKeys=\(mode.contains(.reportAllKeysAsEsc)))"
    }

    /// Rig whose snapshot is asserted to carry exactly the requested mode
    /// bits, so a typo in an escape sequence fails the fixture, not the
    /// behaviour under test.
    private func makeRig(
        feeding setup: String,
        appKeypad: Bool,
        disambiguate: Bool,
        allKeys: Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> Rig {
        let rig = try makeRig(feeding: setup, file: file, line: line)
        let mode = rig.mode
        XCTAssertEqual(mode.contains(.appKeypad), appKeypad,
                       "precondition: setup \(setup.debugDescription) must leave appKeypad=\(appKeypad); "
                       + modeDescription(mode), file: file, line: line)
        XCTAssertEqual(mode.contains(.disambiguateEscCodes), disambiguate,
                       "precondition: setup \(setup.debugDescription) must leave kitty flag 1=\(disambiguate); "
                       + modeDescription(mode), file: file, line: line)
        XCTAssertEqual(mode.contains(.reportAllKeysAsEsc), allKeys,
                       "precondition: setup \(setup.debugDescription) must leave kitty flag 8=\(allKeys); "
                       + modeDescription(mode), file: file, line: line)
        return rig
    }

    /// What the independently tested encoder produces for the key's plain
    /// character under the rig's real kitty mode bits (DECPAM bit stripped:
    /// `KeyEncoderExtendedTests.test_appKeypad_combinedWithDisambiguate_*`
    /// pins that it is a no-op for `encode(chars:)` anyway).
    private func plainCharOracle(_ key: PhysicalKey, in rig: Rig) -> Data {
        KeyEncoder().encode(chars: key.chars, modifiers: [], mode: rig.mode.subtracting(.appKeypad))
    }

    /// Presses `key` once on a clean recorder and returns what reached the
    /// PTY, asserting the event was consumed rather than forwarded up the
    /// responder chain (which ends in the system beep).
    @discardableResult
    private func press(
        _ key: PhysicalKey,
        on rig: Rig,
        context: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> Data {
        rig.recorder.sent = Data()
        let forwardedBefore = rig.counter.keyDownCount
        rig.view.keyDown(with: try keyDownEvent(key))
        XCTAssertEqual(rig.counter.keyDownCount, forwardedBefore,
                       "\(context): \(key.name) must be consumed, not forwarded up the responder chain "
                       + "(that path ends in the system beep); forwarded "
                       + "\(rig.counter.keyDownCount - forwardedBefore) time(s)",
                       file: file, line: line)
        return rig.recorder.sent
    }

    private func assertPress(
        _ key: PhysicalKey,
        on rig: Rig,
        sends expected: Data,
        context: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let sent = try press(key, on: rig, context: context, file: file, line: line)
        XCTAssertEqual(sent, expected,
                       "\(context): \(key.name) (keyCode \(key.keyCode), chars \(key.chars.debugDescription), "
                       + "flags \(key.flags.rawValue)) must send \(hex(expected)); sent \(hex(sent)); "
                       + "setup \(rig.setup.debugDescription), \(modeDescription(rig.mode))",
                       file: file, line: line)
    }

    /// Presses `key` and asserts the bytes are the kitty/plain form `expected`
    /// and in particular are not the legacy SS3 form.
    private func assertKittyPath(
        _ key: PhysicalKey,
        on rig: Rig,
        sends expected: Data,
        context: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let sent = try press(key, on: rig, context: context, file: file, line: line)
        if let final = key.ss3Final {
            XCTAssertNotEqual(sent, ss3(final),
                              "\(context): \(key.name) must NOT send the legacy SS3 form \(hex(ss3(final))) "
                              + "while kitty flags are active; sent \(hex(sent)); "
                              + "setup \(rig.setup.debugDescription), \(modeDescription(rig.mode))",
                              file: file, line: line)
        }
        XCTAssertEqual(sent, expected,
                       "\(context): \(key.name) (keyCode \(key.keyCode), chars \(key.chars.debugDescription)) "
                       + "must be reported through the kitty path as \(hex(expected)); sent \(hex(sent)); "
                       + "setup \(rig.setup.debugDescription), \(modeDescription(rig.mode))",
                       file: file, line: line)
    }

    // MARK: - Harness self-checks and anchors (all pass today)

    /// The escapes this suite feeds really produce the mode bits it relies on,
    /// in either order, and the pop clears the kitty bit while DECPAM stays.
    func test_precondition_kittyFlagsAndDecpam_setSnapshotModeBits() throws {
        _ = try makeRig(feeding: decpamOn + kittyFlag1, appKeypad: true, disambiguate: true, allKeys: false)
        _ = try makeRig(feeding: kittyFlag1 + decpamOn, appKeypad: true, disambiguate: true, allKeys: false)
        _ = try makeRig(feeding: decpamOn + kittyFlag8, appKeypad: true, disambiguate: false, allKeys: true)
        _ = try makeRig(feeding: kittyFlag8 + decpamOn, appKeypad: true, disambiguate: false, allKeys: true)
        _ = try makeRig(feeding: decpamOn + kittyFlag1and8, appKeypad: true, disambiguate: true, allKeys: true)
        _ = try makeRig(feeding: kittyFlag8 + decpamOn + kittyPop, appKeypad: true, disambiguate: false, allKeys: false)
        _ = try makeRig(feeding: decpamOn, appKeypad: true, disambiguate: false, allKeys: false)
    }

    /// Anchor 1: with kitty flag 8 and DECPAM OFF every keypad digit is a
    /// plain `CSI <codepoint> u` today. This pins the wire bytes the DECPAM-on
    /// tests below hard-code, through the same keyDown path.
    func test_anchor_flag8_decpamOff_keypadDigits_areCsiU() throws {
        let rig = try makeRig(feeding: kittyFlag8, appKeypad: false, disambiguate: false, allKeys: true)
        for key in keypadDigits {
            try assertPress(key, on: rig, sends: csiU(key.chars), context: "flag 8, DECPAM off")
        }
        // Spot-check the literal wire bytes so csiU() itself is not the oracle.
        try assertPress(keypadDigits[5], on: rig, sends: Data([0x1B, 0x5B, 0x35, 0x33, 0x75]),
                        context: "flag 8, DECPAM off (literal ESC [ 5 3 u)")
    }

    /// Anchor 2: the operators under flag 8 + DECPAM off equal the encoder's
    /// verdict for their plain characters, and that verdict is a CSI u form
    /// (so the oracle used by the DECPAM-on operator test is not a bare byte).
    func test_anchor_flag8_decpamOff_keypadOperators_matchEncoderOracle() throws {
        let rig = try makeRig(feeding: kittyFlag8, appKeypad: false, disambiguate: false, allKeys: true)
        for key in keypadOperators {
            let oracle = plainCharOracle(key, in: rig)
            XCTAssertTrue(oracle.starts(with: bytes("\u{1B}[")) && oracle.last == 0x75,
                          "oracle sanity: \(key.name) under flag 8 must encode as ESC [ ... u; "
                          + "encoder produced \(hex(oracle))")
            try assertPress(key, on: rig, sends: oracle, context: "flag 8, DECPAM off")
        }
    }

    /// Anchor 3: with kitty flag 1 only and DECPAM OFF the keypad keys are
    /// plain text.
    func test_anchor_flag1_decpamOff_keypadKeys_arePlainText() throws {
        let rig = try makeRig(feeding: kittyFlag1, appKeypad: false, disambiguate: true, allKeys: false)
        for key in keypadDigits + keypadOperators {
            try assertPress(key, on: rig, sends: bytes(key.chars), context: "flag 1, DECPAM off")
        }
    }

    /// Anchor 4: the main-block digits are kitty-encoded under flag 8 with
    /// DECPAM on, so the rig does deliver kitty bytes while DECPAM is set --
    /// a failure of the keypad tests below is specific to the keypad keys.
    func test_anchor_flag8_decpamOn_topRowDigits_areCsiU() throws {
        let rig = try makeRig(feeding: decpamOn + kittyFlag8, appKeypad: true, disambiguate: false, allKeys: true)
        for key in topRowDigits {
            try assertPress(key, on: rig, sends: csiU(key.chars), context: "flag 8, DECPAM on, main block")
        }
    }

    /// Anchor 5 (the KEY-4 contract this bug must not undo): without any
    /// kitty flags, DECPAM keypad digits and operators are SS3.
    func test_anchor_noKitty_decpamOn_keypadKeys_areSS3() throws {
        let rig = try makeRig(feeding: decpamOn, appKeypad: true, disambiguate: false, allKeys: false)
        for key in keypadDigits + keypadOperators {
            guard let final = key.ss3Final else { continue }
            try assertPress(key, on: rig, sends: ss3(final), context: "no kitty flags, DECPAM on")
        }
    }

    // MARK: - The bug: kitty flags active + DECPAM on

    /// Flag 1 (disambiguate) + DECPAM, either enable order: keypad digits and
    /// operators are plain text, exactly what flag 1 + DECPAM-off sends. They
    /// must not become `ESC O <letter>`.
    func test_keyDown_flag1_decpamOn_keypadKeys_arePlainTextNotSS3() throws {
        for setup in [decpamOn + kittyFlag1, kittyFlag1 + decpamOn] {
            let rig = try makeRig(feeding: setup, appKeypad: true, disambiguate: true, allKeys: false)
            for key in keypadDigits + keypadOperators {
                try assertKittyPath(key, on: rig, sends: bytes(key.chars), context: "flag 1, DECPAM on")
            }
        }
    }

    /// Flag 8 (report all keys) + DECPAM, either enable order: keypad digits
    /// are `ESC [ <codepoint> u` (0x30..0x39 -> 48..57), never `ESC O p..y`.
    func test_keyDown_flag8_decpamOn_keypadDigits_areCsiUNotSS3() throws {
        for setup in [decpamOn + kittyFlag8, kittyFlag8 + decpamOn] {
            let rig = try makeRig(feeding: setup, appKeypad: true, disambiguate: false, allKeys: true)
            for key in keypadDigits {
                try assertKittyPath(key, on: rig, sends: csiU(key.chars), context: "flag 8, DECPAM on")
            }
            // Literal wire bytes for keypad 5 so csiU() is not its own oracle.
            try assertKittyPath(keypadDigits[5], on: rig, sends: Data([0x1B, 0x5B, 0x35, 0x33, 0x75]),
                                context: "flag 8, DECPAM on (literal ESC [ 5 3 u)")
        }
    }

    /// Flag 8 + DECPAM: keypad operators are reported exactly as the encoder
    /// reports their plain characters under flag 8 (a CSI u form), never as
    /// `ESC O k/m/j/o/n/X`.
    func test_keyDown_flag8_decpamOn_keypadOperators_matchEncoderOracleNotSS3() throws {
        for setup in [decpamOn + kittyFlag8, kittyFlag8 + decpamOn] {
            let rig = try makeRig(feeding: setup, appKeypad: true, disambiguate: false, allKeys: true)
            for key in keypadOperators {
                try assertKittyPath(key, on: rig, sends: plainCharOracle(key, in: rig),
                                    context: "flag 8, DECPAM on")
            }
        }
    }

    /// Flags 1 + 8 together (the common "full kitty" push) + DECPAM: for every
    /// keypad digit and operator, the bytes with DECPAM on are identical to the
    /// bytes the same key sends with DECPAM off, and are not SS3.
    func test_keyDown_flag1and8_decpamOn_keypadKeys_matchDecpamOffAndNotSS3() throws {
        let off = try makeRig(feeding: kittyFlag1and8, appKeypad: false, disambiguate: true, allKeys: true)
        let on = try makeRig(feeding: decpamOn + kittyFlag1and8, appKeypad: true, disambiguate: true, allKeys: true)
        for key in keypadDigits + keypadOperators {
            let expected = try press(key, on: off, context: "flags 1+8, DECPAM off")
            XCTAssertFalse(expected.isEmpty,
                           "oracle sanity: \(key.name) with flags 1+8 and DECPAM off must send something")
            try assertKittyPath(key, on: on, sends: expected, context: "flags 1+8, DECPAM on")
        }
    }

    /// The precedence follows the live kitty state, not DECPAM history: with
    /// flag 8 pushed the keypad is kitty-encoded; after the program pops its
    /// kitty flags (`CSI < u`) with DECPAM still on, the same keypad keys go
    /// back to SS3. This keeps a "fix" that merely stops emitting SS3 for
    /// keypad keys from passing.
    func test_keyDown_decpamOn_kittyPushedThenPopped_keypadFollowsLiveKittyState() throws {
        let rig = try makeRig(feeding: decpamOn + kittyFlag8, appKeypad: true, disambiguate: false, allKeys: true)
        let kp5 = keypadDigits[5]
        let kpPlus = keypadOperators[0]
        XCTAssertEqual(kp5.keyCode, 87, "fixture sanity: keypad 5 is key code 87")
        XCTAssertEqual(kpPlus.keyCode, 69, "fixture sanity: keypad + is key code 69")

        try assertKittyPath(kp5, on: rig, sends: csiU("5"), context: "flag 8 pushed, DECPAM on")
        try assertKittyPath(kpPlus, on: rig, sends: plainCharOracle(kpPlus, in: rig),
                            context: "flag 8 pushed, DECPAM on")

        rig.term.input(kittyPop)
        rig.view.currentSnapshot = try XCTUnwrap(rig.term.snapshot(), "snapshot() returned nil after CSI < u")
        XCTAssertTrue(rig.mode.contains(.appKeypad) && !rig.mode.contains(.reportAllKeysAsEsc)
                      && !rig.mode.contains(.disambiguateEscCodes),
                      "precondition: CSI < u must clear the kitty flags and leave DECPAM on; "
                      + modeDescription(rig.mode))

        try assertPress(kp5, on: rig, sends: ss3("u"), context: "kitty flags popped, DECPAM on")
        try assertPress(kpPlus, on: rig, sends: ss3("k"), context: "kitty flags popped, DECPAM on")
    }
}
