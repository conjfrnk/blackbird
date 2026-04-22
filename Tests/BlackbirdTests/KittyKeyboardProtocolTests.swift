import XCTest
@testable import Blackbird

/// Pins KeyEncoder behavior under the kitty keyboard protocol, progressive
/// enhancement flag 1 (`disambiguateEscCodes`). Without this path, Shift+Enter,
/// Ctrl+i, Ctrl+m, modified Esc, and modified Backspace are indistinguishable
/// from their unmodified forms — which breaks Claude Code, nvim 0.10+, and any
/// TUI that negotiates kitty keyboard support.
///
/// Reference: https://sw.kovidgoyal.net/kitty/keyboard-protocol/#progressive-enhancement
final class KittyKeyboardProtocolTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        TestHostTermination.shared.register()
    }

    // MARK: - Helpers

    /// `ESC [ <codepoint> ; <mod> u`. `mod == 1` collapses to `ESC [ <cp> u`.
    private func csiU(_ codepoint: Int, mod: Int = 1) -> Data {
        var s = "\u{1B}[\(codepoint)"
        if mod > 1 { s += ";\(mod)" }
        s += "u"
        return Data(s.utf8)
    }

    private let kittyOn: BBTermMode = [.disambiguateEscCodes]

    // MARK: - Enter

    func test_shiftEnter_emitsCsiU_whenDisambiguate() {
        // THE target bug: Shift+Enter in Claude Code must insert a newline
        // into the prompt, not submit. That requires the terminal to emit
        // `ESC[13;2u` instead of bare `\r`.
        let enc = KeyEncoder()
        XCTAssertEqual(enc.encode(chars: "\r", modifiers: [.shift], mode: kittyOn),
                       csiU(13, mod: 2))
    }

    func test_ctrlEnter_emitsCsiU_whenDisambiguate() {
        let enc = KeyEncoder()
        XCTAssertEqual(enc.encode(chars: "\r", modifiers: [.control], mode: kittyOn),
                       csiU(13, mod: 5))
    }

    func test_plainEnter_stillCR_evenWhenDisambiguate() {
        // Kitty spec: unmodified Enter stays as legacy CR so line-discipline
        // shells continue to work transparently.
        let enc = KeyEncoder()
        XCTAssertEqual(enc.encode(chars: "\r", modifiers: [], mode: kittyOn),
                       Data([0x0D]))
    }

    func test_plainEnter_legacyMode_stillCR() {
        let enc = KeyEncoder()
        XCTAssertEqual(enc.encode(chars: "\r", modifiers: [], mode: []),
                       Data([0x0D]))
    }

    func test_shiftEnter_legacyMode_stillCR() {
        // Protect the default: without the TUI asking for kitty mode, we must
        // not unilaterally start emitting CSI u — that would confuse legacy
        // TUIs that assume `\r` is the only thing an Enter can produce.
        let enc = KeyEncoder()
        XCTAssertEqual(enc.encode(chars: "\r", modifiers: [.shift], mode: []),
                       Data([0x0D]))
    }

    // MARK: - Ctrl + C0-aliasing letters

    func test_ctrlI_disambiguated_distinctFromTab() {
        // Without disambiguation, Ctrl+i and Tab both produce 0x09. The kitty
        // protocol exists specifically to fix this.
        let enc = KeyEncoder()
        XCTAssertEqual(enc.encode(chars: "i", modifiers: [.control], mode: kittyOn),
                       csiU(105, mod: 5))
    }

    func test_ctrlM_disambiguated_distinctFromEnter() {
        let enc = KeyEncoder()
        XCTAssertEqual(enc.encode(chars: "m", modifiers: [.control], mode: kittyOn),
                       csiU(109, mod: 5))
    }

    func test_ctrlOpenBracket_disambiguated_distinctFromEsc() {
        let enc = KeyEncoder()
        XCTAssertEqual(enc.encode(chars: "[", modifiers: [.control], mode: kittyOn),
                       csiU(91, mod: 5))
    }

    func test_ctrlH_disambiguated_distinctFromBackspace() {
        let enc = KeyEncoder()
        XCTAssertEqual(enc.encode(chars: "h", modifiers: [.control], mode: kittyOn),
                       csiU(104, mod: 5))
    }

    func test_ctrlC_disambiguateMode_stillSendsSigInt() {
        // Ctrl+c is NOT an ambiguous binding — 0x03 is unique to Ctrl+c. Every
        // shell in the world expects 0x03 for SIGINT. Emitting CSI u here
        // would silently break `^C`.
        let enc = KeyEncoder()
        XCTAssertEqual(enc.encode(chars: "c", modifiers: [.control], mode: kittyOn),
                       Data([0x03]))
    }

    func test_ctrlA_disambiguateMode_stillControlByte() {
        let enc = KeyEncoder()
        XCTAssertEqual(enc.encode(chars: "a", modifiers: [.control], mode: kittyOn),
                       Data([0x01]))
    }

    // MARK: - Tab

    func test_shiftTab_disambiguateMode_emitsCsiU() {
        // Matches kitty's own behavior: in disambiguate mode Shift+Tab becomes
        // CSI 9;2u rather than the legacy back-tab (CSI Z).
        let enc = KeyEncoder()
        XCTAssertEqual(enc.encode(chars: "\t", modifiers: [.shift], mode: kittyOn),
                       csiU(9, mod: 2))
    }

    func test_plainTab_disambiguateMode_stillHT() {
        let enc = KeyEncoder()
        XCTAssertEqual(enc.encode(chars: "\t", modifiers: [], mode: kittyOn),
                       Data([0x09]))
    }

    func test_shiftTab_legacyMode_stillCsiZ() {
        // Existing contract: readline's reverse-menu relies on CSI Z when the
        // TUI hasn't negotiated kitty. Preserve it.
        let enc = KeyEncoder()
        XCTAssertEqual(enc.encode(chars: "\t", modifiers: [.shift], mode: []),
                       Data([0x1B, 0x5B, 0x5A]))
    }

    // MARK: - Backspace

    func test_shiftBackspace_disambiguateMode_emitsCsiU() {
        let enc = KeyEncoder()
        XCTAssertEqual(enc.encode(chars: "\u{7F}", modifiers: [.shift], mode: kittyOn),
                       csiU(127, mod: 2))
    }

    func test_plainBackspace_disambiguateMode_stillDel() {
        let enc = KeyEncoder()
        XCTAssertEqual(enc.encode(chars: "\u{7F}", modifiers: [], mode: kittyOn),
                       Data([0x7F]))
    }

    // MARK: - Escape

    func test_shiftEsc_disambiguateMode_emitsCsiU() {
        let enc = KeyEncoder()
        XCTAssertEqual(enc.encode(chars: "\u{1B}", modifiers: [.shift], mode: kittyOn),
                       csiU(27, mod: 2))
    }

    func test_plainEsc_disambiguateMode_stillEsc() {
        let enc = KeyEncoder()
        XCTAssertEqual(enc.encode(chars: "\u{1B}", modifiers: [], mode: kittyOn),
                       Data([0x1B]))
    }

    // MARK: - ⌘ always suppressed

    func test_cmdShiftEnter_isSuppressed_evenWithKitty() {
        // Defence-in-depth: if ⌘ were ever passed in with Shift+Enter, we
        // must not leak the CSI u sequence as PTY bytes.
        let enc = KeyEncoder()
        XCTAssertEqual(enc.encode(chars: "\r", modifiers: [.command, .shift], mode: kittyOn),
                       Data())
    }

    // MARK: - Option / Meta under kitty (regression for bypass bug)

    // Historical bug (audit C1 / key-encoder F2): with optionIsMeta=true and
    // kitty flag 1 active, Option+{Enter, Esc, Tab, Backspace} fell through
    // the hasMods predicate and emitted legacy "ESC <byte>" — for Esc that
    // meant two raw ESCs, which nvim interprets as an abort. All four must
    // emit `CSI <cp>;3u` so the TUI sees the Alt modifier unambiguously.

    func test_optionEnter_metaMode_emitsCsiU() {
        let enc = KeyEncoder(optionIsMeta: true)
        XCTAssertEqual(enc.encode(chars: "\r", modifiers: [.option], mode: kittyOn),
                       csiU(13, mod: 3))
    }

    func test_optionEsc_metaMode_emitsCsiU_notDoubleEsc() {
        let enc = KeyEncoder(optionIsMeta: true)
        XCTAssertEqual(enc.encode(chars: "\u{1B}", modifiers: [.option], mode: kittyOn),
                       csiU(27, mod: 3))
    }

    func test_optionTab_metaMode_emitsCsiU() {
        let enc = KeyEncoder(optionIsMeta: true)
        XCTAssertEqual(enc.encode(chars: "\t", modifiers: [.option], mode: kittyOn),
                       csiU(9, mod: 3))
    }

    func test_optionBackspace_metaMode_emitsCsiU() {
        let enc = KeyEncoder(optionIsMeta: true)
        XCTAssertEqual(enc.encode(chars: "\u{7F}", modifiers: [.option], mode: kittyOn),
                       csiU(127, mod: 3))
    }

    // Native-Option mode: Option is invisible to the shell for modified
    // specials too. Option+Enter under kitty should fall through to plain
    // CR, not emit an Alt-bit in the CSI u.

    func test_optionEnter_nativeMode_fallsThroughToCR() {
        let enc = KeyEncoder(optionIsMeta: false)
        XCTAssertEqual(enc.encode(chars: "\r", modifiers: [.option], mode: kittyOn),
                       Data([0x0D]))
    }

    func test_optionTab_nativeMode_fallsThroughToHT() {
        let enc = KeyEncoder(optionIsMeta: false)
        XCTAssertEqual(enc.encode(chars: "\t", modifiers: [.option], mode: kittyOn),
                       Data([0x09]))
    }

    // Native-Option + Shift: shift still must appear in the CSI u, but Alt
    // (bit 2) must not. Audit F4.

    func test_shiftOptionEnter_nativeMode_csiUShiftOnly() {
        let enc = KeyEncoder(optionIsMeta: false)
        XCTAssertEqual(enc.encode(chars: "\r", modifiers: [.shift, .option], mode: kittyOn),
                       csiU(13, mod: 2))
    }

    // Option+printable under kitty + Meta mode — legacy ESC-prefix Meta.
    // Kitty flag 1 only disambiguates the four C0-aliasing keys; other
    // printables still use Meta-ESC so Emacs M-x etc. keep working.

    func test_optionA_metaMode_kittyOn_stillEscPrefix() {
        let enc = KeyEncoder(optionIsMeta: true)
        XCTAssertEqual(enc.encode(chars: "a", modifiers: [.option], mode: kittyOn),
                       Data([0x1B, 0x61]))
    }

    // MARK: - Multi-modifier Ctrl collisions (audit F6 / F7)

    func test_shiftCtrlI_kitty_distinctFromCtrlI() {
        // AppKit delivers Shift+Ctrl+i with chars="I". Without the fix the
        // encoder fell through to controlByte and emitted 0x09 (Tab), so a
        // TUI couldn't tell Shift+Ctrl+i from plain Tab.
        let enc = KeyEncoder()
        let out = enc.encode(chars: "I", modifiers: [.shift, .control], mode: kittyOn)
        XCTAssertEqual(out, csiU(105, mod: 6),
                       "Shift+Ctrl+i must emit CSI 105;6u under kitty, not the Tab byte")
    }

    func test_shiftCtrlOpenBracket_kitty_distinctFromEsc() {
        // Same shape as F7: Shift+Ctrl+[ must NOT collapse to bare ESC.
        let enc = KeyEncoder()
        let out = enc.encode(chars: "{", modifiers: [.shift, .control], mode: kittyOn)
        // On US layout Shift+[ produces "{", but kitty wants the unshifted
        // collider's codepoint with shift in the mod param. We accept either
        // the shifted "{" (123) path or the unshifted "[" (91) path — but
        // the bare 0x1B escape is the regression.
        XCTAssertNotEqual(out, Data([0x1B]),
                          "Shift+Ctrl+[ must not fall through to bare ESC")
    }

    func test_shiftCtrlM_kitty_distinctFromEnter() {
        let enc = KeyEncoder()
        let out = enc.encode(chars: "M", modifiers: [.shift, .control], mode: kittyOn)
        XCTAssertEqual(out, csiU(109, mod: 6))
    }

    func test_ctrlOptionI_metaMode_kitty_distinctFromCtrlI() {
        // Three-mod combo: Option-as-Meta + Ctrl + i. All three bits in the
        // mod param (shift=1, alt=2, ctrl=4) → mod 1 + 2 + 4 = 7.
        let enc = KeyEncoder(optionIsMeta: true)
        let out = enc.encode(chars: "i", modifiers: [.option, .control], mode: kittyOn)
        XCTAssertEqual(out, csiU(105, mod: 7))
    }

    // MARK: - Progressive enhancement flags 2/4/8/16 (pin current no-op)

    // Flag 2 (reportEventTypes) is implemented — see the "event type"
    // tests below. Flags 4/8/16 are accepted via the mode bitfield but
    // the encoder doesn't consume them yet (key-encoder F1 deferred
    // pieces). Pin today's no-op behaviour so a future change has to
    // update these tests deliberately.

    func test_flag2_reportEventTypes_doesNotAlterKeyDownEncoding() {
        // press event-type encodes identically whether flag 2 is on or
        // off. The only visible change is that keyUp emits CSI-u with
        // a release event (tested below).
        let enc = KeyEncoder()
        let mode: BBTermMode = [.disambiguateEscCodes, .reportEventTypes]
        XCTAssertEqual(enc.encode(chars: "\r", modifiers: [.shift], mode: mode),
                       csiU(13, mod: 2))
    }

    // MARK: - Flag 2: release events

    func test_flag2_release_on_csiU_key_emitsReleaseSuffix() {
        // Shift+Enter press emits ESC[13;2u. Flag 2 makes the paired
        // release emit ESC[13;2:3u (same modifier, event-type 3 = release).
        let enc = KeyEncoder()
        let mode: BBTermMode = [.disambiguateEscCodes, .reportEventTypes]
        let out = enc.encode(
            chars: "\r", modifiers: [.shift], mode: mode, eventType: .release
        )
        XCTAssertEqual(out, Data("\u{1B}[13;2:3u".utf8))
    }

    func test_flag2_release_without_modifier_stillIncludesModField() {
        // Release events ALWAYS emit the modifier field even when the
        // effective modifier is 1 (none) — the `:3` sub-parameter has
        // no place to attach without it. Spec-compliant Kitty parsers
        // reject a bare ESC[13:3u.
        let enc = KeyEncoder()
        let mode: BBTermMode = [.disambiguateEscCodes, .reportEventTypes]
        let out = enc.encode(
            chars: "\r", modifiers: [], mode: mode, eventType: .release
        )
        // Unmodified Enter doesn't hit the CSI-u path; release drops.
        XCTAssertEqual(out, Data())
    }

    func test_flag2_release_without_flag2_returnsEmpty() {
        // Without flag 2, release events must never emit bytes — legacy
        // TUIs crash on unexpected post-keystroke traffic.
        let enc = KeyEncoder()
        let out = enc.encode(
            chars: "\r", modifiers: [.shift], mode: kittyOn, eventType: .release
        )
        XCTAssertEqual(out, Data())
    }

    func test_flag2_release_plainPrintableKey_returnsEmpty() {
        // Plain 'a' keyDown emits 0x61 — no CSI u, no release event
        // either. Release reporting only applies to keys that went
        // through a CSI-u branch.
        let enc = KeyEncoder()
        let mode: BBTermMode = [.disambiguateEscCodes, .reportEventTypes]
        XCTAssertEqual(
            enc.encode(chars: "a", modifiers: [], mode: mode, eventType: .release),
            Data()
        )
    }

    func test_flag2_release_ctrlCollider_emitsReleaseSuffix() {
        // Ctrl+i under flag 1+2: press is ESC[105;5u, release is
        // ESC[105;5:3u.
        let enc = KeyEncoder()
        let mode: BBTermMode = [.disambiguateEscCodes, .reportEventTypes]
        let out = enc.encode(
            chars: "i", modifiers: [.control], mode: mode, eventType: .release
        )
        XCTAssertEqual(out, Data("\u{1B}[105;5:3u".utf8))
    }

    func test_flag2_repeat_encodesLikePressWithEventType2() {
        // Repeat event-type = 2. ESC[13;2:2u for Shift+Enter repeat.
        let enc = KeyEncoder()
        let mode: BBTermMode = [.disambiguateEscCodes, .reportEventTypes]
        let out = enc.encode(
            chars: "\r", modifiers: [.shift], mode: mode, eventType: .repeat
        )
        XCTAssertEqual(out, Data("\u{1B}[13;2:2u".utf8))
    }

    func test_flag4_reportAlternateKeys_doesNotAlterEncoding() {
        let enc = KeyEncoder()
        let mode: BBTermMode = [.disambiguateEscCodes, .reportAlternateKeys]
        XCTAssertEqual(enc.encode(chars: "\r", modifiers: [.shift], mode: mode),
                       csiU(13, mod: 2))
    }

    func test_flag8_reportAllKeysAsEsc_doesNotAlterEncoding() {
        let enc = KeyEncoder()
        let mode: BBTermMode = [.disambiguateEscCodes, .reportAllKeysAsEsc]
        XCTAssertEqual(enc.encode(chars: "a", modifiers: [], mode: mode),
                       Data([0x61]))
    }

    func test_flag16_reportAssociatedText_doesNotAlterEncoding() {
        let enc = KeyEncoder()
        let mode: BBTermMode = [.disambiguateEscCodes, .reportAssociatedText]
        XCTAssertEqual(enc.encode(chars: "\r", modifiers: [.shift], mode: mode),
                       csiU(13, mod: 2))
    }

    func test_allFlagsTogether_doNotAlterEncoding() {
        let enc = KeyEncoder()
        let mode: BBTermMode = [.disambiguateEscCodes, .reportEventTypes,
                                .reportAlternateKeys, .reportAllKeysAsEsc,
                                .reportAssociatedText]
        XCTAssertEqual(enc.encode(chars: "\r", modifiers: [.shift], mode: mode),
                       csiU(13, mod: 2))
    }

    // MARK: - End-to-end: round-trip with real BBTerm

    func test_endToEnd_kittyProtocolLightsBitAndFlipsEncoder() {
        // Round trip: feed the protocol-enable sequence into a real BBTerm,
        // read the snapshot's BBTermMode, pass it to the encoder — the encoder
        // must switch behavior.
        guard let term = BBTerm(size: .init(cols: 80, rows: 24)) else {
            XCTFail("BBTerm init")
            return
        }
        term.input("\u{1B}[>1u")
        guard let snap = term.snapshot() else {
            XCTFail("snapshot")
            return
        }
        XCTAssertTrue(snap.termMode.contains(.disambiguateEscCodes),
                      "ESC[>1u must light disambiguateEscCodes")

        let enc = KeyEncoder()
        XCTAssertEqual(enc.encode(chars: "\r", modifiers: [.shift], mode: snap.termMode),
                       csiU(13, mod: 2))
    }
}
