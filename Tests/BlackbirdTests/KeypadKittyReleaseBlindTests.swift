import XCTest
import AppKit
@testable import Blackbird
import BBCore

/// XL-keypad-release -- Kitty flag 2 (`reportEventTypes`): numeric-keypad keys
/// that are reported to the program as escape codes on the way DOWN must also
/// be reported on the way UP.
///
/// Contract under test (https://sw.kovidgoyal.net/kitty/keyboard-protocol/,
/// "Report event types"). A TUI that pushes flag 2 asks to be told, for every
/// key that is sent as an escape code, whether the event was a press (1), a
/// repeat (2) or a release (3). A program that tracks key state (hold / chord /
/// auto-repeat logic in helix, crossterm, Zellij-style clients, games) pairs
/// the three events of one physical key: whatever it was told on the press, it
/// must be told on the release (same key code, same modifier field, event type
/// `:3`). A key that goes down as `CSI 53 u` and never comes up looks held
/// forever.
///
/// Two ways a keypad key becomes an escape code on the press:
///
///   1. Kitty flag 8 (`reportAllKeysAsEsc`), with or without flag 1: every
///      key, keypad digits / operators / Enter included, is `CSI <cp> u`
///      (`ESC [ 5 3 u` for keypad 5). DECPAM (application keypad) does not
///      change that -- kitty wins over the legacy SS3 keypad forms (pinned by
///      `KeypadKittyPrecedenceBlindTests`). The release is the same key with
///      the event-type sub-parameter: `ESC [ 5 3 ; 1 : 3 u`.
///   2. Kitty flags 1+2 with a Ctrl or Option(Meta) modifier on a keypad digit:
///      press `ESC [ 5 3 ; 5 u` (Ctrl) or `ESC [ 5 3 ; 3 u` (Option),
///      release `ESC [ 5 3 ; 5 : 3 u` / `ESC [ 5 3 ; 3 : 3 u`.
///
/// Oracle. The expected release is never "whatever the view sent". It is the
/// hard-coded wire form of the same key's PRESS with the `:3` event type added
/// to the modifier field (keypad Enter, whose press shape is not hard-coded
/// here, derives it from the observed press). Every test first asserts the
/// press bytes, which are right today, so a red result can only be the missing
/// release and never a dead rig or a wrong key fixture. The main-row digit 5
/// is pinned as an anchor (press AND release pair today), and releases that are
/// correctly silent (flag 2 off; a plain text keypad key under flags 1+2) are
/// pinned next to the failing claims so a "fix" that reports every keypad
/// release unconditionally cannot pass.
///
/// Fixture realism. A hardware keypad key arrives as a key event whose
/// `keyCode` is the kVK_ANSI_Keypad* virtual key (digits 82...92 with 90
/// skipped, operators 65/67/69/75/78/81, Enter 76), whose `characters` are the
/// plain digit / operator (Enter: ETX, U+0003) and whose `modifierFlags` carry
/// `.numericPad`; the key-up carries the same flags as the key-down. Mode bits
/// are produced by feeding the real `CSI > n u` / `ESC =` bytes to a real
/// `BBTerm`, and every rig asserts the bits it relies on.
///
/// Written blind: no `KeyEncoder` / `TerminalView` / `KeyEventClassifier` body
/// was read; only declarations, doc comments and sibling tests.
///
/// Review follow-ups (added after the fix, NOT blind): the last two sections
/// pin (a) a keypad key whose layout text differs from the US table, where the
/// release must pair with whatever the press reported, and (b) the SS3 guard
/// (DECPAM on, kitty flag 2 only), where a keypad release must stay empty.
///
/// Memory/time pre-flight: one headless `TerminalView` (100x100 frame) + one
/// 40x6 `BBTerm` (scrollback 16) per rig, at most two rigs per test; no
/// window, no PTY, no child process, no timers, no runloop pumping. A few
/// hundred KiB each; wall time is dominated by Metal renderer construction.
final class KeypadKittyReleaseBlindTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        TestHostTermination.shared.register()
    }

    // MARK: - Escape sequences that build the rigs

    /// `CSI > 10 u`: kitty flags 2 (report event types) + 8 (report all keys).
    private let push2and8 = "\u{1B}[>10u"
    /// `CSI > 11 u`: kitty flags 1 + 2 + 8.
    private let push1and2and8 = "\u{1B}[>11u"
    /// `CSI > 3 u`: kitty flags 1 (disambiguate) + 2 (report event types).
    private let push1and2 = "\u{1B}[>3u"
    /// `CSI > 8 u`: kitty flag 8 only (no event types).
    private let push8 = "\u{1B}[>8u"
    /// `ESC =`: DECKPAM, application keypad on.
    private let decpamOn = "\u{1B}="

    // MARK: - Formatting helpers

    private func hex(_ d: Data) -> String {
        d.isEmpty ? "<empty>" : d.map { String(format: "%02X", $0) }.joined(separator: " ")
    }

    /// Human-readable wire form: `ESC` for 0x1B, the character for printable
    /// ASCII, `\xNN` otherwise.
    private func show(_ d: Data) -> String {
        if d.isEmpty { return "<empty>" }
        return d.map { (b: UInt8) -> String in
            switch b {
            case 0x1B: return "ESC "
            case 0x20...0x7E: return String(UnicodeScalar(b)) + " "
            default: return String(format: "\\x%02X ", b)
            }
        }.joined().trimmingCharacters(in: .whitespaces)
    }

    private func wire(_ s: String) -> String { show(Data(s.utf8)) }

    /// `ESC [ <cp> u`, or `ESC [ <cp> ; <mod> u` when `mod != nil`, or with an
    /// event type `ESC [ <cp> ; <mod> : <event> u`.
    private func csiU(_ cp: Int, mod: Int? = nil, event: Int? = nil) -> String {
        var s = "\u{1B}[\(cp)"
        if let m = mod {
            s += ";\(m)"
            if let e = event { s += ":\(e)" }
        } else if let e = event {
            s += ";1:\(e)"
        }
        return s + "u"
    }

    /// The release form of a CSI u press: `ESC [ cp u` -> `ESC [ cp ; 1 : 3 u`,
    /// `ESC [ cp ; mod u` -> `ESC [ cp ; mod : 3 u`. nil when `press` is not a
    /// plain (no sub-parameter) CSI u.
    private func releaseForm(ofPress press: Data) -> String? {
        guard let s = String(data: press, encoding: .utf8),
              s.hasPrefix("\u{1B}["), s.hasSuffix("u") else { return nil }
        let body = String(s.dropFirst(2).dropLast())
        if body.contains(":") { return nil }
        let parts: [String] = body.split(separator: ";", omittingEmptySubsequences: false).map { String($0) }
        switch parts.count {
        case 1: return "\u{1B}[\(parts[0]);1:3u"
        case 2: return "\u{1B}[\(parts[0]);\(parts[1]):3u"
        default: return nil
        }
    }

    // MARK: - Key table

    private struct PhysKey {
        let name: String
        let keyCode: UInt16
        let chars: String
        /// Flags the key itself brings (`.numericPad` for keypad keys).
        let baseFlags: NSEvent.ModifierFlags
        /// Code point the kitty CSI u form reports for this key.
        let cp: Int
        /// The `ESC O <final>` byte DECPAM sends without kitty flags.
        let ss3Final: Character?
    }

    private func kp(_ name: String, _ code: UInt16, _ ch: String, _ ss3: Character) -> PhysKey {
        PhysKey(name: name, keyCode: code, chars: ch, baseFlags: [.numericPad],
                cp: Int(ch.unicodeScalars.first!.value), ss3Final: ss3)
    }

    /// kVK_ANSI_Keypad0...9 (key code 90 is F20, hence 8 and 9 at 91 and 92).
    private var keypadDigits: [PhysKey] {
        [
            kp("keypad 0", 82, "0", "p"), kp("keypad 1", 83, "1", "q"),
            kp("keypad 2", 84, "2", "r"), kp("keypad 3", 85, "3", "s"),
            kp("keypad 4", 86, "4", "t"), kp("keypad 5", 87, "5", "u"),
            kp("keypad 6", 88, "6", "v"), kp("keypad 7", 89, "7", "w"),
            kp("keypad 8", 91, "8", "x"), kp("keypad 9", 92, "9", "y"),
        ]
    }

    /// kVK_ANSI_KeypadPlus / Minus / Multiply / Divide / Decimal / Equals.
    private var keypadOperators: [PhysKey] {
        [
            kp("keypad +", 69, "+", "k"), kp("keypad -", 78, "-", "m"),
            kp("keypad *", 67, "*", "j"), kp("keypad /", 75, "/", "o"),
            kp("keypad .", 65, ".", "n"), kp("keypad =", 81, "=", "X"),
        ]
    }

    private var keypad5: PhysKey { keypadDigits[5] }

    /// kVK_ANSI_KeypadEnter: reports ETX as its character.
    private var keypadEnter: PhysKey {
        PhysKey(name: "keypad Enter", keyCode: 76, chars: "\u{03}", baseFlags: [.numericPad],
                cp: 13, ss3Final: "M")
    }

    /// Main-block digit 5 (kVK_ANSI_5): the key the keypad 5 must pair like.
    private var topRow5: PhysKey {
        PhysKey(name: "top-row 5", keyCode: 23, chars: "5", baseFlags: [], cp: 53, ss3Final: nil)
    }

    // MARK: - Rig

    private struct Rig {
        let view: TerminalView
        let term: BBTerm
        let session: TerminalSession
        let recorder: RecordingPTY
        let snapshot: BBSnapshot
        let setup: String
        var mode: BBTermMode { snapshot.termMode }
    }

    private func modeDescription(_ mode: BBTermMode) -> String {
        "termMode.rawValue=\(mode.rawValue) "
        + "(appKeypad=\(mode.contains(.appKeypad)), disambiguate=\(mode.contains(.disambiguateEscCodes)), "
        + "eventTypes=\(mode.contains(.reportEventTypes)), allKeys=\(mode.contains(.reportAllKeysAsEsc)))"
    }

    /// One headless view + a 40x6 BBTerm. `setup` is fed to the real parser and
    /// the resulting snapshot (and so `termMode`) is installed on the view. The
    /// snapshot is asserted to carry exactly the wanted mode bits so a mistyped
    /// escape fails the fixture, not the behaviour under test.
    private func makeRig(
        feeding setup: String,
        appKeypad: Bool,
        disambiguate: Bool,
        eventTypes: Bool,
        allKeys: Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> Rig {
        let view = try XCTUnwrap(TerminalView.makeHeadlessForTests(),
                                 "Metal device required", file: file, line: line)
        let term = try XCTUnwrap(BBTerm(size: .init(cols: 40, rows: 6), scrollback: 16),
                                 "BBTerm init failed", file: file, line: line)
        term.input(setup)
        let snapshot = try XCTUnwrap(term.snapshot(), "snapshot() returned nil", file: file, line: line)
        let session = TerminalSession.makeHeadlessForTests()
        view.session = session
        view.currentSnapshot = snapshot
        let recorder = RecordingPTY()
        view.ptyRecorderForTests = recorder
        let rig = Rig(view: view, term: term, session: session, recorder: recorder,
                      snapshot: snapshot, setup: setup)
        let mode = rig.mode
        XCTAssertEqual(mode.contains(.appKeypad), appKeypad,
                       "precondition: setup \(setup.debugDescription) must leave appKeypad=\(appKeypad); "
                       + modeDescription(mode), file: file, line: line)
        XCTAssertEqual(mode.contains(.disambiguateEscCodes), disambiguate,
                       "precondition: setup \(setup.debugDescription) must leave kitty flag 1=\(disambiguate); "
                       + modeDescription(mode), file: file, line: line)
        XCTAssertEqual(mode.contains(.reportEventTypes), eventTypes,
                       "precondition: setup \(setup.debugDescription) must leave kitty flag 2=\(eventTypes); "
                       + modeDescription(mode), file: file, line: line)
        XCTAssertEqual(mode.contains(.reportAllKeysAsEsc), allKeys,
                       "precondition: setup \(setup.debugDescription) must leave kitty flag 8=\(allKeys); "
                       + modeDescription(mode), file: file, line: line)
        return rig
    }

    private func event(
        _ type: NSEvent.EventType, _ key: PhysKey, flags: NSEvent.ModifierFlags
    ) throws -> NSEvent {
        try XCTUnwrap(
            NSEvent.keyEvent(
                with: type,
                location: .zero,
                modifierFlags: key.baseFlags.union(flags),
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

    private func down(_ key: PhysKey, flags: NSEvent.ModifierFlags = [], on rig: Rig) throws -> Data {
        rig.recorder.sent = Data()
        rig.view.keyDown(with: try event(.keyDown, key, flags: flags))
        return rig.recorder.sent
    }

    private func up(_ key: PhysKey, flags: NSEvent.ModifierFlags = [], on rig: Rig) throws -> Data {
        rig.recorder.sent = Data()
        rig.view.keyUp(with: try event(.keyUp, key, flags: flags))
        return rig.recorder.sent
    }

    /// Press then release `key` on `rig` and assert the matched pair:
    /// `pressWire` (hard-coded, right today) then `releaseWire`.
    private func assertPressThenRelease(
        _ key: PhysKey, flags: NSEvent.ModifierFlags = [], on rig: Rig,
        pressWire: String, releaseWire: String, context: String,
        file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let label = key.name + (flags.isEmpty ? "" : " (+flags \(flags.rawValue))")
        let pressed = try down(key, flags: flags, on: rig)
        XCTAssertEqual(show(pressed), wire(pressWire),
                       "\(context): precondition: \(label) PRESS must be \(wire(pressWire)); "
                       + "got \(show(pressed)) [hex \(hex(pressed))]; setup \(rig.setup.debugDescription), "
                       + modeDescription(rig.mode),
                       file: file, line: line)
        let released = try up(key, flags: flags, on: rig)
        XCTAssertEqual(show(released), wire(releaseWire),
                       "\(context): \(label) RELEASE (press was \(show(pressed))) must be "
                       + "\(wire(releaseWire)); got \(show(released)) [hex \(hex(released))]; "
                       + "setup \(rig.setup.debugDescription), \(modeDescription(rig.mode))",
                       file: file, line: line)
    }

    // MARK: - Anchors (all pass today; prove the rig is alive and the key table right)

    /// The main-row digit 5 under flags 2+8 pairs press and release today. This
    /// is the working twin of the keypad-5 tests below: same mode, same code
    /// point, same wire shape -- only the physical key differs.
    func test_anchor_mainRowDigit5_flags2and8_pairsPressAndRelease() throws {
        let rig = try makeRig(feeding: push2and8, appKeypad: false, disambiguate: false,
                              eventTypes: true, allKeys: true)
        XCTAssertEqual(topRow5.keyCode, 23, "fixture sanity: top-row 5 is kVK_ANSI_5 (23)")
        try assertPressThenRelease(topRow5, on: rig,
                                   pressWire: csiU(53), releaseWire: csiU(53, mod: 1, event: 3),
                                   context: "anchor, main row, flags 2+8")
    }

    /// Ctrl+top-row 5 under flags 1+2 pairs press and release today (the
    /// second trigger's working twin).
    func test_anchor_mainRowCtrl5_flags1and2_pairsPressAndRelease() throws {
        let rig = try makeRig(feeding: push1and2, appKeypad: false, disambiguate: true,
                              eventTypes: true, allKeys: false)
        try assertPressThenRelease(topRow5, flags: [.control], on: rig,
                                   pressWire: csiU(53, mod: 5), releaseWire: csiU(53, mod: 5, event: 3),
                                   context: "anchor, main row, flags 1+2, Ctrl")
    }

    /// Must-not-change: a release is only reported when flag 2 is on. With flag
    /// 8 alone the keypad press is `CSI 53 u` but the release stays silent.
    func test_anchor_keypadRelease_flag8WithoutFlag2_staysSilent() throws {
        let rig = try makeRig(feeding: push8, appKeypad: false, disambiguate: false,
                              eventTypes: false, allKeys: true)
        let pressed = try down(keypad5, on: rig)
        XCTAssertEqual(show(pressed), wire(csiU(53)),
                       "anchor: keypad 5 PRESS under flag 8 alone must be ESC [ 5 3 u; got \(show(pressed))")
        let released = try up(keypad5, on: rig)
        XCTAssertEqual(hex(released), hex(Data()),
                       "anchor: keypad 5 RELEASE without flag 2 must stay silent; got \(show(released)) [hex \(hex(released))]")
    }

    /// Must-not-change: under flags 1+2 an UNMODIFIED keypad digit is plain
    /// text on the way down (the bare character, no escape code), so there is
    /// nothing to pair a release with and the release stays silent.
    func test_anchor_plainKeypadDigit_flags1and2_pressIsTextAndReleaseStaysSilent() throws {
        let rig = try makeRig(feeding: push1and2, appKeypad: false, disambiguate: true,
                              eventTypes: true, allKeys: false)
        let pressed = try down(keypad5, on: rig)
        XCTAssertEqual(show(pressed), "5",
                       "anchor: plain keypad 5 PRESS under flags 1+2 is the bare text '5'; got \(show(pressed))")
        let released = try up(keypad5, on: rig)
        XCTAssertEqual(hex(released), hex(Data()),
                       "anchor: plain keypad 5 RELEASE under flags 1+2 (press was text) must stay silent; "
                       + "got \(show(released)) [hex \(hex(released))]")
    }

    // MARK: - Encoder level

    /// `encodeSpecial` is the entry point keypad keys take when the view routes
    /// them as keypad keys. Under flags 2+8 the release of every keypad key
    /// (DECPAM on or off) is the key's `CSI <cp> ; 1 : 3 u`.
    func test_encoder_keypadKeys_release_flags2and8_reportsReleaseEvent() {
        let enc = KeyEncoder()
        let mode: BBTermMode = [.reportEventTypes, .reportAllKeysAsEsc]
        let table: [(KeyEncoder.SpecialKey, PhysKey)] = [
            (.kp0, keypadDigits[0]), (.kp1, keypadDigits[1]), (.kp2, keypadDigits[2]),
            (.kp3, keypadDigits[3]), (.kp4, keypadDigits[4]), (.kp5, keypadDigits[5]),
            (.kp6, keypadDigits[6]), (.kp7, keypadDigits[7]), (.kp8, keypadDigits[8]),
            (.kp9, keypadDigits[9]),
            (.kpPlus, keypadOperators[0]), (.kpMinus, keypadOperators[1]),
            (.kpMultiply, keypadOperators[2]), (.kpDivide, keypadOperators[3]),
            (.kpDecimal, keypadOperators[4]), (.kpEquals, keypadOperators[5]),
        ]
        for decpam in [false, true] {
            for (special, phys) in table {
                let ctx = "KeyEncoder.encodeSpecial(\(special), flags 2+8, applicationKeypad=\(decpam))"
                let press = enc.encodeSpecial(special, modifiers: [], applicationKeypad: decpam,
                                              mode: mode, eventType: .press)
                XCTAssertEqual(show(press), wire(csiU(phys.cp)),
                               "\(ctx): precondition: \(phys.name) PRESS must be \(wire(csiU(phys.cp))); "
                               + "got \(show(press)) [hex \(hex(press))]")
                let release = enc.encodeSpecial(special, modifiers: [], applicationKeypad: decpam,
                                                mode: mode, eventType: .release)
                XCTAssertEqual(show(release), wire(csiU(phys.cp, mod: 1, event: 3)),
                               "\(ctx): \(phys.name) RELEASE must be \(wire(csiU(phys.cp, mod: 1, event: 3))); "
                               + "got \(show(release)) [hex \(hex(release))]")
            }
        }
    }

    func test_encoder_keypadEnter_release_flags2and8_pairsWithItsPress() {
        let enc = KeyEncoder()
        let mode: BBTermMode = [.reportEventTypes, .reportAllKeysAsEsc]
        for decpam in [false, true] {
            let ctx = "KeyEncoder.encodeSpecial(.kpEnter, flags 2+8, applicationKeypad=\(decpam))"
            let press = enc.encodeSpecial(.kpEnter, modifiers: [], applicationKeypad: decpam,
                                          mode: mode, eventType: .press)
            guard let expectedRelease = releaseForm(ofPress: press) else {
                XCTFail("\(ctx): precondition: keypad Enter PRESS must be a plain CSI u under flag 8; "
                        + "got \(show(press)) [hex \(hex(press))]")
                continue
            }
            let release = enc.encodeSpecial(.kpEnter, modifiers: [], applicationKeypad: decpam,
                                            mode: mode, eventType: .release)
            XCTAssertEqual(show(release), wire(expectedRelease),
                           "\(ctx): keypad Enter RELEASE (press was \(show(press))) must be "
                           + "\(wire(expectedRelease)); got \(show(release)) [hex \(hex(release))]")
        }
    }

    /// Second trigger at the encoder: Ctrl+keypad 5 and Option+keypad 5 under
    /// flags 1+2 are `CSI 53 ; 5 u` / `CSI 53 ; 3 u` on the way down and must
    /// be `CSI 53 ; 5 : 3 u` / `CSI 53 ; 3 : 3 u` on the way up.
    func test_encoder_keypad5_release_flags1and2_ctrlAndOption_reportsReleaseEvent() {
        let enc = KeyEncoder(optionIsMeta: true)
        let mode: BBTermMode = [.disambiguateEscCodes, .reportEventTypes]
        let cases: [(KeyEncoder.Modifiers, String, Int)] = [(.control, "Ctrl", 5), (.option, "Option", 3)]
        for (mods, name, modField) in cases {
            let ctx = "KeyEncoder.encodeSpecial(.kp5, flags 1+2, \(name))"
            let press = enc.encodeSpecial(.kp5, modifiers: mods, mode: mode, eventType: .press)
            XCTAssertEqual(show(press), wire(csiU(53, mod: modField)),
                           "\(ctx): precondition: \(name)+keypad 5 PRESS must be \(wire(csiU(53, mod: modField))); "
                           + "got \(show(press)) [hex \(hex(press))]")
            let release = enc.encodeSpecial(.kp5, modifiers: mods, mode: mode, eventType: .release)
            XCTAssertEqual(show(release), wire(csiU(53, mod: modField, event: 3)),
                           "\(ctx): \(name)+keypad 5 RELEASE must be \(wire(csiU(53, mod: modField, event: 3))); "
                           + "got \(show(release)) [hex \(hex(release))]")
        }
    }

    // MARK: - View level: flag 8 (flags 2+8 / 1+2+8), no modifiers

    /// Every keypad digit and operator, pressed and released as AppKit
    /// delivers them, pairs under the given kitty push.
    private func assertKeypadKeysPair(
        setup: String, decpam: Bool, disambiguate: Bool, context: String,
        file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let rig = try makeRig(feeding: (decpam ? decpamOn : "") + setup, appKeypad: decpam,
                              disambiguate: disambiguate, eventTypes: true, allKeys: true,
                              file: file, line: line)
        for key in keypadDigits + keypadOperators {
            try assertPressThenRelease(key, on: rig,
                                       pressWire: csiU(key.cp), releaseWire: csiU(key.cp, mod: 1, event: 3),
                                       context: context, file: file, line: line)
        }
    }

    func test_view_keypadKeys_pressAndRelease_flags2and8_decpamOff() throws {
        try assertKeypadKeysPair(setup: push2and8, decpam: false, disambiguate: false,
                                 context: "flags 2+8, DECPAM off")
    }

    func test_view_keypadKeys_pressAndRelease_flags1and2and8_decpamOff() throws {
        try assertKeypadKeysPair(setup: push1and2and8, decpam: false, disambiguate: true,
                                 context: "flags 1+2+8, DECPAM off")
    }

    func test_view_keypadKeys_pressAndRelease_flags2and8_decpamOn() throws {
        try assertKeypadKeysPair(setup: push2and8, decpam: true, disambiguate: false,
                                 context: "flags 2+8, DECPAM on")
    }

    func test_view_keypadKeys_pressAndRelease_flags1and2and8_decpamOn() throws {
        try assertKeypadKeysPair(setup: push1and2and8, decpam: true, disambiguate: true,
                                 context: "flags 1+2+8, DECPAM on")
    }

    /// Keypad Enter under flags 2+8, DECPAM off and on. Its press shape is not
    /// hard-coded (the Enter code point is the encoder's call); the release
    /// must be that same CSI u with the `:3` event type.
    func test_view_keypadEnter_pressAndRelease_flags2and8() throws {
        for decpam in [false, true] {
            let rig = try makeRig(feeding: (decpam ? decpamOn : "") + push2and8, appKeypad: decpam,
                                  disambiguate: false, eventTypes: true, allKeys: true)
            let ctx = "flags 2+8, DECPAM \(decpam ? "on" : "off")"
            let pressed = try down(keypadEnter, on: rig)
            guard let expectedRelease = releaseForm(ofPress: pressed) else {
                XCTFail("\(ctx): precondition: keypad Enter PRESS must be a plain CSI u under flag 8; "
                        + "got \(show(pressed)) [hex \(hex(pressed))]; setup \(rig.setup.debugDescription), "
                        + modeDescription(rig.mode))
                continue
            }
            let released = try up(keypadEnter, on: rig)
            XCTAssertEqual(show(released), wire(expectedRelease),
                           "\(ctx): keypad Enter RELEASE (press was \(show(pressed))) must be "
                           + "\(wire(expectedRelease)); got \(show(released)) [hex \(hex(released))]; "
                           + "setup \(rig.setup.debugDescription), \(modeDescription(rig.mode))")
        }
    }

    // MARK: - View level: flags 1+2 with Ctrl / Option on a keypad digit

    func test_view_ctrlKeypad5_pressAndRelease_flags1and2() throws {
        let rig = try makeRig(feeding: push1and2, appKeypad: false, disambiguate: true,
                              eventTypes: true, allKeys: false)
        try assertPressThenRelease(keypad5, flags: [.control], on: rig,
                                   pressWire: csiU(53, mod: 5), releaseWire: csiU(53, mod: 5, event: 3),
                                   context: "flags 1+2, Ctrl")
    }

    func test_view_optionKeypad5_pressAndRelease_flags1and2() throws {
        let rig = try makeRig(feeding: push1and2, appKeypad: false, disambiguate: true,
                              eventTypes: true, allKeys: false)
        try assertPressThenRelease(keypad5, flags: [.option], on: rig,
                                   pressWire: csiU(53, mod: 3), releaseWire: csiU(53, mod: 3, event: 3),
                                   context: "flags 1+2, Option(Meta)")
    }

    /// The same two chords with DECPAM on: kitty wins over the SS3 keypad forms
    /// (KEY-4b), so the pairing must hold there too.
    func test_view_ctrlAndOptionKeypad5_pressAndRelease_flags1and2_decpamOn() throws {
        let rig = try makeRig(feeding: decpamOn + push1and2, appKeypad: true, disambiguate: true,
                              eventTypes: true, allKeys: false)
        try assertPressThenRelease(keypad5, flags: [.control], on: rig,
                                   pressWire: csiU(53, mod: 5), releaseWire: csiU(53, mod: 5, event: 3),
                                   context: "flags 1+2, DECPAM on, Ctrl")
        try assertPressThenRelease(keypad5, flags: [.option], on: rig,
                                   pressWire: csiU(53, mod: 3), releaseWire: csiU(53, mod: 3, event: 3),
                                   context: "flags 1+2, DECPAM on, Option(Meta)")
    }

    // MARK: - Layout text that differs from the US keypad table

    /// A keypad key as a non-US layout / input source delivers it: the same
    /// virtual key code, different text.
    private struct LayoutKey {
        let name: String
        let keyCode: UInt16
        let text: String
        /// Code point of the US-table character the encoder falls back to.
        let usCp: Int
    }

    /// Comma-decimal layouts (German, French, ...) put `,` on the keypad
    /// decimal key; some non-Latin input sources put Arabic-Indic digits on the
    /// keypad. Both differ from the US character the encoder keeps for a
    /// keypad key.
    private var layoutKeys: [LayoutKey] {
        [
            LayoutKey(name: "keypad decimal (comma-decimal layout)", keyCode: 65, text: ",", usCp: 46),
            LayoutKey(name: "keypad 5 (Arabic-Indic digit input source)", keyCode: 87, text: "\u{0665}", usCp: 53),
        ]
    }

    /// Whatever code point the key-down reported, the key-up must report the
    /// SAME one with the `:3` event type. The key-down is observed, not
    /// assumed: with a live input context AppKit commits the layout text
    /// through `insertText` (`CSI 44 u`); without one, or with DECPAM on
    /// (which bypasses the input context), the press is the US-table character
    /// (`CSI 46 u`). Both are legal; a release for the OTHER code point leaves
    /// the pressed key held forever and releases a key never pressed.
    func test_view_keypadKeyWithLayoutText_releasePairsWithObservedPress() throws {
        for decpam in [false, true] {
            let rig = try makeRig(feeding: (decpam ? decpamOn : "") + push2and8, appKeypad: decpam,
                                  disambiguate: false, eventTypes: true, allKeys: true)
            for layout in layoutKeys {
                let key = PhysKey(name: layout.name, keyCode: layout.keyCode, chars: layout.text,
                                  baseFlags: [.numericPad], cp: layout.usCp, ss3Final: nil)
                let textCp = Int(layout.text.unicodeScalars.first!.value)
                let ctx = "flags 2+8, DECPAM \(decpam ? "on" : "off")"
                let pressed = try down(key, on: rig)
                XCTAssertTrue(
                    show(pressed) == wire(csiU(textCp)) || show(pressed) == wire(csiU(layout.usCp)),
                    "\(ctx): precondition: \(layout.name) PRESS must report the layout text "
                    + "\(wire(csiU(textCp))) or the US-table character \(wire(csiU(layout.usCp))); "
                    + "got \(show(pressed)) [hex \(hex(pressed))]; \(modeDescription(rig.mode))")
                guard let expectedRelease = releaseForm(ofPress: pressed) else {
                    XCTFail("\(ctx): precondition: \(layout.name) PRESS must be a plain CSI u; "
                            + "got \(show(pressed)) [hex \(hex(pressed))]")
                    continue
                }
                let released = try up(key, on: rig)
                XCTAssertEqual(show(released), wire(expectedRelease),
                               "\(ctx): \(layout.name) RELEASE (press was \(show(pressed))) must be "
                               + "\(wire(expectedRelease)); got \(show(released)) [hex \(hex(released))]; "
                               + "\(modeDescription(rig.mode))")
            }
        }
    }

    // MARK: - DECPAM (SS3) keypad keys have no release form

    /// DECPAM on with kitty flag 2 alone (no flag 1 or 8): the keypad key is
    /// the legacy `ESC O <final>`, which has no event field, so a release must
    /// not replay it. A held key still repeats the SS3 bytes.
    func test_encoder_keypadKeys_ss3_flag2Only_releaseIsEmpty_repeatReplaysSS3() {
        let enc = KeyEncoder()
        let mode: BBTermMode = [.reportEventTypes]
        let table: [(KeyEncoder.SpecialKey, PhysKey)] = [
            (.kp0, keypadDigits[0]), (.kp1, keypadDigits[1]), (.kp5, keypadDigits[5]),
            (.kp9, keypadDigits[9]),
            (.kpPlus, keypadOperators[0]), (.kpMinus, keypadOperators[1]),
            (.kpMultiply, keypadOperators[2]), (.kpDivide, keypadOperators[3]),
            (.kpDecimal, keypadOperators[4]), (.kpEquals, keypadOperators[5]),
        ]
        for (special, phys) in table {
            let ctx = "KeyEncoder.encodeSpecial(\(special), DECPAM on, flag 2 only)"
            let ss3 = "\u{1B}O\(phys.ss3Final!)"
            let press = enc.encodeSpecial(special, modifiers: [], applicationKeypad: true,
                                          mode: mode, eventType: .press)
            XCTAssertEqual(show(press), wire(ss3),
                           "\(ctx): precondition: \(phys.name) PRESS must be \(wire(ss3)); got \(show(press))")
            let release = enc.encodeSpecial(special, modifiers: [], applicationKeypad: true,
                                            mode: mode, eventType: .release)
            XCTAssertEqual(hex(release), hex(Data()),
                           "\(ctx): \(phys.name) RELEASE must stay silent (SS3 has no event field); "
                           + "got \(show(release)) [hex \(hex(release))]")
            let repeated = enc.encodeSpecial(special, modifiers: [], applicationKeypad: true,
                                             mode: mode, eventType: .repeat)
            XCTAssertEqual(show(repeated), wire(ss3),
                           "\(ctx): \(phys.name) REPEAT must keep re-sending \(wire(ss3)); got \(show(repeated))")
        }
    }

    /// The same at the view: DECPAM on + `CSI > 2 u`, keypad 5 goes down as
    /// `ESC O u` and comes up silent.
    func test_view_keypad5_decpamOn_flag2Only_pressIsSS3AndReleaseStaysSilent() throws {
        let rig = try makeRig(feeding: decpamOn + "\u{1B}[>2u", appKeypad: true, disambiguate: false,
                              eventTypes: true, allKeys: false)
        let pressed = try down(keypad5, on: rig)
        XCTAssertEqual(show(pressed), wire("\u{1B}Ou"),
                       "precondition: keypad 5 PRESS under DECPAM + flag 2 only must be ESC O u; got \(show(pressed))")
        let released = try up(keypad5, on: rig)
        XCTAssertEqual(hex(released), hex(Data()),
                       "keypad 5 RELEASE under DECPAM + flag 2 only must stay silent; "
                       + "got \(show(released)) [hex \(hex(released))]")
    }
}
