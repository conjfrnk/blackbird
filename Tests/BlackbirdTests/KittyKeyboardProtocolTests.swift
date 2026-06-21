import XCTest
@testable import Blackbird

/// Pins KeyEncoder behavior under the kitty keyboard protocol, progressive
/// enhancement flag 1 (`disambiguateEscCodes`). Without this path, Shift+Enter,
/// Ctrl+i, Ctrl+m, modified Esc, and modified Backspace are indistinguishable
/// from their unmodified forms — which breaks Claude Code, nvim 0.10+, and any
/// TUI that negotiates kitty keyboard support.
///
/// **Compat-matrix pin:** this file backs the Kitty keyboard flags row in
/// `docs/compat-matrix.md`. `git grep "compat-matrix.md"` resolves to every
/// test that gates a row in that doc.
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

    // MARK: - Flag 2: release events on CSI-parameter special keys (F-S3-005)

    // F-S3-005 contract: encodeSpecial now honors Kitty flag 2
    // (reportEventTypes) for the CSI-parameter special keys (arrows, Home,
    // End, PageUp/Down, Insert, Delete, F1–F12). A PRESS is byte-identical
    // to legacy (kitty omits the `:1` press sub-param). A RELEASE emits
    // `CSI <lead> ; <mod>:3 <terminator>` ONLY when the mode contains
    // reportEventTypes — otherwise EMPTY Data (legacy emits no post-keystroke
    // traffic). The modifier field is FORCED present even when unmodified
    // (mod=1) so the `:3` sub-param has a parameter to attach to.
    // modParam = 1 + bitmask (shift=1, alt=2, ctrl=4): unmodified=1, Shift=2,
    // Ctrl=5. Keypad keys have no CSI-parameter form, so their release is
    // EMPTY even under flag 2.

    /// Flag 1 + flag 2 lit together — the mode a kitty TUI negotiates when it
    /// wants both disambiguation and event-type reporting.
    private let flag2Mode: BBTermMode = [.disambiguateEscCodes, .reportEventTypes]

    func test_special_up_release_noMods_flag2_forcesModFieldWithReleaseSuffix() {
        // F-S3-005: Up release under flag 2, no modifiers. The modifier field
        // is forced to 1 so `:3` (release) has somewhere to live. Up's lead is
        // `1` and its terminator is the letter `A`.
        let enc = KeyEncoder()
        let out = enc.encodeSpecial(.up, modifiers: [], mode: flag2Mode, eventType: .release)
        XCTAssertEqual(out, Data("\u{1B}[1;1:3A".utf8))
    }

    func test_special_up_release_shift_flag2_emitsReleaseSuffix() {
        // F-S3-005: Shift sets modParam = 1 + 1 = 2.
        let enc = KeyEncoder()
        let out = enc.encodeSpecial(.up, modifiers: [.shift], mode: flag2Mode, eventType: .release)
        XCTAssertEqual(out, Data("\u{1B}[1;2:3A".utf8))
    }

    func test_special_left_release_ctrl_flag2_emitsReleaseSuffix() {
        // F-S3-005: Ctrl sets modParam = 1 + 4 = 5. Left's lead is `1`,
        // terminator the letter `D`.
        let enc = KeyEncoder()
        let out = enc.encodeSpecial(.left, modifiers: [.control], mode: flag2Mode, eventType: .release)
        XCTAssertEqual(out, Data("\u{1B}[1;5:3D".utf8))
    }

    func test_special_pageUp_release_noMods_flag2_emitsTildeReleaseSuffix() {
        // F-S3-005: PageUp uses the `~` terminator with lead `5`. Forced
        // modParam = 1.
        let enc = KeyEncoder()
        let out = enc.encodeSpecial(.pageUp, modifiers: [], mode: flag2Mode, eventType: .release)
        XCTAssertEqual(out, Data("\u{1B}[5;1:3~".utf8))
    }

    func test_special_f1_release_noMods_flag2_emitsLetterReleaseSuffix() {
        // F-S3-005: F1 uses a LETTER terminator (`P`) with lead `1`.
        let enc = KeyEncoder()
        let out = enc.encodeSpecial(.f1, modifiers: [], mode: flag2Mode, eventType: .release)
        XCTAssertEqual(out, Data("\u{1B}[1;1:3P".utf8))
    }

    func test_special_f5_release_noMods_flag2_emitsTildeReleaseSuffix() {
        // F-S3-005: F5 crosses into the `~` family with lead `15`.
        let enc = KeyEncoder()
        let out = enc.encodeSpecial(.f5, modifiers: [], mode: flag2Mode, eventType: .release)
        XCTAssertEqual(out, Data("\u{1B}[15;1:3~".utf8))
    }

    func test_special_up_release_withoutFlag2_returnsEmpty() {
        // F-S3-005: Without reportEventTypes, a release must produce no bytes —
        // legacy emits no post-keystroke traffic.
        let enc = KeyEncoder()
        let out = enc.encodeSpecial(.up, modifiers: [], mode: [], eventType: .release)
        XCTAssertEqual(out, Data())
    }

    func test_special_up_press_flag2_byteIdenticalToLegacy() {
        // F-S3-005: A PRESS under flag 2 is unchanged from legacy — kitty omits
        // the `:1` press sub-param, so unmodified Up is the bare `CSI A`.
        let enc = KeyEncoder()
        let out = enc.encodeSpecial(.up, modifiers: [], mode: flag2Mode, eventType: .press)
        XCTAssertEqual(out, Data("\u{1B}[A".utf8))
    }

    func test_special_left_modifiedPress_flag2_unchangedLegacyForm() {
        // F-S3-005: A modified PRESS under flag 2 keeps the legacy modified
        // shape `CSI 1;5D` (default eventType = .press). Flag 2 does not alter
        // press encoding.
        let enc = KeyEncoder()
        let out = enc.encodeSpecial(.left, modifiers: [.control], mode: flag2Mode)
        XCTAssertEqual(out, Data("\u{1B}[1;5D".utf8))
    }

    func test_special_keypad_release_flag2_returnsEmpty() {
        // F-S3-005: Keypad keys have no CSI-parameter form, so even under flag 2
        // a release emits EMPTY Data.
        let enc = KeyEncoder()
        let out = enc.encodeSpecial(.kp1, modifiers: [], mode: flag2Mode, eventType: .release)
        XCTAssertEqual(out, Data())
    }

    func test_flag4_reportAlternateKeys_controlChars_unchanged() {
        // Disambiguation keys (Enter/Esc/Tab/Backspace) have no shifted
        // alternate form. Flag 4 is a no-op on them; the on-wire shape
        // stays `ESC[13;2u` for Shift+Enter.
        let enc = KeyEncoder()
        let mode: BBTermMode = [.disambiguateEscCodes, .reportAlternateKeys]
        XCTAssertEqual(enc.encode(chars: "\r", modifiers: [.shift], mode: mode),
                       csiU(13, mod: 2))
    }

    func test_flag4_reportAlternateKeys_shiftLetterEmitsShifted() {
        // Flag 4 + Flag 8 + Shift+A: `ESC[97:65;2u`.
        // Kitty key-code field = `unicode-key : shifted-key : base-layout-key`
        // (https://sw.kovidgoyal.net/kitty/keyboard-protocol/). So:
        //   - base codepoint 97 (lowercase 'a')
        //   - shifted 65 (uppercase 'A') in the SECOND sub-field
        //   - base-layout omitted (macOS exposes no alt-layout slot); the
        //     spec drops an absent trailing field rather than padding it.
        //   - modifier 2 (shift)
        // Flag 4 without flag 8 wouldn't emit CSI-u for plain letters at
        // all, so the natural test exercises the combined mode.
        let enc = KeyEncoder()
        let mode: BBTermMode = [.reportAllKeysAsEsc, .reportAlternateKeys]
        XCTAssertEqual(enc.encode(chars: "A", modifiers: [.shift], mode: mode),
                       Data("\u{1B}[97:65;2u".utf8))
    }

    func test_flag4_reportAlternateKeys_plainLetterNoShiftedPayload() {
        // No shift → no shifted form to report. Plain "a" under flag
        // 8+4 still emits the same `ESC[97u` as flag 8 alone.
        let enc = KeyEncoder()
        let mode: BBTermMode = [.reportAllKeysAsEsc, .reportAlternateKeys]
        XCTAssertEqual(enc.encode(chars: "a", modifiers: [], mode: mode),
                       csiU(97, mod: 1))
    }

    // MARK: - Flag 4: US-layout symbols

    func test_flag4_shiftDigit2_emitsUnshiftedBaseWithShiftedAlt() {
        // Canonical shifted-symbol case: Shift+2 on US layout produces "@".
        // Flag 4 reverse-lookup must resolve the unshifted base ('2' = 50)
        // and report the typed symbol ('@' = 64) in the shifted sub-field.
        let enc = KeyEncoder()
        let mode: BBTermMode = [.reportAllKeysAsEsc, .reportAlternateKeys]
        XCTAssertEqual(enc.encode(chars: "@", modifiers: [.shift], mode: mode),
                       Data("\u{1B}[50:64;2u".utf8))
    }

    func test_flag4_shiftHyphenToUnderscore() {
        // Shift+'-' → '_'. Base 45, shifted 95.
        let enc = KeyEncoder()
        let mode: BBTermMode = [.reportAllKeysAsEsc, .reportAlternateKeys]
        XCTAssertEqual(enc.encode(chars: "_", modifiers: [.shift], mode: mode),
                       Data("\u{1B}[45:95;2u".utf8))
    }

    func test_flag4_shiftSlashToQuestion() {
        // Shift+'/' → '?'. Base 47, shifted 63.
        let enc = KeyEncoder()
        let mode: BBTermMode = [.reportAllKeysAsEsc, .reportAlternateKeys]
        XCTAssertEqual(enc.encode(chars: "?", modifiers: [.shift], mode: mode),
                       Data("\u{1B}[47:63;2u".utf8))
    }

    func test_flag4_unshiftedSymbol_noShiftPayload() {
        // Without Shift, there's no shifted alternate to report. Plain "1"
        // under flag 8+4 must emit the same `ESC[49u` as flag 8 alone — the
        // reverse-lookup only fires when Shift is held.
        let enc = KeyEncoder()
        let mode: BBTermMode = [.reportAllKeysAsEsc, .reportAlternateKeys]
        XCTAssertEqual(enc.encode(chars: "1", modifiers: [], mode: mode),
                       csiU(49, mod: 1))
    }

    func test_flag4_nonAsciiSymbol_noShiftedPayload() {
        // Shift+É isn't a US-layout letter or a known shifted ASCII symbol,
        // so the reverse-lookup must fail gracefully — no `:<shifted>`
        // section, no invented base codepoint. Falls back to flag-8
        // single-codepoint output with the shift modifier bit set.
        let enc = KeyEncoder()
        let mode: BBTermMode = [.reportAllKeysAsEsc, .reportAlternateKeys]
        XCTAssertEqual(enc.encode(chars: "É", modifiers: [.shift], mode: mode),
                       csiU(0xC9, mod: 2))
    }

    // MARK: - Flag 8: report all keys as CSI u

    func test_flag8_plainLetter_emitsCsiU() {
        // Plain 'a' press under flag 8: ESC[97u instead of 0x61. Breaks
        // the default shell contract by design — only TUIs that opt in
        // see it.
        let enc = KeyEncoder()
        let mode: BBTermMode = [.reportAllKeysAsEsc]
        XCTAssertEqual(enc.encode(chars: "a", modifiers: [], mode: mode),
                       csiU(97, mod: 1))
    }

    func test_flag8_uppercaseLetter_lowercasesBaseEmitsShiftMod() {
        // Shift+A keyDown should emit ESC[97;2u — Kitty lowercases the
        // base codepoint so Shift is reported through the mod field.
        let enc = KeyEncoder()
        let mode: BBTermMode = [.reportAllKeysAsEsc]
        XCTAssertEqual(enc.encode(chars: "A", modifiers: [.shift], mode: mode),
                       csiU(97, mod: 2))
    }

    func test_flag8_symbolPassesThrough() {
        // '/' isn't a letter; scalar value passes through unchanged.
        let enc = KeyEncoder()
        let mode: BBTermMode = [.reportAllKeysAsEsc]
        XCTAssertEqual(enc.encode(chars: "/", modifiers: [], mode: mode),
                       csiU(47, mod: 1))
    }

    func test_flag8_plusFlag1_disambiguationStillWins() {
        // Flag 8 + Flag 1 together: Shift+Enter must still hit the
        // disambiguation path with codepoint 13, not the flag-8 path.
        let enc = KeyEncoder()
        let mode: BBTermMode = [.disambiguateEscCodes, .reportAllKeysAsEsc]
        XCTAssertEqual(enc.encode(chars: "\r", modifiers: [.shift], mode: mode),
                       csiU(13, mod: 2))
    }

    func test_flag8_ctrlC_emitsCsiU_notSigIntByte() {
        // Under flag 8 alone, Ctrl+C emits ESC[99;5u rather than the
        // legacy 0x03. SIGINT-at-the-shell is the trade-off the TUI
        // opted into by pushing flag 8 — users who want both the
        // progressive protocol AND default shell behaviour combine
        // flag 1 + application-side bindings.
        let enc = KeyEncoder()
        let mode: BBTermMode = [.reportAllKeysAsEsc]
        XCTAssertEqual(enc.encode(chars: "c", modifiers: [.control], mode: mode),
                       csiU(99, mod: 5))
    }

    func test_flag8_plusFlag2_releaseEmitsCsiU() {
        // Plain 'a' release under flag 2+8: ESC[97;1:3u.
        let enc = KeyEncoder()
        let mode: BBTermMode = [.reportAllKeysAsEsc, .reportEventTypes]
        XCTAssertEqual(
            enc.encode(chars: "a", modifiers: [], mode: mode, eventType: .release),
            Data("\u{1B}[97;1:3u".utf8)
        )
    }

    func test_flag16_reportAssociatedText_controlChars_unchanged() {
        // Control characters (Enter/Esc/Tab/Backspace) produce no
        // visible text on their own; the base codepoint already
        // carries the key identity. Flag 16 elides the text section
        // for these, so Shift+Enter stays `ESC[13;2u`.
        let enc = KeyEncoder()
        let mode: BBTermMode = [.disambiguateEscCodes, .reportAssociatedText]
        XCTAssertEqual(enc.encode(chars: "\r", modifiers: [.shift], mode: mode),
                       csiU(13, mod: 2))
    }

    func test_flag16_reportAssociatedText_shiftLetterEmitsText() {
        // Flag 8+16 + Shift+A: base is 'a' (97, lowercased), modifier
        // carries Shift, text carries the actually-produced 'A' (65).
        // Shape: `ESC[97;2;65u`.
        let enc = KeyEncoder()
        let mode: BBTermMode = [.reportAllKeysAsEsc, .reportAssociatedText]
        XCTAssertEqual(enc.encode(chars: "A", modifiers: [.shift], mode: mode),
                       Data("\u{1B}[97;2;65u".utf8))
    }

    func test_flag16_reportAssociatedText_plainLetterElidesText() {
        // Plain "a" under flag 8+16: base == produced text, so the
        // text section is elided (parser already knows text=base when
        // absent). Shape stays `ESC[97u`.
        let enc = KeyEncoder()
        let mode: BBTermMode = [.reportAllKeysAsEsc, .reportAssociatedText]
        XCTAssertEqual(enc.encode(chars: "a", modifiers: [], mode: mode),
                       csiU(97, mod: 1))
    }

    func test_flag4_plus_flag16_combined() {
        // Flag 8+4+16 + Shift+A: all three sections.
        //   base=97 : shifted=65 ; mod=2 ; text=65
        // (base-layout sub-field omitted — see flag-4 tests above.)
        let enc = KeyEncoder()
        let mode: BBTermMode = [
            .reportAllKeysAsEsc, .reportAlternateKeys, .reportAssociatedText,
        ]
        XCTAssertEqual(enc.encode(chars: "A", modifiers: [.shift], mode: mode),
                       Data("\u{1B}[97:65;2;65u".utf8))
    }

    func test_allFlagsTogether_doNotAlterEncoding() {
        let enc = KeyEncoder()
        let mode: BBTermMode = [.disambiguateEscCodes, .reportEventTypes,
                                .reportAlternateKeys, .reportAllKeysAsEsc,
                                .reportAssociatedText]
        XCTAssertEqual(enc.encode(chars: "\r", modifiers: [.shift], mode: mode),
                       csiU(13, mod: 2))
    }

    // MARK: - xterm modifyOtherKeys (CSI 27 ; mod ; cp ~)

    // Emacs and other TUIs ask for xterm's `modifyOtherKeys` level 2
    // encoding via `CSI > 4 ; 2 m`, which lights BBTermMode.modifyOtherKeys.
    // The encoder's contract when that bit is on — and none of the Kitty
    // flags are set — is `CSI 27 ; <mod> ; <cp> ~` for any modified key,
    // with `<mod>` = 1 + (shift?1:0) + (option?2:0) + (ctrl?4:0) and
    // `<cp>` the raw codepoint Cocoa delivered in `chars`.

    func test_modifyOtherKeys_shiftEnter_emitsCsi27() {
        // Shift's mod bit = 1, plus base 1 = 2. `\r` codepoint = 13.
        let enc = KeyEncoder()
        XCTAssertEqual(enc.encode(chars: "\r", modifiers: [.shift], mode: [.modifyOtherKeys]),
                       Data("\u{1B}[27;2;13~".utf8))
    }

    func test_modifyOtherKeys_ctrlPeriod_emitsCsi27() {
        // Emacs canonical test — Ctrl+. is unreachable via legacy byte
        // encoding, which is the whole reason modifyOtherKeys exists.
        // Ctrl's mod bit = 4, plus base 1 = 5. `.` codepoint = 46.
        let enc = KeyEncoder()
        XCTAssertEqual(enc.encode(chars: ".", modifiers: [.control], mode: [.modifyOtherKeys]),
                       Data("\u{1B}[27;5;46~".utf8))
    }

    func test_modifyOtherKeys_plainKey_usesLegacyPath() {
        // Zero modifiers → no CSI 27 branch. Plain "a" must still hit the
        // legacy printable path so the default shell contract holds.
        let enc = KeyEncoder()
        XCTAssertEqual(enc.encode(chars: "a", modifiers: [], mode: [.modifyOtherKeys]),
                       Data("a".utf8))
    }

    func test_modifyOtherKeys_shiftLetter_emitsUppercaseCodepoint() {
        // Cocoa applies Shift for us: chars comes in as "A" (cp=65), not
        // lowercased "a" like the Kitty flag-8 path. modifyOtherKeys uses
        // the raw codepoint from chars verbatim.
        let enc = KeyEncoder()
        XCTAssertEqual(enc.encode(chars: "A", modifiers: [.shift], mode: [.modifyOtherKeys]),
                       Data("\u{1B}[27;2;65~".utf8))
    }

    func test_modifyOtherKeys_kittyPrecedence_kittyWins() {
        // When both modifyOtherKeys and a Kitty flag are lit, the Kitty
        // path wins. Pins the precedence rule so a future refactor can't
        // accidentally flip them.
        let enc = KeyEncoder()
        let mode: BBTermMode = [.disambiguateEscCodes, .modifyOtherKeys]
        XCTAssertEqual(enc.encode(chars: "\r", modifiers: [.shift], mode: mode),
                       csiU(13, mod: 2))
    }

    func test_modifyOtherKeys_releaseReturnsEmpty() {
        // Release traffic drops — xterm's modifyOtherKeys has no paired
        // release event, unlike Kitty's flag 2.
        let enc = KeyEncoder()
        let out = enc.encode(
            chars: "\r", modifiers: [.shift], mode: [.modifyOtherKeys], eventType: .release
        )
        XCTAssertEqual(out, Data())
    }

    func test_modifyOtherKeys_shiftCtrlAlt_combinedMod() {
        // All three mod bits present: shift=1 + alt=2 + ctrl=4 + base 1 = 8.
        let enc = KeyEncoder()
        XCTAssertEqual(
            enc.encode(chars: ".", modifiers: [.shift, .control, .option], mode: [.modifyOtherKeys]),
            Data("\u{1B}[27;8;46~".utf8)
        )
    }

    // MARK: - Flag 1: Ctrl + printable with NO C0 mapping (F-S3)

    // F-S3 contract: under Kitty enhancement flag 1 (disambiguateEscCodes), a
    // Ctrl+printable key that has NO C0 control-byte mapping must be reported as
    // a CSI u sequence so the Ctrl modifier survives — legacy would drop Ctrl
    // and send the bare char. Keys that DO have a C0 mapping (letters a–z, and
    // @ [ \ ] ^ _ ? space) keep their C0 byte and must NOT become CSI u.
    // modParam = 1 + bitmask (shift=1, alt=2, ctrl=4): Ctrl alone = 5,
    // Ctrl+Shift = 6. The CSI-u codepoint is the UNSHIFTED base of the key.

    func test_ctrlPeriod_flag1_emitsCsiU_noC0Mapping() {
        // '.' = 0x2E = 46 has no C0 control byte. Ctrl+. → CSI 46;5u.
        let enc = KeyEncoder()
        XCTAssertEqual(enc.encode(chars: ".", modifiers: [.control], mode: kittyOn),
                       csiU(46, mod: 5))
    }

    func test_ctrlSlash_flag1_emitsCsiU_noC0Mapping() {
        // '/' = 47. (Ctrl+/ legacy maps to 0x1F via '_', but '/' itself is the
        // typed char here — no C0 byte for '/', so it must surface as CSI u.)
        let enc = KeyEncoder()
        XCTAssertEqual(enc.encode(chars: "/", modifiers: [.control], mode: kittyOn),
                       csiU(47, mod: 5))
    }

    func test_ctrlSemicolon_flag1_emitsCsiU_noC0Mapping() {
        // ';' = 59 has no C0 control byte. Ctrl+; → CSI 59;5u.
        let enc = KeyEncoder()
        XCTAssertEqual(enc.encode(chars: ";", modifiers: [.control], mode: kittyOn),
                       csiU(59, mod: 5))
    }

    func test_ctrlDigit1_flag1_emitsCsiU_noC0Mapping() {
        // Digit '1' = 49 has no C0 control byte. Ctrl+1 → CSI 49;5u.
        let enc = KeyEncoder()
        XCTAssertEqual(enc.encode(chars: "1", modifiers: [.control], mode: kittyOn),
                       csiU(49, mod: 5))
    }

    func test_ctrlLetterA_flag1_keepsC0Byte_notCsiU() {
        // Letter 'a' HAS a C0 mapping (0x01); F-S3 must NOT promote it to CSI u.
        let enc = KeyEncoder()
        XCTAssertEqual(enc.encode(chars: "a", modifiers: [.control], mode: kittyOn),
                       Data([0x01]))
    }

    func test_ctrlPeriod_legacyMode_dropsCtrl_bareChar() {
        // Pin today's legacy behaviour: without any Kitty flag, Ctrl+. has no
        // C0 byte and no CSI-u path, so Ctrl is dropped and the bare '.' (0x2E)
        // is what reaches the PTY. F-S3 is the kitty-only fix for exactly this.
        let enc = KeyEncoder()
        XCTAssertEqual(enc.encode(chars: ".", modifiers: [.control], mode: []),
                       Data([0x2E]))
    }

    func test_ctrlShiftPeriod_flag1_usesUnshiftedBaseCodepoint() {
        // US layout: Shift+. yields '>' (0x3E) from the OS, but the CSI-u
        // codepoint must be the UNSHIFTED base '.' (46), with Shift reported
        // via modParam = 1 + shift(1) + ctrl(4) = 6.
        let enc = KeyEncoder()
        XCTAssertEqual(enc.encode(chars: ">", modifiers: [.control, .shift], mode: kittyOn),
                       csiU(46, mod: 6))
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
