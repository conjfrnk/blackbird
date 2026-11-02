import XCTest
import AppKit
@testable import Blackbird
@testable import BBCore

/// KEY-BACKTAB — Shift+Tab (and Ctrl+Shift+Tab) must reach the program as
/// "back-tab", never as the raw byte 0x19 (^Y).
///
/// What AppKit delivers. On a US layout the Tab key (virtual key code 48,
/// `kVK_Tab`) with Shift held does not report `"\t"`: AppKit reports the
/// single scalar U+0019 (`NSBackTabCharacter`, "⇤") as both `characters` and
/// `charactersIgnoringModifiers`. That scalar is numerically the same as the
/// C0 byte for Ctrl+Y, so a view that treats the event text as a literal byte
/// string, or an encoder that maps it as a control code, would put ^Y on the
/// wire instead of the back-tab report.
///
/// Terminal convention being pinned (xterm, VT220 `kcbt`, the `xterm-kitty`
/// terminfo Blackbird advertises: `kcbt=\E[Z`, `cbt=\E[Z`):
///
///     Shift+Tab                legacy                  -> ESC [ Z
///     Shift+Tab                kitty flag 1            -> ESC [ 9 ; 2 u
///     Ctrl+Shift+Tab           kitty flag 1            -> ESC [ 9 ; 6 u
///     Option+Shift+Tab         kitty flag 1            -> ESC [ 9 ; 4 u
///     Shift+Tab                xterm modifyOtherKeys 2 -> ESC [ 27 ; 2 ; 9 ~
///     Ctrl+Shift+Tab           xterm modifyOtherKeys 2 -> ESC [ 27 ; 6 ; 9 ~
///
/// (Tab is codepoint 9 in every CSI-u / modifyOtherKeys report; 25 is ^Y.)
///
/// Why it matters. A TUI that binds back-tab (Claude Code's mode cycle,
/// fzf, vim, zsh reverse-menu-complete) gets ^Y instead; in readline that is
/// "yank", and in a cooked-mode foreground job macOS maps ^Y to VDSUSP
/// (delayed suspend), so the job is stopped the next time it reads stdin.
///
/// Rig honesty and anchors (these must hold before AND after any fix, so a
/// failure in the "bug" tests can only be the back-tab gap):
///   * the same chords delivered the way the encoder's own unit tests spell
///     them (`"\t"` + modifiers, key code 48) already produce the right bytes
///     through the real `keyDown` path in every protocol — proves the rig
///     records back-tab / CSI-u / modifyOtherKeys sequences;
///   * plain Tab stays 0x09;
///   * Ctrl+Option+Y (whose `characters` is the very same U+0019) must still
///     end in ^Y and must not turn into a back-tab report, so a fix cannot
///     rewrite every U+0019 into back-tab.
///
/// Scope notes from probing the headless rig (no window, so no
/// `NSTextInputContext` round trip): a bare Ctrl+letter, and Ctrl+Tab /
/// Ctrl+Shift+Tab in LEGACY mode, record no bytes at all before or after
/// the fix — they are routed through the text-input / menu machinery — so
/// those are deliberately not asserted here. The Ctrl+Shift+Tab bug is pinned
/// in the protocols where the rig does observe it (kitty flag 1,
/// modifyOtherKeys), where it also reports ^Y / codepoint 25 today.
///
/// Every test drives the real `TerminalView.keyDown` with a synthesized
/// `NSEvent` into a headless view (100x100 pt, 40x6 `BBTerm`, no PTY, no
/// window, no child process; a few KiB) whose PTY writes are captured by
/// `RecordingPTY`. Keyboard-protocol modes come from a real `BBTerm` that was
/// fed the push sequence, so a fixture cannot pass on a mode the parser does
/// not actually set.
///
/// Written blind: no body of `KeyEncoder.encode`, `KeyEventClassifier` or
/// `TerminalView.keyDown` was read; only declarations, doc comments, sibling
/// tests, and the convention above.
final class ShiftTabBackTabBlindTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        TestHostTermination.shared.register()
    }

    // MARK: - Fixtures

    /// macOS `kVK_Tab`.
    private let tabKeyCode: UInt16 = 48
    /// macOS `kVK_ANSI_Y`.
    private let yKeyCode: UInt16 = 16
    /// `NSBackTabCharacter`: what AppKit reports for Shift+Tab. Also the C0
    /// control byte for Ctrl+Y, which is the whole problem.
    private let backTabChar = "\u{19}"

    private let noProtocol = ""
    private let kittyFlag1 = "\u{1B}[>1u"
    private let modifyOtherKeys2 = "\u{1B}[>4;2m"

    private func bytes(_ s: String) -> Data { Data(s.utf8) }

    private func hex(_ d: Data) -> String {
        d.isEmpty ? "<empty>" : d.map { String(format: "%02X", $0) }.joined(separator: " ")
    }

    /// `ESC [ <cp> ; <mod> u`
    private func csiU(_ codepoint: Int, mod: Int) -> Data {
        bytes("\u{1B}[\(codepoint);\(mod)u")
    }

    /// `ESC [ 27 ; <mod> ; <cp> ~` (xterm modifyOtherKeys)
    private func csi27(mod: Int, cp: Int) -> Data {
        bytes("\u{1B}[27;\(mod);\(cp)~")
    }

    /// Back-tab as a program can recognise it: `CSI Z`, optionally carrying the
    /// xterm modifier parameter (`CSI 1 ; <mod> Z`), optionally preceded by the
    /// Meta ESC prefix. Anything else (a lone control byte, a different final)
    /// is not a back-tab report.
    private func isBackTabReport(_ d: Data) -> Bool {
        guard let s = String(data: d, encoding: .utf8) else { return false }
        return s.range(of: "^\u{1B}?\u{1B}\\[(1;[0-9]+)?Z$", options: .regularExpression) != nil
    }

    // MARK: - Events

    private func keyDown(
        chars: String,
        ignoring: String,
        keyCode: UInt16,
        flags: NSEvent.ModifierFlags
    ) throws -> NSEvent {
        try XCTUnwrap(
            NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: flags,
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                characters: chars,
                charactersIgnoringModifiers: ignoring,
                isARepeat: false,
                keyCode: keyCode
            ),
            "NSEvent.keyEvent returned nil for keyCode \(keyCode) flags \(flags.rawValue)"
        )
    }

    /// The Tab key as AppKit really reports it while Shift is held: U+0019.
    private func backTabEvent(flags: NSEvent.ModifierFlags) throws -> NSEvent {
        try keyDown(chars: backTabChar, ignoring: backTabChar, keyCode: tabKeyCode, flags: flags)
    }

    /// The same chord spelled the way the encoder's unit tests spell it
    /// (`"\t"` + Shift). Not what hardware sends; used as the working anchor.
    private func tabShapedEvent(flags: NSEvent.ModifierFlags) throws -> NSEvent {
        try keyDown(chars: "\t", ignoring: "\t", keyCode: tabKeyCode, flags: flags)
    }

    // MARK: - Rig

    private struct Rig {
        let view: TerminalView
        let term: BBTerm
        let session: TerminalSession
        let recorder: RecordingPTY
        let snapshot: BBSnapshot
    }

    /// One headless view + a 40x6 BBTerm that has been fed `setup` (a keyboard
    /// protocol push) + a headless session.
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
        return Rig(view: view, term: term, session: session, recorder: recorder, snapshot: snapshot)
    }

    /// Deliver one event through the real `keyDown` and return exactly the
    /// bytes it put on the PTY (the recorder is cleared first, so a rig can be
    /// reused for several chords).
    private func send(_ event: NSEvent, to rig: Rig) -> Data {
        rig.recorder.sent = Data()
        rig.view.keyDown(with: event)
        return rig.recorder.sent
    }

    // MARK: - Preconditions and anchors (must pass before and after the fix)

    /// The synthesized event is what the bug report says AppKit sends, and
    /// each protocol fixture really sets the mode bit its tests depend on.
    func test_precondition_eventShapeAndModeFixtures() throws {
        let ev = try backTabEvent(flags: [.shift])
        XCTAssertEqual(ev.keyCode, tabKeyCode, "synthesized Shift+Tab keyCode")
        XCTAssertEqual(ev.characters?.unicodeScalars.map { $0.value }, [0x19],
                       "synthesized Shift+Tab must carry exactly U+0019 as characters")
        XCTAssertEqual(ev.charactersIgnoringModifiers?.unicodeScalars.map { $0.value }, [0x19],
                       "synthesized Shift+Tab must carry exactly U+0019 as charactersIgnoringModifiers")
        XCTAssertTrue(ev.modifierFlags.contains(.shift), "synthesized Shift+Tab must carry .shift")

        let legacy = try makeRig(feeding: noProtocol)
        XCTAssertTrue(legacy.snapshot.termMode.isDisjoint(with: [.disambiguateEscCodes, .modifyOtherKeys]),
                      "no-protocol fixture must have neither kitty flag 1 nor modifyOtherKeys; "
                      + "mode raw \(legacy.snapshot.termMode.rawValue)")

        let kitty = try makeRig(feeding: kittyFlag1)
        XCTAssertTrue(kitty.snapshot.termMode.contains(.disambiguateEscCodes),
                      "CSI > 1 u must set kitty flag 1; mode raw \(kitty.snapshot.termMode.rawValue)")

        let mok = try makeRig(feeding: modifyOtherKeys2)
        XCTAssertTrue(mok.snapshot.termMode.contains(.modifyOtherKeys),
                      "CSI > 4 ; 2 m must set modifyOtherKeys; mode raw \(mok.snapshot.termMode.rawValue)")
        XCTAssertFalse(mok.snapshot.termMode.contains(.disambiguateEscCodes),
                       "modifyOtherKeys fixture must not also have kitty flag 1")
    }

    /// Rig honesty: plain Tab is HT, and Shift / Ctrl+Shift / Option+Shift Tab
    /// spelled `"\t"` + modifiers already come out correctly through the real
    /// keyDown in every protocol. If these fail the rig (not the bug) is broken.
    func test_anchor_tabShapedChords_recordExpectedBytes_inEveryProtocol() throws {
        let legacy = try makeRig(feeding: noProtocol)
        XCTAssertEqual(send(try tabShapedEvent(flags: []), to: legacy), Data([0x09]),
                       "anchor: plain Tab must stay HT (09)")
        let legacyShift = send(try tabShapedEvent(flags: [.shift]), to: legacy)
        XCTAssertEqual(legacyShift, bytes("\u{1B}[Z"),
                       "anchor: tab-shaped Shift+Tab (legacy) must be ESC [ Z; recorded \(hex(legacyShift))")

        let kitty = try makeRig(feeding: kittyFlag1)
        let kittyCases: [(String, NSEvent.ModifierFlags, Data)] = [
            ("Shift+Tab", [.shift], csiU(9, mod: 2)),
            ("Ctrl+Shift+Tab", [.control, .shift], csiU(9, mod: 6)),
            ("Option+Shift+Tab", [.option, .shift], csiU(9, mod: 4)),
        ]
        for (label, flags, want) in kittyCases {
            let got = send(try tabShapedEvent(flags: flags), to: kitty)
            XCTAssertEqual(got, want,
                           "anchor: tab-shaped \(label) (kitty flag 1) must be \(hex(want)); recorded \(hex(got))")
        }

        let mok = try makeRig(feeding: modifyOtherKeys2)
        let mokCases: [(String, NSEvent.ModifierFlags, Data)] = [
            ("Shift+Tab", [.shift], csi27(mod: 2, cp: 9)),
            ("Ctrl+Shift+Tab", [.control, .shift], csi27(mod: 6, cp: 9)),
        ]
        for (label, flags, want) in mokCases {
            let got = send(try tabShapedEvent(flags: flags), to: mok)
            XCTAssertEqual(got, want,
                           "anchor: tab-shaped \(label) (modifyOtherKeys) must be \(hex(want)); recorded \(hex(got))")
        }
    }

    /// Ctrl+Option+Y carries the same U+0019 in `characters` (with "y" and
    /// key code 16). It is a Ctrl+Y chord and must stay one: it still ends in
    /// the ^Y byte and is never a back-tab report. Guards against a fix that
    /// rewrites every U+0019, not just Shift+Tab (key code 48).
    func test_anchor_ctrlOptionY_staysCtrlY_notBackTab() throws {
        let rig = try makeRig(feeding: noProtocol, optionIsMeta: true)
        let ev = try keyDown(chars: backTabChar, ignoring: "y", keyCode: yKeyCode, flags: [.control, .option])
        let got = send(ev, to: rig)
        XCTAssertEqual(got.last, 0x19,
                       "Ctrl+Option+Y must still end in ^Y (19); recorded \(hex(got))")
        XCTAssertFalse(isBackTabReport(got),
                       "Ctrl+Option+Y must not become a back-tab report; recorded \(hex(got))")
    }

    // MARK: - The bug: Shift+Tab as AppKit really delivers it

    /// THE BUG (legacy): Shift+Tab -> ESC [ Z, with Option as Meta or Native.
    func test_view_shiftTab_legacy_sendsCsiZ() throws {
        for optionIsMeta in [true, false] {
            let rig = try makeRig(feeding: noProtocol, optionIsMeta: optionIsMeta)
            let got = send(try backTabEvent(flags: [.shift]), to: rig)
            XCTAssertEqual(got, bytes("\u{1B}[Z"),
                           "Shift+Tab (legacy, optionIsMeta=\(optionIsMeta)) must be ESC [ Z (1B 5B 5A), "
                           + "not ^Y (19); recorded \(hex(got))")
        }
    }

    /// Same chord under kitty flag 1: CSI 9;2u, like the tab-shaped anchor.
    func test_view_shiftTab_kittyFlag1_sendsCsiU9Mod2() throws {
        let rig = try makeRig(feeding: kittyFlag1)
        let got = send(try backTabEvent(flags: [.shift]), to: rig)
        XCTAssertEqual(got, csiU(9, mod: 2),
                       "Shift+Tab (kitty flag 1) must be ESC [ 9 ; 2 u (1B 5B 39 3B 32 75); recorded \(hex(got))")
    }

    /// Under modifyOtherKeys the chord is reported against the Tab codepoint
    /// (9), never 25 (^Y): ESC [ 27 ; 2 ; 9 ~.
    func test_view_shiftTab_modifyOtherKeys_reportsTabCodepoint9() throws {
        let rig = try makeRig(feeding: modifyOtherKeys2)
        let got = send(try backTabEvent(flags: [.shift]), to: rig)
        XCTAssertEqual(got, csi27(mod: 2, cp: 9),
                       "Shift+Tab (modifyOtherKeys) must be ESC [ 27 ; 2 ; 9 ~, not codepoint 25 (^Y); "
                       + "recorded \(hex(got))")
    }

    // MARK: - The bug: Ctrl+Shift+Tab

    /// Ctrl+Shift+Tab under kitty flag 1: CSI 9;6u (shift 1 + ctrl 4, +1).
    func test_view_ctrlShiftTab_kittyFlag1_sendsCsiU9Mod6() throws {
        let rig = try makeRig(feeding: kittyFlag1)
        let got = send(try backTabEvent(flags: [.control, .shift]), to: rig)
        XCTAssertEqual(got, csiU(9, mod: 6),
                       "Ctrl+Shift+Tab (kitty flag 1) must be ESC [ 9 ; 6 u (1B 5B 39 3B 36 75); "
                       + "recorded \(hex(got))")
    }

    /// Ctrl+Shift+Tab under modifyOtherKeys: Tab codepoint, never 25.
    func test_view_ctrlShiftTab_modifyOtherKeys_reportsTabCodepoint9() throws {
        let rig = try makeRig(feeding: modifyOtherKeys2)
        let got = send(try backTabEvent(flags: [.control, .shift]), to: rig)
        XCTAssertEqual(got, csi27(mod: 6, cp: 9),
                       "Ctrl+Shift+Tab (modifyOtherKeys) must be ESC [ 27 ; 6 ; 9 ~, not codepoint 25 (^Y); "
                       + "recorded \(hex(got))")
    }

    // MARK: - The bug: Option held

    /// Option+Shift+Tab, legacy, Option as Meta or Native: a back-tab report
    /// (optionally Meta-prefixed), never `ESC ^Y` (1B 19) or a bare ^Y.
    func test_view_optionShiftTab_legacy_isBackTabReport() throws {
        for optionIsMeta in [true, false] {
            let rig = try makeRig(feeding: noProtocol, optionIsMeta: optionIsMeta)
            let got = send(try backTabEvent(flags: [.option, .shift]), to: rig)
            XCTAssertTrue(isBackTabReport(got),
                          "Option+Shift+Tab (legacy, optionIsMeta=\(optionIsMeta)) must be a back-tab report "
                          + "(ESC [ Z, optionally Meta-prefixed), not ^Y (19 / 1B 19); recorded \(hex(got))")
        }
    }

    /// Option+Shift+Tab under kitty flag 1: CSI 9;4u (shift 1 + alt 2, +1).
    func test_view_optionShiftTab_kittyFlag1_sendsCsiU9Mod4() throws {
        let rig = try makeRig(feeding: kittyFlag1)
        let got = send(try backTabEvent(flags: [.option, .shift]), to: rig)
        XCTAssertEqual(got, csiU(9, mod: 4),
                       "Option+Shift+Tab (kitty flag 1) must be ESC [ 9 ; 4 u (1B 5B 39 3B 34 75); "
                       + "recorded \(hex(got))")
    }
}
