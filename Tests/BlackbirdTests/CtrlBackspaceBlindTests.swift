import XCTest
import AppKit
@testable import Blackbird
@testable import BBCore

/// KEY-CTRL-BS — Ctrl+Backspace must reach the shell as BS (0x08), not DEL
/// (0x7F).
///
/// Terminal convention (xterm, and the kitty "legacy" key table that
/// `TERM=xterm-kitty` advertises, which is what Blackbird sets):
///
///     Backspace             -> 0x7F
///     Shift+Backspace       -> 0x7F
///     Alt/Option+Backspace  -> ESC 0x7F
///     Ctrl+Backspace        -> 0x08          (the same byte as Ctrl+H)
///     Ctrl+Shift+Backspace  -> 0x08
///     Ctrl+Alt+Backspace    -> ESC 0x08
///
/// Why it matters: the very common shell setup `bindkey '^H'
/// backward-kill-word` (and the readline / vim / emacs bindings on C-h) is how
/// users get "Ctrl+Backspace deletes a word" in every other terminal. If
/// Ctrl+Backspace is sent as the unmodified DEL byte the shell cannot tell it
/// apart from plain Backspace, the binding never fires, and the chord just
/// deletes one character.
///
/// Scope: the legacy path only (no kitty keyboard flag, no modifyOtherKeys).
/// Under those protocols a modified Backspace is reported as a CSI sequence
/// (`CSI 127 ; 5 u` etc.), which is a separate, already-correct contract; one
/// anchor below pins that it stays that way.
///
/// Rig honesty. Every claim that Ctrl+Backspace changes is anchored to the
/// unmodified / Shift / Option Backspace results, which must stay exactly as
/// they are today, so a failure here can only be the Ctrl gap and never a
/// broken harness. The view-level tests drive the real `TerminalView.keyDown`
/// with a synthesized key event into a headless view whose PTY writes are
/// captured by `RecordingPTY`; the plain-Backspace precondition proves that
/// rig records the DEL byte for an ordinary Backspace.
///
/// Written blind: no body of `KeyEncoder.encode` or `TerminalView.keyDown` was
/// read; only declarations, doc comments, sibling tests, and the convention
/// above.
final class CtrlBackspaceBlindTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        TestHostTermination.shared.register()
    }

    // MARK: - Fixtures

    /// What AppKit reports for the Backspace key: DEL as both `characters`
    /// and `charactersIgnoringModifiers`, key code 51 (`kVK_Delete`).
    private let backspaceChars = "\u{7F}"
    private let backspaceKeyCode: UInt16 = 51

    private let del = Data([0x7F])
    private let bs = Data([0x08])
    private let escDel = Data([0x1B, 0x7F])
    private let escBS = Data([0x1B, 0x08])

    private func hex(_ d: Data) -> String {
        d.isEmpty ? "<empty>" : d.map { String(format: "%02X", $0) }.joined(separator: " ")
    }

    /// `ESC [ <codepoint> ; <mod> u`, collapsing `mod == 1` to `ESC [ <cp> u`.
    private func csiU(_ codepoint: Int, mod: Int = 1) -> Data {
        var s = "\u{1B}[\(codepoint)"
        if mod > 1 { s += ";\(mod)" }
        s += "u"
        return Data(s.utf8)
    }

    private func encodeBackspace(
        _ encoder: KeyEncoder,
        _ modifiers: KeyEncoder.Modifiers,
        mode: BBTermMode = []
    ) -> Data {
        encoder.encode(chars: backspaceChars, modifiers: modifiers, mode: mode)
    }

    // MARK: - Encoder: anchors that must NOT change

    /// Unmodified, Shift and Option (Meta) Backspace stay DEL-based. If a fix
    /// over-reaches and turns every Backspace into BS, these fail.
    func test_anchor_encoder_nonCtrlBackspace_staysDel() {
        let meta = KeyEncoder(optionIsMeta: true)
        let native = KeyEncoder(optionIsMeta: false)

        XCTAssertEqual(encodeBackspace(meta, []), del,
                       "plain Backspace must stay DEL (0x7F); got \(hex(encodeBackspace(meta, [])))")
        XCTAssertEqual(encodeBackspace(native, []), del,
                       "plain Backspace (native Option) must stay DEL (0x7F); got \(hex(encodeBackspace(native, [])))")
        XCTAssertEqual(encodeBackspace(meta, [.shift]), del,
                       "Shift+Backspace must stay DEL (0x7F); got \(hex(encodeBackspace(meta, [.shift])))")
        XCTAssertEqual(encodeBackspace(meta, [.option]), escDel,
                       "Option+Backspace (Meta) must stay ESC DEL (1B 7F); got \(hex(encodeBackspace(meta, [.option])))")
        XCTAssertEqual(encodeBackspace(meta, [.option, .shift]), escDel,
                       "Option+Shift+Backspace (Meta) must stay ESC DEL (1B 7F); got \(hex(encodeBackspace(meta, [.option, .shift])))")
    }

    /// The byte Ctrl+Backspace is supposed to equal: Ctrl+H is BS today.
    func test_anchor_encoder_ctrlH_isBS() {
        let enc = KeyEncoder()
        let got = enc.encode(chars: "h", modifiers: [.control], mode: [])
        XCTAssertEqual(got, bs, "Ctrl+H must be BS (08); got \(hex(got))")
    }

    /// Under kitty flag 1 a Ctrl+Backspace is a CSI u report, not a legacy
    /// byte; that contract is untouched by the legacy BS fix.
    func test_anchor_encoder_ctrlBackspace_kittyFlag1_isCsiU127Mod5() {
        let enc = KeyEncoder()
        let flag1: BBTermMode = [.disambiguateEscCodes]
        let got = encodeBackspace(enc, [.control], mode: flag1)
        XCTAssertEqual(got, csiU(127, mod: 5),
                       "Ctrl+Backspace under kitty flag 1 must stay ESC[127;5u; got \(hex(got))")
    }

    // MARK: - Encoder: the bug

    /// THE BUG: Ctrl+Backspace -> 08, regardless of the Option setting (Ctrl
    /// alone has no Option to interpret).
    func test_encoder_ctrlBackspace_legacy_isBS() {
        let meta = KeyEncoder(optionIsMeta: true)
        let native = KeyEncoder(optionIsMeta: false)

        let gotMeta = encodeBackspace(meta, [.control])
        XCTAssertEqual(gotMeta, bs,
                       "Ctrl+Backspace (legacy, Option=Meta) must be BS (08) like Ctrl+H; got \(hex(gotMeta))")
        let gotNative = encodeBackspace(native, [.control])
        XCTAssertEqual(gotNative, bs,
                       "Ctrl+Backspace (legacy, Option=Native) must be BS (08) like Ctrl+H; got \(hex(gotNative))")
    }

    /// Ctrl wins over Shift: Ctrl+Shift+Backspace -> 08 (Shift+Backspace alone
    /// is DEL, anchored above).
    func test_encoder_ctrlShiftBackspace_legacy_isBS() {
        let enc = KeyEncoder(optionIsMeta: true)
        let got = encodeBackspace(enc, [.control, .shift])
        XCTAssertEqual(got, bs,
                       "Ctrl+Shift+Backspace (legacy) must be BS (08); got \(hex(got))")
    }

    /// Ctrl+Option+Backspace in Meta mode: the Meta ESC prefix followed by BS.
    func test_encoder_ctrlOptionBackspace_metaMode_isEscBS() {
        let enc = KeyEncoder(optionIsMeta: true)
        let got = encodeBackspace(enc, [.control, .option])
        XCTAssertEqual(got, escBS,
                       "Ctrl+Option+Backspace (Meta) must be ESC BS (1B 08); got \(hex(got))")
    }

    /// Same with Shift added: Shift never changes the legacy Backspace byte.
    func test_encoder_ctrlOptionShiftBackspace_metaMode_isEscBS() {
        let enc = KeyEncoder(optionIsMeta: true)
        let got = encodeBackspace(enc, [.control, .option, .shift])
        XCTAssertEqual(got, escBS,
                       "Ctrl+Option+Shift+Backspace (Meta) must be ESC BS (1B 08); got \(hex(got))")
    }

    // MARK: - View level (real keyDown path)

    private struct Rig {
        let view: TerminalView
        let term: BBTerm
        let session: TerminalSession
        let recorder: RecordingPTY
    }

    /// One headless view (100x100 pt) + a 40x6 BBTerm + a headless session.
    /// A few KiB of memory, no PTY, no window, no child process.
    private func makeRig(
        optionIsMeta: Bool = true,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> Rig {
        let view = try XCTUnwrap(TerminalView.makeHeadlessForTests(),
                                 "Metal device required", file: file, line: line)
        let term = try XCTUnwrap(BBTerm(size: .init(cols: 40, rows: 6), scrollback: 16),
                                 "BBTerm init failed", file: file, line: line)
        let snapshot = try XCTUnwrap(term.snapshot(), "snapshot() returned nil",
                                     file: file, line: line)
        let session = TerminalSession.makeHeadlessForTests()
        view.session = session
        view.currentSnapshot = snapshot
        let recorder = RecordingPTY()
        view.ptyRecorderForTests = recorder
        view.setOptionIsMetaForTests(optionIsMeta)
        return Rig(view: view, term: term, session: session, recorder: recorder)
    }

    private func backspaceKeyDown(flags: NSEvent.ModifierFlags) throws -> NSEvent {
        try XCTUnwrap(
            NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: flags,
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                characters: backspaceChars,
                charactersIgnoringModifiers: backspaceChars,
                isARepeat: false,
                keyCode: backspaceKeyCode
            ),
            "NSEvent.keyEvent returned nil for Backspace with flags \(flags.rawValue)"
        )
    }

    /// Rig honesty: an ordinary Backspace and a Shift / Option Backspace go
    /// through the real keyDown and land in the recorder as DEL / ESC DEL, so
    /// the Ctrl results below cannot be explained by a dead or rewriting rig.
    func test_precondition_view_nonCtrlBackspace_recordsDel() throws {
        let plain = try makeRig()
        plain.view.keyDown(with: try backspaceKeyDown(flags: []))
        XCTAssertEqual(plain.recorder.sent, del,
                       "view: plain Backspace must record DEL (7F); recorded \(hex(plain.recorder.sent))")

        let option = try makeRig(optionIsMeta: true)
        option.view.keyDown(with: try backspaceKeyDown(flags: [.option]))
        XCTAssertEqual(option.recorder.sent, escDel,
                       "view: Option+Backspace (Meta) must record ESC DEL (1B 7F); recorded \(hex(option.recorder.sent))")
    }

    /// THE BUG through the real key path: Ctrl+Backspace and Ctrl+Shift+
    /// Backspace must put 08 on the PTY.
    func test_view_ctrlBackspace_sendsBS() throws {
        let ctrl = try makeRig()
        ctrl.view.keyDown(with: try backspaceKeyDown(flags: [.control]))
        XCTAssertEqual(ctrl.recorder.sent, bs,
                       "view: Ctrl+Backspace must record BS (08); recorded \(hex(ctrl.recorder.sent))")

        let ctrlShift = try makeRig()
        ctrlShift.view.keyDown(with: try backspaceKeyDown(flags: [.control, .shift]))
        XCTAssertEqual(ctrlShift.recorder.sent, bs,
                       "view: Ctrl+Shift+Backspace must record BS (08); recorded \(hex(ctrlShift.recorder.sent))")
    }

    /// Ctrl+Option+Backspace with Option=Meta puts ESC BS on the PTY.
    func test_view_ctrlOptionBackspace_metaMode_sendsEscBS() throws {
        let rig = try makeRig(optionIsMeta: true)
        rig.view.keyDown(with: try backspaceKeyDown(flags: [.control, .option]))
        XCTAssertEqual(rig.recorder.sent, escBS,
                       "view: Ctrl+Option+Backspace (Meta) must record ESC BS (1B 08); recorded \(hex(rig.recorder.sent))")
    }
}
