import XCTest
import AppKit
@testable import Blackbird
@testable import BBCore

/// ime-1 -- modified Enter / Return / Tab / Esc keys must reach the program
/// with their modifiers, not as a bare control character.
///
/// Contract under test (terminal convention, plus the encoder contracts the
/// sibling suites already pin):
///
///   1. Shift + numeric-keypad Enter. A hardware keypad Enter reports
///      `keyCode` 76 and U+0003 (ETX) as both `characters` and
///      `charactersIgnoringModifiers`, whatever modifiers are held. That
///      U+0003 is an AppKit artifact: the key is Enter, never Ctrl+C.
///      `KeyEncoderKeypadModifierTests` pins that a DECPAM-off keypad Enter
///      encodes exactly like Return carrying the same modifiers, so:
///
///          Shift+kpEnter            legacy -> CR (0D)      kitty -> ESC[13;2u
///          Ctrl+Shift+kpEnter       legacy -> CR (0D)      kitty -> ESC[13;6u
///          Ctrl+Option+kpEnter      Meta   -> ESC CR       kitty -> ESC[13;7u
///
///      Writing 0x03 instead is a disaster: it is SIGINT to a cooked-mode
///      foreground job and a literal Ctrl+C in a raw-mode TUI (a Claude Code
///      user pressing Shift+Enter on the keypad for a newline cancels the
///      turn). Under kitty flag 8 the same bug surfaces as `CSI 3;2u`.
///
///   2. Ctrl+Option + Return / Tab / Esc. With Option as Meta these are
///      Meta-Control chords. The modifiers must survive whichever AppKit
///      route (key-binding command or `insertText`) delivers the character:
///
///          legacy (Meta)        Ctrl+Opt+Return -> ESC CR   Ctrl+Opt+Tab -> ESC TAB
///                               Ctrl+Opt+Esc    -> ESC ESC
///          kitty flag 1 / 1+8   ESC[13;7u       ESC[9;7u    ESC[27;7u
///          modifyOtherKeys 2    ESC[27;7;13~    ESC[27;7;9~ ESC[27;7;27~
///
///      The bug sends the bare CR / TAB / ESC (kitty flag 1: `ESC[27u`
///      instead of `ESC[27;7u`; Meta mode: no ESC prefix).
///
/// Oracle. Every expectation is a hard-coded wire sequence. The
/// `test_precondition_encoderOracle` test additionally proves that the
/// independently tested `KeyEncoder.encode(chars:modifiers:mode:)` produces
/// exactly those bytes for the corresponding plain character, so the numbers
/// above can never drift from the encoder contract without a loud failure
/// in the fixture instead of the behaviour.
///
/// Fixture realism. Every key is a real `keyDown` NSEvent handed to
/// `TerminalView.keyDown` of a headless view whose snapshot comes from a
/// real `BBTerm` that was fed the actual `CSI > N u` / `CSI > 4 ; 2 m`
/// bytes; each rig asserts the resulting `termMode` bits so a mistyped
/// escape fails the fixture, not the behaviour. PTY writes are captured by
/// `RecordingPTY`. The anchors (plain keypad Enter, Shift+Return,
/// Option+Return) press neighbouring keys through the
/// same rig and must give the right bytes today, so a failure in a bug test
/// can only be the modified-Enter / Tab / Esc gap and never a dead rig.
///
/// Memory/time pre-flight: one 100x100 pt headless `TerminalView` (Metal
/// renderer, no draw) + one 40x6 `BBTerm` (scrollback 16) per rig; at most
/// ~10 rigs per test; no window, no PTY, no child process, no timers. A few
/// hundred KiB per rig.
///
/// Written blind: no body of `TerminalView.keyDown`, `TerminalView+IME` or
/// `KeyEventClassifier` was read; only declarations, doc comments, sibling
/// tests and the convention above.
final class IMEModifiedEnterBlindTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        TestHostTermination.shared.register()
    }

    // MARK: - Fixtures

    private struct PhysicalKey {
        let name: String
        let keyCode: UInt16
        let chars: String
        let flags: NSEvent.ModifierFlags
        /// `charactersIgnoringModifiers` when it differs from `chars` (a
        /// Ctrl+Option+letter reports the C0 byte as `chars` and the letter
        /// here); `nil` means "same as `chars`".
        var ignoring: String? = nil
    }

    private static let kVKReturn: UInt16 = 36
    private static let kVKTab: UInt16 = 48
    private static let kVKEscape: UInt16 = 53
    private static let kVKKeypadEnter: UInt16 = 76

    /// Return / Tab / Esc with `flags`, reporting the plain control character
    /// as AppKit does for these keys.
    private func returnKey(_ flags: NSEvent.ModifierFlags, _ label: String) -> PhysicalKey {
        PhysicalKey(name: label, keyCode: Self.kVKReturn, chars: "\r", flags: flags)
    }

    private func tabKey(_ flags: NSEvent.ModifierFlags, _ label: String) -> PhysicalKey {
        PhysicalKey(name: label, keyCode: Self.kVKTab, chars: "\t", flags: flags)
    }

    private func escKey(_ flags: NSEvent.ModifierFlags, _ label: String) -> PhysicalKey {
        PhysicalKey(name: label, keyCode: Self.kVKEscape, chars: "\u{1B}", flags: flags)
    }

    /// Keypad Enter: key code 76, U+0003 as the reported character, and the
    /// numeric-pad flag, with `flags` held on top.
    private func keypadEnterKey(_ flags: NSEvent.ModifierFlags, _ label: String) -> PhysicalKey {
        PhysicalKey(name: label,
                    keyCode: Self.kVKKeypadEnter,
                    chars: "\u{03}",
                    flags: flags.union(.numericPad))
    }

    /// Escape sequences that put a real `BBTerm` into each mode.
    private let noMode = ""
    private let kittyFlag1 = "\u{1B}[>1u"
    private let kittyFlag8 = "\u{1B}[>8u"
    private let kittyFlag1and8 = "\u{1B}[>9u"
    private let modifyOtherKeys2 = "\u{1B}[>4;2m"

    private func bytes(_ s: String) -> Data { Data(s.utf8) }

    private func hex(_ d: Data) -> String {
        d.isEmpty ? "<empty>" : d.map { String(format: "%02X", $0) }.joined(separator: " ")
    }

    private static let etx = UInt8(0x03)

    private let cr = Data([0x0D])
    private let escCR = Data([0x1B, 0x0D])
    private let escTab = Data([0x1B, 0x09])
    private let escEsc = Data([0x1B, 0x1B])

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
                charactersIgnoringModifiers: key.ignoring ?? key.chars,
                isARepeat: false,
                keyCode: key.keyCode
            ),
            "NSEvent.keyEvent returned nil for \(key.name) (keyCode \(key.keyCode))"
        )
    }

    private struct Rig {
        let view: TerminalView
        let term: BBTerm
        let session: TerminalSession
        let recorder: RecordingPTY
        let mode: BBTermMode
    }

    /// One headless view + a 40x6 BBTerm. `setup` is fed to the real parser
    /// and the resulting snapshot (and so `termMode`) is installed on the
    /// view. Option is Meta unless `optionIsMeta` says otherwise.
    private func makeRig(
        feeding setup: String,
        optionIsMeta: Bool = true,
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
        view.setOptionIsMetaForTests(optionIsMeta)
        XCTAssertEqual(view.encoder.optionIsMeta, optionIsMeta,
                       "precondition: rig must have optionIsMeta=\(optionIsMeta)",
                       file: file, line: line)
        return Rig(view: view, term: term, session: session, recorder: recorder, mode: snapshot.termMode)
    }

    /// Rig for a given mode setup string, with the mode bits asserted.
    private func makeModeRig(
        feeding setup: String,
        expecting expected: BBTermMode,
        optionIsMeta: Bool = true,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> Rig {
        let rig = try makeRig(feeding: setup, optionIsMeta: optionIsMeta, file: file, line: line)
        let kittyAndMok: BBTermMode = [.disambiguateEscCodes, .reportEventTypes, .reportAlternateKeys,
                                       .reportAllKeysAsEsc, .reportAssociatedText, .modifyOtherKeys]
        XCTAssertEqual(rig.mode.intersection(kittyAndMok), expected,
                       "precondition: feeding \(setup.debugDescription) must yield exactly the expected "
                       + "keyboard-protocol bits; termMode.rawValue=\(rig.mode.rawValue)",
                       file: file, line: line)
        return rig
    }

    /// Presses `key` once on a clean recorder and returns what reached the PTY.
    private func press(_ key: PhysicalKey, on rig: Rig) throws -> Data {
        rig.recorder.sent = Data()
        rig.view.keyDown(with: try keyDownEvent(key))
        return rig.recorder.sent
    }

    /// Presses `key` and asserts exactly `expected` reached the PTY.
    private func assertPress(
        _ key: PhysicalKey,
        on rig: Rig,
        sends expected: Data,
        context: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let got = try press(key, on: rig)
        XCTAssertEqual(got, expected,
                       "\(context): \(key.name) (keyCode \(key.keyCode), chars "
                       + "\(key.chars.unicodeScalars.map { String(format: "U+%04X", $0.value) }), "
                       + "flags \(key.flags.rawValue)) must send \(hex(expected)); sent \(hex(got))",
                       file: file, line: line)
    }

    /// Asserts the bytes are not (and do not contain) a bare Ctrl+C.
    private func assertNoETX(
        _ key: PhysicalKey,
        on rig: Rig,
        context: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let got = try press(key, on: rig)
        XCTAssertFalse(got.contains(Self.etx),
                       "\(context): \(key.name) must never put ETX (03, Ctrl+C) on the PTY; sent \(hex(got))",
                       file: file, line: line)
    }

    // MARK: - Oracle self-check

    /// The hard-coded wire bytes used below are exactly what the independently
    /// tested encoder produces for Return / Tab / Esc carrying the same
    /// modifiers, so the expectations cannot be a wrong-but-plausible guess.
    func test_precondition_encoderOracle() {
        let meta = KeyEncoder(optionIsMeta: true)
        let flag1: BBTermMode = [.disambiguateEscCodes]
        let flag8: BBTermMode = [.reportAllKeysAsEsc]
        let flag1and8: BBTermMode = [.disambiguateEscCodes, .reportAllKeysAsEsc]
        let mok: BBTermMode = [.modifyOtherKeys]

        XCTAssertEqual(meta.encode(chars: "\r", modifiers: [.shift], mode: []), cr,
                       "legacy Shift+Return is CR")
        XCTAssertEqual(meta.encode(chars: "\r", modifiers: [.shift], mode: flag8), bytes("\u{1B}[13;2u"),
                       "flag 8 Shift+Return is ESC[13;2u")
        XCTAssertEqual(meta.encode(chars: "\r", modifiers: [.shift], mode: flag1), bytes("\u{1B}[13;2u"),
                       "flag 1 Shift+Return is ESC[13;2u")
        XCTAssertEqual(meta.encode(chars: "\r", modifiers: [.control, .shift], mode: flag1), bytes("\u{1B}[13;6u"),
                       "flag 1 Ctrl+Shift+Return is ESC[13;6u")
        XCTAssertEqual(meta.encode(chars: "\r", modifiers: [.control, .shift], mode: []), cr,
                       "legacy Ctrl+Shift+Return is CR")
        XCTAssertEqual(meta.encode(chars: "\r", modifiers: [.control, .option], mode: []), escCR,
                       "Meta legacy Ctrl+Option+Return is ESC CR")
        XCTAssertEqual(meta.encode(chars: "\t", modifiers: [.control, .option], mode: []), escTab,
                       "Meta legacy Ctrl+Option+Tab is ESC TAB")
        XCTAssertEqual(meta.encode(chars: "\u{1B}", modifiers: [.control, .option], mode: []), escEsc,
                       "Meta legacy Ctrl+Option+Esc is ESC ESC")
        for mode in [flag1, flag1and8] {
            XCTAssertEqual(meta.encode(chars: "\r", modifiers: [.control, .option], mode: mode),
                           bytes("\u{1B}[13;7u"), "kitty Ctrl+Option+Return is ESC[13;7u")
            XCTAssertEqual(meta.encode(chars: "\t", modifiers: [.control, .option], mode: mode),
                           bytes("\u{1B}[9;7u"), "kitty Ctrl+Option+Tab is ESC[9;7u")
            XCTAssertEqual(meta.encode(chars: "\u{1B}", modifiers: [.control, .option], mode: mode),
                           bytes("\u{1B}[27;7u"), "kitty Ctrl+Option+Esc is ESC[27;7u")
        }
        XCTAssertEqual(meta.encode(chars: "\r", modifiers: [.control, .option], mode: mok),
                       bytes("\u{1B}[27;7;13~"), "modifyOtherKeys Ctrl+Option+Return is ESC[27;7;13~")
        XCTAssertEqual(meta.encode(chars: "\t", modifiers: [.control, .option], mode: mok),
                       bytes("\u{1B}[27;7;9~"), "modifyOtherKeys Ctrl+Option+Tab is ESC[27;7;9~")
        XCTAssertEqual(meta.encode(chars: "\u{1B}", modifiers: [.control, .option], mode: mok),
                       bytes("\u{1B}[27;7;27~"), "modifyOtherKeys Ctrl+Option+Esc is ESC[27;7;27~")
    }

    // MARK: - Anchors (right today; prove the rig is alive and not rewriting)

    /// Plain keypad Enter, Return and Shift+Return already produce CR, so the
    /// Shift+kpEnter results below cannot be blamed on a dead rig.
    func test_anchor_legacy_plainEnterKeys_sendCR() throws {
        let rig = try makeModeRig(feeding: noMode, expecting: [])
        try assertPress(keypadEnterKey([], "plain keypad Enter"), on: rig, sends: cr, context: "legacy anchor")
        try assertPress(returnKey([], "plain Return"), on: rig, sends: cr, context: "legacy anchor")
        try assertPress(returnKey([.shift], "Shift+Return"), on: rig, sends: cr, context: "legacy anchor")
    }

    func test_anchor_kittyFlag8_shiftReturn_csiU13_2() throws {
        let rig = try makeModeRig(feeding: kittyFlag8, expecting: [.reportAllKeysAsEsc])
        try assertPress(returnKey([.shift], "Shift+Return"), on: rig,
                        sends: bytes("\u{1B}[13;2u"), context: "flag 8 anchor")
    }

    /// Option as Meta: Option+Return already keeps its ESC prefix, so the
    /// Ctrl+Option+Return/Tab/Esc results below are about the Ctrl+Option
    /// chords, not about Meta mode being dead.
    func test_anchor_metaLegacy_optionReturn_isEscCR() throws {
        let rig = try makeModeRig(feeding: noMode, expecting: [])
        try assertPress(returnKey([.option], "Option+Return"), on: rig, sends: escCR,
                        context: "Meta legacy anchor")
    }

    // MARK: - Bug 1: Shift (and friends) + keypad Enter reaches the PTY as ETX

    func test_shiftKeypadEnter_legacy_isCR_notETX() throws {
        let rig = try makeModeRig(feeding: noMode, expecting: [])
        let key = keypadEnterKey([.shift], "Shift+keypad Enter")
        try assertNoETX(key, on: rig, context: "legacy")
        try assertPress(key, on: rig, sends: cr, context: "legacy")
    }

    func test_shiftKeypadEnter_kittyFlag8_csiU13_2_notCsi3() throws {
        let rig = try makeModeRig(feeding: kittyFlag8, expecting: [.reportAllKeysAsEsc])
        try assertPress(keypadEnterKey([.shift], "Shift+keypad Enter"), on: rig,
                        sends: bytes("\u{1B}[13;2u"), context: "kitty flag 8")
    }

    func test_shiftKeypadEnter_kittyFlag1_csiU13_2() throws {
        let rig = try makeModeRig(feeding: kittyFlag1, expecting: [.disambiguateEscCodes])
        try assertPress(keypadEnterKey([.shift], "Shift+keypad Enter"), on: rig,
                        sends: bytes("\u{1B}[13;2u"), context: "kitty flag 1")
    }

    func test_ctrlShiftKeypadEnter_legacy_isCR_notETX() throws {
        let rig = try makeModeRig(feeding: noMode, expecting: [])
        let key = keypadEnterKey([.control, .shift], "Ctrl+Shift+keypad Enter")
        try assertNoETX(key, on: rig, context: "legacy")
        try assertPress(key, on: rig, sends: cr, context: "legacy")
    }

    func test_ctrlShiftKeypadEnter_kittyFlag1_csiU13_6() throws {
        let rig = try makeModeRig(feeding: kittyFlag1, expecting: [.disambiguateEscCodes])
        try assertPress(keypadEnterKey([.control, .shift], "Ctrl+Shift+keypad Enter"), on: rig,
                        sends: bytes("\u{1B}[13;6u"), context: "kitty flag 1")
    }

    func test_ctrlOptionKeypadEnter_metaLegacy_isEscCR_notETX() throws {
        let rig = try makeModeRig(feeding: noMode, expecting: [])
        let key = keypadEnterKey([.control, .option], "Ctrl+Option+keypad Enter")
        try assertNoETX(key, on: rig, context: "Meta legacy")
        try assertPress(key, on: rig, sends: escCR, context: "Meta legacy")
    }

    func test_ctrlOptionKeypadEnter_kittyFlag1_csiU13_7() throws {
        let rig = try makeModeRig(feeding: kittyFlag1, expecting: [.disambiguateEscCodes])
        try assertPress(keypadEnterKey([.control, .option], "Ctrl+Option+keypad Enter"), on: rig,
                        sends: bytes("\u{1B}[13;7u"), context: "kitty flag 1")
    }

    // MARK: - Bug 2: Ctrl+Option + Return / Tab / Esc lose Ctrl and Meta

    /// Option=Meta, no keyboard protocol: ESC prefix + the bare control byte.
    func test_ctrlOptionReturnTabEsc_metaLegacy_keepEscPrefix() throws {
        let rig = try makeModeRig(feeding: noMode, expecting: [])
        try assertPress(returnKey([.control, .option], "Ctrl+Option+Return"), on: rig,
                        sends: escCR, context: "Meta legacy")
        try assertPress(tabKey([.control, .option], "Ctrl+Option+Tab"), on: rig,
                        sends: escTab, context: "Meta legacy")
        try assertPress(escKey([.control, .option], "Ctrl+Option+Esc"), on: rig,
                        sends: escEsc, context: "Meta legacy")
    }

    /// Kitty flag 1: CSI u with the Ctrl+Alt modifier parameter 7.
    func test_ctrlOptionReturnTabEsc_kittyFlag1_csiUMod7() throws {
        let rig = try makeModeRig(feeding: kittyFlag1, expecting: [.disambiguateEscCodes])
        try assertPress(returnKey([.control, .option], "Ctrl+Option+Return"), on: rig,
                        sends: bytes("\u{1B}[13;7u"), context: "kitty flag 1")
        try assertPress(tabKey([.control, .option], "Ctrl+Option+Tab"), on: rig,
                        sends: bytes("\u{1B}[9;7u"), context: "kitty flag 1")
        try assertPress(escKey([.control, .option], "Ctrl+Option+Esc"), on: rig,
                        sends: bytes("\u{1B}[27;7u"), context: "kitty flag 1")
    }

    /// Kitty flags 1+8 (report all keys): same CSI u with parameter 7.
    func test_ctrlOptionReturnTabEsc_kittyFlag1and8_csiUMod7() throws {
        let rig = try makeModeRig(feeding: kittyFlag1and8,
                                  expecting: [.disambiguateEscCodes, .reportAllKeysAsEsc])
        try assertPress(returnKey([.control, .option], "Ctrl+Option+Return"), on: rig,
                        sends: bytes("\u{1B}[13;7u"), context: "kitty flags 1+8")
        try assertPress(tabKey([.control, .option], "Ctrl+Option+Tab"), on: rig,
                        sends: bytes("\u{1B}[9;7u"), context: "kitty flags 1+8")
        try assertPress(escKey([.control, .option], "Ctrl+Option+Esc"), on: rig,
                        sends: bytes("\u{1B}[27;7u"), context: "kitty flags 1+8")
    }

    /// xterm modifyOtherKeys level 2: CSI 27 ; 7 ; <code> ~.
    func test_ctrlOptionReturnTabEsc_modifyOtherKeys2_csi27Mod7() throws {
        let rig = try makeModeRig(feeding: modifyOtherKeys2, expecting: [.modifyOtherKeys])
        try assertPress(returnKey([.control, .option], "Ctrl+Option+Return"), on: rig,
                        sends: bytes("\u{1B}[27;7;13~"), context: "modifyOtherKeys 2")
        try assertPress(tabKey([.control, .option], "Ctrl+Option+Tab"), on: rig,
                        sends: bytes("\u{1B}[27;7;9~"), context: "modifyOtherKeys 2")
        try assertPress(escKey([.control, .option], "Ctrl+Option+Esc"), on: rig,
                        sends: bytes("\u{1B}[27;7;27~"), context: "modifyOtherKeys 2")
    }

    // MARK: - Review follow-up (added after review, NOT blind)
    //
    // The first revision of the fix bypassed the IME for a keyCode whitelist
    // (Return / Tab / Esc / Space). A real NSTextInputContext (measured with a
    // standalone NSTextInputClient probe) also commits the bare C0 byte for 24
    // of the 26 Ctrl+Option+letter chords (only f and b reach `doCommand`), so
    // M-C-k reached the program as C-k and Ctrl+Option+c as a bare 0x03. These
    // tests pin the general rule: every Ctrl+Option chord skips the IME.
    // Memory/time: same rigs as above, 26 key events per test at most.

    private var letters: [Character] { Array("abcdefghijklmnopqrstuvwxyz") }

    /// Ctrl+Option+<letter> as the real window server delivers it:
    /// `characters` is the C0 byte, `charactersIgnoringModifiers` the letter.
    private func ctrlOptionLetterKey(_ letter: Character, keyCode: UInt16) -> PhysicalKey {
        let scalar = letter.unicodeScalars.first!.value
        let c0 = String(UnicodeScalar(scalar & 0x1F)!)
        return PhysicalKey(name: "Ctrl+Option+\(letter)", keyCode: keyCode, chars: c0,
                           flags: [.control, .option], ignoring: String(letter))
    }

    /// Meta legacy: every Ctrl+Option+letter is ESC + its C0 byte (the
    /// readline / Emacs M-C-* chord), never the bare C0 byte. Includes f and b
    /// (the two that reach `doCommand`) and c (a bare 0x03 would be SIGINT).
    func test_ctrlOptionLetters_metaLegacy_keepEscPrefix() throws {
        let rig = try makeModeRig(feeding: noMode, expecting: [])
        for (index, letter) in letters.enumerated() {
            let key = ctrlOptionLetterKey(letter, keyCode: UInt16(index))
            let c0 = UInt8(letter.unicodeScalars.first!.value & 0x1F)
            try assertPress(key, on: rig, sends: Data([0x1B, c0]), context: "Meta legacy")
        }
    }

    /// Kitty flag 1: Ctrl+Option+letter is `CSI <cp>;7u`.
    func test_ctrlOptionLetters_kittyFlag1_csiUMod7() throws {
        let rig = try makeModeRig(feeding: kittyFlag1, expecting: [.disambiguateEscCodes])
        for (index, letter) in letters.enumerated() {
            let key = ctrlOptionLetterKey(letter, keyCode: UInt16(index))
            let cp = letter.unicodeScalars.first!.value
            try assertPress(key, on: rig, sends: bytes("\u{1B}[\(cp);7u"), context: "kitty flag 1")
        }
    }

    /// Ctrl+Option+Space keeps both modifiers in Meta legacy and kitty modes
    /// (real `characters` for the chord was not measured; both plausible
    /// reports, " " and NUL, are covered).
    func test_ctrlOptionSpace_keepsModifiers() throws {
        let meta = KeyEncoder(optionIsMeta: true)
        let legacyRig = try makeModeRig(feeding: noMode, expecting: [])
        let kittyRig = try makeModeRig(feeding: kittyFlag1, expecting: [.disambiguateEscCodes])
        for chars in [" ", "\u{00}"] {
            let key = PhysicalKey(name: "Ctrl+Option+Space", keyCode: 49, chars: chars,
                                  flags: [.control, .option], ignoring: " ")
            try assertPress(key, on: legacyRig,
                            sends: meta.encode(chars: " ", modifiers: [.control, .option], mode: []),
                            context: "Meta legacy (chars \(chars.debugDescription))")
            try assertPress(key, on: kittyRig, sends: bytes("\u{1B}[32;7u"),
                            context: "kitty flag 1 (chars \(chars.debugDescription))")
        }
    }

    /// Native-Option mode (Option is not Meta): Shift+Option+keypad Enter still
    /// never reaches the PTY as ETX.
    func test_shiftOptionKeypadEnter_nativeOption_isCR_notETX() throws {
        let rig = try makeModeRig(feeding: noMode, expecting: [], optionIsMeta: false)
        let key = keypadEnterKey([.shift, .option], "Shift+Option+keypad Enter")
        try assertNoETX(key, on: rig, context: "native Option legacy")
        try assertPress(key, on: rig, sends: cr, context: "native Option legacy")
    }

    // MARK: - Predicate: isNonComposableControlChord

    private func bypasses(_ keyCode: UInt16, _ flags: NSEvent.ModifierFlags) -> Bool {
        KeyEventClassifier.isNonComposableControlChord(keyCode: keyCode, modifierFlags: flags)
    }

    func test_predicate_ctrlOption_anyKey_bypasses() {
        // Return, keypad Enter, Tab, Space, Esc, a letter (k = 40), a digit (1 = 18).
        for keyCode: UInt16 in [36, 76, 48, 49, 53, 40, 18] {
            XCTAssertTrue(bypasses(keyCode, [.control, .option]), "keyCode \(keyCode)")
            XCTAssertTrue(bypasses(keyCode, [.control, .option, .shift]), "keyCode \(keyCode) +Shift")
            XCTAssertTrue(bypasses(keyCode, [.control, .option, .numericPad]), "keyCode \(keyCode) +pad")
        }
    }

    func test_predicate_shiftEnter_bypasses() {
        for keyCode: UInt16 in [36, 76] {
            XCTAssertTrue(bypasses(keyCode, [.shift]), "keyCode \(keyCode) Shift")
            XCTAssertTrue(bypasses(keyCode, [.shift, .numericPad]), "keyCode \(keyCode) Shift+pad")
            XCTAssertTrue(bypasses(keyCode, [.control, .shift]), "keyCode \(keyCode) Ctrl+Shift")
            XCTAssertTrue(bypasses(keyCode, [.shift, .option]), "keyCode \(keyCode) Shift+Option")
        }
    }

    func test_predicate_negatives_keepIMEPath() {
        for keyCode: UInt16 in [36, 76] {
            XCTAssertFalse(bypasses(keyCode, []), "plain Enter \(keyCode)")
            XCTAssertFalse(bypasses(keyCode, [.numericPad]), "plain keypad Enter \(keyCode)")
            XCTAssertFalse(bypasses(keyCode, [.control]), "Ctrl+Enter \(keyCode)")
            XCTAssertFalse(bypasses(keyCode, [.option]), "Option+Enter \(keyCode)")
        }
        // Single modifiers and Shift on non-Enter keys compose / commit normally.
        for keyCode: UInt16 in [48, 49, 53, 40, 0] {
            XCTAssertFalse(bypasses(keyCode, []), "keyCode \(keyCode) bare")
            XCTAssertFalse(bypasses(keyCode, [.shift]), "keyCode \(keyCode) Shift")
            XCTAssertFalse(bypasses(keyCode, [.control]), "keyCode \(keyCode) Ctrl")
            XCTAssertFalse(bypasses(keyCode, [.option]), "keyCode \(keyCode) Option (dead keys)")
            XCTAssertFalse(bypasses(keyCode, [.control, .shift]), "keyCode \(keyCode) Ctrl+Shift")
            XCTAssertFalse(bypasses(keyCode, [.option, .shift]), "keyCode \(keyCode) Option+Shift")
        }
    }

    func test_predicate_command_neverBypasses() {
        for keyCode: UInt16 in [36, 76, 48, 40] {
            XCTAssertFalse(bypasses(keyCode, [.command, .control, .option]), "keyCode \(keyCode)")
            XCTAssertFalse(bypasses(keyCode, [.command, .shift]), "keyCode \(keyCode)")
        }
    }
}
