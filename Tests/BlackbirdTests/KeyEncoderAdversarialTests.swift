import XCTest
@testable import Blackbird
@testable import BBCore

/// Adversarial coverage for `KeyEncoder` — fills the TST-S3 gaps and
/// stress-tests the contract under inputs that the existing
/// happy-path tests don't visit.
///
/// **Compat-matrix pin:** this file backs the `modifyOtherKeys` row in
/// `docs/compat-matrix.md`. The CSI 27 emit + suppression contract that
/// Emacs / tmux / Neovim expect is asserted here. `git grep
/// "compat-matrix.md"` resolves to every test that gates a row in that
/// doc.
///
/// Pre-flight memory cost: every test allocates one `KeyEncoder`
/// (no heap state), a small set of `Data` outputs, and at most a
/// handful of UTF-8 byte sequences. No PTY, no large grids, no
/// 2^16 dimensions. Total < 16 KiB across the whole file. Safe under
/// the 256 MiB MemoryBudget cap without an explicit `requireTestFitsInBudget`.
final class KeyEncoderAdversarialTests: XCTestCase {

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

    /// `ESC [ 27 ; <mod> ; <cp> ~` xterm modifyOtherKeys form.
    private func csi27(mod: Int, cp: Int) -> Data {
        Data("\u{1B}[27;\(mod);\(cp)~".utf8)
    }

    // MARK: - Flag 1 (disambiguateEscCodes) — Ctrl-collider regressions

    /// **TST-S3 gap (focus areas / Kitty flag 1):** Ctrl+i must NOT
    /// collapse to 0x09 under disambiguate; it must take the CSI u
    /// path. The existing `KittyKeyboardProtocolTests` covers
    /// `Ctrl+i → ESC[105;5u` once; we add the symmetric assertion that
    /// the legacy 0x09 byte never appears.
    func test_flag1_ctrlI_neverCollapsesToTab() {
        let enc = KeyEncoder()
        let mode: BBTermMode = [.disambiguateEscCodes]
        let out = enc.encode(chars: "i", modifiers: [.control], mode: mode)
        XCTAssertEqual(out, csiU(105, mod: 5),
                       "Ctrl+i under flag 1 must be ESC[105;5u")
        XCTAssertNotEqual(out, Data([0x09]),
                          "Ctrl+i under flag 1 must NEVER produce HT (0x09)")
    }

    /// Symmetric: Ctrl+m must NOT collapse to 0x0D.
    func test_flag1_ctrlM_neverCollapsesToCR() {
        let enc = KeyEncoder()
        let mode: BBTermMode = [.disambiguateEscCodes]
        let out = enc.encode(chars: "m", modifiers: [.control], mode: mode)
        XCTAssertEqual(out, csiU(109, mod: 5),
                       "Ctrl+m under flag 1 must be ESC[109;5u")
        XCTAssertNotEqual(out, Data([0x0D]),
                          "Ctrl+m under flag 1 must NEVER produce CR (0x0D)")
    }

    /// Symmetric for Ctrl+[ → not bare ESC, and Ctrl+h → not 0x08.
    func test_flag1_ctrlOpenBracket_neverCollapsesToEsc() {
        let enc = KeyEncoder()
        let out = enc.encode(chars: "[", modifiers: [.control], mode: [.disambiguateEscCodes])
        XCTAssertEqual(out, csiU(91, mod: 5))
        XCTAssertNotEqual(out, Data([0x1B]),
                          "Ctrl+[ under flag 1 must NEVER produce bare ESC")
    }

    func test_flag1_ctrlH_neverCollapsesToBS() {
        let enc = KeyEncoder()
        let out = enc.encode(chars: "h", modifiers: [.control], mode: [.disambiguateEscCodes])
        XCTAssertEqual(out, csiU(104, mod: 5))
        // 0x08 (BS) is what Ctrl+h would produce in legacy mode if
        // controlByte['h'-'a'] = 0x08 were applied. Pin it doesn't.
        XCTAssertNotEqual(out, Data([0x08]),
                          "Ctrl+h under flag 1 must NEVER produce BS (0x08)")
    }

    // MARK: - Flag 4 (reportAlternateKeys) — every US-layout shifted symbol

    /// **TST-S3 gap (focus areas / Kitty flag 4):** the existing tests
    /// pin `@` (Shift+2), `_` (Shift+-), and `?` (Shift+/). The full
    /// US-layout shifted-symbol table has 11 more entries — pin them
    /// all so a regression that drops one row of the lookup table
    /// fails the right test.
    ///
    /// Format: `(typed_glyph, base_codepoint_unshifted)` for each
    /// US-layout shifted-symbol pair. The encoder under flag 8+4
    /// must emit `ESC [ <base> : 0 : <typed> ; 2 u`.
    func test_flag4_allUSLayoutShiftedSymbols() {
        let enc = KeyEncoder()
        let mode: BBTermMode = [.reportAllKeysAsEsc, .reportAlternateKeys]

        // (typed: shifted glyph, base: unshifted ASCII codepoint, name).
        // US-layout pairs: '!'<-'1', '@'<-'2', '#'<-'3', '$'<-'4',
        // '%'<-'5', '^'<-'6', '&'<-'7', '*'<-'8', '('<-'9', ')'<-'0',
        // '_'<-'-', '+'<-'=', '{'<-'[', '}'<-']', '|'<-'\', ':'<-';',
        // '"'<-'\'', '<'<-',', '>'<-'.', '?'<-'/', '~'<-'`'.
        let pairs: [(String, Int, String)] = [
            ("!",  Int(Character("1").asciiValue!), "Shift+1 → !"),
            ("@",  Int(Character("2").asciiValue!), "Shift+2 → @"),
            ("#",  Int(Character("3").asciiValue!), "Shift+3 → #"),
            ("$",  Int(Character("4").asciiValue!), "Shift+4 → $"),
            ("%",  Int(Character("5").asciiValue!), "Shift+5 → %"),
            ("^",  Int(Character("6").asciiValue!), "Shift+6 → ^"),
            ("&",  Int(Character("7").asciiValue!), "Shift+7 → &"),
            ("*",  Int(Character("8").asciiValue!), "Shift+8 → *"),
            ("(",  Int(Character("9").asciiValue!), "Shift+9 → ("),
            (")",  Int(Character("0").asciiValue!), "Shift+0 → )"),
            ("_",  Int(Character("-").asciiValue!), "Shift+- → _"),
            ("+",  Int(Character("=").asciiValue!), "Shift+= → +"),
            ("{",  Int(Character("[").asciiValue!), "Shift+[ → {"),
            ("}",  Int(Character("]").asciiValue!), "Shift+] → }"),
            ("|",  Int(Character("\\").asciiValue!), "Shift+\\ → |"),
            (":",  Int(Character(";").asciiValue!), "Shift+; → :"),
            ("\"", Int(Character("'").asciiValue!), "Shift+' → \""),
            ("<",  Int(Character(",").asciiValue!), "Shift+, → <"),
            (">",  Int(Character(".").asciiValue!), "Shift+. → >"),
            ("?",  Int(Character("/").asciiValue!), "Shift+/ → ?"),
            ("~",  Int(Character("`").asciiValue!), "Shift+` → ~"),
        ]

        for (typed, base, name) in pairs {
            let typedScalar = Int(typed.unicodeScalars.first!.value)
            let expected = Data("\u{1B}[\(base):0:\(typedScalar);2u".utf8)
            let actual = enc.encode(chars: typed, modifiers: [.shift], mode: mode)
            XCTAssertEqual(actual, expected,
                           "\(name): expected ESC[\(base):0:\(typedScalar);2u, got \(Array(actual))")
        }
    }

    /// Document the deliberate gap: non-US layouts (e.g. Dvorak,
    /// Colemak, German QWERTZ) are NOT covered by `reportAlternateKeys`
    /// today. The reverse-lookup table is hard-coded for US QWERTY.
    /// On a non-US layout, a Shift+key combination would still
    /// produce *some* shifted symbol from Cocoa, but we can't infer
    /// the unshifted base without a system-keyboard query (which we
    /// don't issue). Pin today's behaviour: a shifted non-ASCII glyph
    /// falls through with no `:0:<shifted>` payload — just the single-
    /// codepoint CSI u with the shift bit in the mod field.
    func test_flag4_nonUSLayout_isExplicitlyNotCovered() {
        let enc = KeyEncoder()
        let mode: BBTermMode = [.reportAllKeysAsEsc, .reportAlternateKeys]
        // German QWERTZ Shift+ä would produce 'Ä' (U+00C4). The
        // encoder cannot reverse-look-up to 'ä', so it emits a
        // single-codepoint CSI u with the shifted glyph as the base.
        let out = enc.encode(chars: "Ä", modifiers: [.shift], mode: mode)
        // `Ä` = U+00C4 = 196.
        XCTAssertEqual(out, csiU(196, mod: 2),
                       "Non-US shifted glyph falls through to single-cp CSI u")
        // Specifically: must NOT contain `:0:` (which would imply a
        // reverse-lookup happened).
        XCTAssertFalse(out.contains(0x3A),  // ':' = 0x3A
                       "Non-US fallback must not include the alternate ':' separator")
    }

    // MARK: - Flag 8 (reportAllKeysAsEsc) — Ctrl-letter colliders

    /// **TST-S3 gap (focus areas / Kitty flag 8):** every Ctrl-letter
    /// — including the C0-collider letters (i, m, [, h, c) — must
    /// take the CSI u path under flag 8 alone. Even Ctrl+C, which
    /// flag 1 deliberately leaves as 0x03, must become CSI u under
    /// flag 8 because the TUI has explicitly asked for "all keys".
    func test_flag8_allCtrlLetters_csiU() {
        let enc = KeyEncoder()
        let mode: BBTermMode = [.reportAllKeysAsEsc]
        // a..z lowercase. AppKit delivers Ctrl+letter as the lowercase
        // letter (no shift), so we test the lowercase branch.
        for code in UInt8(0x61)...UInt8(0x7A) {
            let ch = String(UnicodeScalar(code))
            let out = enc.encode(chars: ch, modifiers: [.control], mode: mode)
            XCTAssertEqual(out, csiU(Int(code), mod: 5),
                           "Ctrl+\(ch) under flag 8 must be ESC[\(code);5u")
            // Negative: the legacy 0x01..0x1A controlByte must NOT
            // appear in the output.
            let legacyByte = code - 0x60
            XCTAssertNotEqual(out, Data([legacyByte]),
                              "Ctrl+\(ch) under flag 8 must NOT collapse to 0x\(String(legacyByte, radix: 16))")
        }
    }

    /// Flag 8 + uppercase letter: Cocoa delivers Shift+A as chars="A".
    /// Under flag 8 the base codepoint is lowercased (a=97), and Shift
    /// shows up in the mod field (mod=2). Pin the entire alphabet.
    func test_flag8_allUppercaseLetters_lowerBaseShiftMod() {
        let enc = KeyEncoder()
        let mode: BBTermMode = [.reportAllKeysAsEsc]
        for upperCode in UInt8(0x41)...UInt8(0x5A) {
            let upperCh = String(UnicodeScalar(upperCode))
            let lowerCode = Int(upperCode + 0x20)
            XCTAssertEqual(
                enc.encode(chars: upperCh, modifiers: [.shift], mode: mode),
                csiU(lowerCode, mod: 2),
                "Shift+\(upperCh) under flag 8 must use lowercase base + shift mod"
            )
        }
    }

    // MARK: - Flag 16 (reportAssociatedText) — multi-scalar text

    /// **TST-S3 gap (focus areas / Kitty flag 16) +
    /// TST-S3-001 [medium] (Flag 16 with multi-codepoint IME output):**
    /// flag 16's text section emits `;<utf32>` per scalar. Existing
    /// tests are single-scalar. Pin the multi-scalar shape so a
    /// refactor that emits only the first scalar (silently dropping
    /// the rest of the composition) is caught.
    ///
    /// "é" decomposed as 'e' (U+0065) + combining acute (U+0301)
    /// is a realistic IME deliverable.
    func test_flag16_multiScalar_emitsAllScalars() {
        let enc = KeyEncoder()
        let mode: BBTermMode = [.reportAllKeysAsEsc, .reportAssociatedText]
        // Plain (no shift): chars = "e\u{0301}", modifiers empty.
        // Base codepoint is the first scalar 'e' = 101. Text section
        // must include both scalars.
        let composed = "e\u{0301}"
        let out = enc.encode(chars: composed, modifiers: [], mode: mode)
        // The exact wire format under "text != base" is
        // `ESC [ <base> ; <mod> ; <text-scalars-joined> u`.
        // For a non-elided multi-scalar text, the joiner is `:`
        // per the Kitty spec ("text codepoints are colon-separated"),
        // but Blackbird's existing single-scalar test
        // `test_flag16_reportAssociatedText_shiftLetterEmitsText`
        // showed the form `ESC[97;2;65u` (semicolon before text).
        // We don't know which separator the implementation uses for
        // multi-scalar text, so the assertion is structural: the
        // output must (a) start with `ESC[101;1` (base + mod), and
        // (b) include both `101` and `769` (decimal of U+0301)
        // somewhere — neither scalar may be silently dropped.
        let bytes = Array(out)

        // Must start with ESC [ 101 ; (i.e. base = 101, mod = 1).
        let expectedPrefix: [UInt8] = [0x1B, 0x5B] + Array("101;1".utf8)
        XCTAssertTrue(bytes.starts(with: expectedPrefix),
                      "flag 16 multi-scalar must lead with `ESC[101;1` (base + mod), got \(bytes)")

        // Must include the second scalar's decimal (U+0301 = 769).
        let secondScalar = Array("769".utf8)
        XCTAssertTrue(byteSliceContains(bytes, secondScalar),
                      "flag 16 multi-scalar must include second scalar (769) in text section, got \(bytes)")
    }

    /// Flag 16 elision: when the produced text matches the base
    /// codepoint, the text section MUST be elided (parser-side
    /// optimisation per spec). Existing
    /// `test_flag16_reportAssociatedText_plainLetterElidesText`
    /// pins this for plain "a"; we add the symmetric assertion that
    /// the bytes do NOT contain a redundant `;97u` tail.
    func test_flag16_textEqualsBase_isElided() {
        let enc = KeyEncoder()
        let mode: BBTermMode = [.reportAllKeysAsEsc, .reportAssociatedText]
        let out = enc.encode(chars: "a", modifiers: [], mode: mode)
        // Expected: bare ESC[97u. NOT ESC[97;1;97u.
        XCTAssertEqual(out, csiU(97, mod: 1),
                       "Flag 16 must elide the text when text == base")
        // Defensive: assert the output length is exactly 5 (ESC [ 9 7 u),
        // so we'd catch any redundant trailing `;…` payload.
        XCTAssertEqual(out.count, 5,
                       "Bare ESC[97u must be 5 bytes; got \(out.count)")
    }

    // MARK: - Special keys with modifiers

    /// **TST-S3 gap (focus areas / Special keys):** the existing
    /// extended tests cover modified F1-F12 and arrows individually.
    /// Add a sweep that pins ALL specials (F1-F12, arrows, Home, End,
    /// PageUp, PageDown, Insert, Delete) under Shift, with a single
    /// loop, so an inadvertent regression that touched only one
    /// branch fails fast and informatively.
    func test_allSpecials_withShift_haveModifierEncoding() {
        let enc = KeyEncoder()
        // (key, expected Shift output). For arrows / Home/End / F1-F4
        // it's `ESC[1;2<final>`; for F5-F12 / PageUp/Down / Insert /
        // Delete it's `ESC[<num>;2~`.
        let arrowFinal: [(KeyEncoder.SpecialKey, UInt8)] = [
            (.up, 0x41), (.down, 0x42), (.right, 0x43), (.left, 0x44),
            (.home, 0x48), (.end, 0x46),
            (.f1, 0x50), (.f2, 0x51), (.f3, 0x52), (.f4, 0x53),
        ]
        for (key, final) in arrowFinal {
            let expected = Data([0x1B, 0x5B, 0x31, 0x3B, 0x32, final]) // ESC [ 1 ; 2 <final>
            XCTAssertEqual(enc.encodeSpecial(key, modifiers: [.shift]), expected,
                           "Shift+\(key) must be ESC[1;2\(String(UnicodeScalar(final)))")
        }

        let tildeNum: [(KeyEncoder.SpecialKey, String)] = [
            (.insert, "2"), (.delete, "3"),
            (.pageUp, "5"), (.pageDown, "6"),
            (.f5, "15"), (.f6, "17"), (.f7, "18"), (.f8, "19"),
            (.f9, "20"), (.f10, "21"), (.f11, "23"), (.f12, "24"),
        ]
        for (key, num) in tildeNum {
            var bytes: [UInt8] = [0x1B, 0x5B]
            bytes.append(contentsOf: Array(num.utf8))
            bytes.append(contentsOf: Array(";2".utf8))
            bytes.append(0x7E)
            XCTAssertEqual(enc.encodeSpecial(key, modifiers: [.shift]), Data(bytes),
                           "Shift+\(key) must be ESC[\(num);2~")
        }
    }

    /// **TST-S3 gap (focus areas / Special keys):** `Esc with mod`.
    /// Plain Esc is 0x1B; Shift+Esc under Kitty flag 1 must take the
    /// CSI u path, not the ESC-Meta-prefix path that would produce
    /// `ESC ESC` (double ESC, which nvim treats as abort).
    func test_escWithMod_kittyFlag1_takesCsiU() {
        let enc = KeyEncoder()
        // Shift+Esc: ESC[27;2u
        XCTAssertEqual(enc.encode(chars: "\u{1B}", modifiers: [.shift], mode: [.disambiguateEscCodes]),
                       csiU(27, mod: 2))
        // Ctrl+Esc: ESC[27;5u
        XCTAssertEqual(enc.encode(chars: "\u{1B}", modifiers: [.control], mode: [.disambiguateEscCodes]),
                       csiU(27, mod: 5))
    }

    /// Esc with mod under modifyOtherKeys: should take the CSI 27 path.
    func test_escWithMod_modifyOtherKeys_takesCsi27() {
        let enc = KeyEncoder()
        XCTAssertEqual(
            enc.encode(chars: "\u{1B}", modifiers: [.shift], mode: [.modifyOtherKeys]),
            csi27(mod: 2, cp: 27)
        )
    }

    // MARK: - Modifier param arithmetic — adversarial corners

    /// `.command` is suppressed at the encode boundary. Cover the
    /// special-key path too (encodeSpecial doesn't suppress, it
    /// just doesn't add a Cmd bit).
    func test_modifierParam_specialKey_commandIgnored() {
        let enc = KeyEncoder()
        // `encodeSpecial(.up, modifiers: [.command])` → mod=1
        // collapses to plain ESC[A.
        XCTAssertEqual(enc.encodeSpecial(.up, modifiers: [.command]),
                       Data([0x1B, 0x5B, 0x41]),
                       "encodeSpecial must ignore .command bit (collapse to mod=1)")
        // `encodeSpecial(.up, modifiers: [.command, .shift])` →
        // mod=2 (only shift contributes).
        XCTAssertEqual(enc.encodeSpecial(.up, modifiers: [.command, .shift]),
                       Data([0x1B, 0x5B, 0x31, 0x3B, 0x32, 0x41]),
                       "encodeSpecial must let shift through ⌘ to produce mod=2")
    }

    // MARK: - Releases never escape outside flag 2

    /// **TST-S3 gap (focus areas / Release events):** non-press
    /// events must NEVER escape the legacy or modifyOtherKeys modes.
    /// Sweep every event-type (release, repeat) over both legacy and
    /// modifyOtherKeys modes, with several keys, and assert empty Data.
    func test_releasesNeverEscapeLegacyOrMok() {
        let enc = KeyEncoder()
        let modes: [BBTermMode] = [
            [],                       // legacy
            [.modifyOtherKeys],       // xterm
            [.disambiguateEscCodes],  // kitty flag 1 only (no flag 2)
            [.reportAllKeysAsEsc],    // kitty flag 8 only (no flag 2)
            [.reportAlternateKeys],   // kitty flag 4 only (no flag 2)
        ]
        let chars = ["a", "Z", "1", "\r", "\t", "\u{1B}", "\u{7F}", "."]
        let mods: [KeyEncoder.Modifiers] = [
            [], [.shift], [.control], [.option], [.shift, .control],
        ]
        // Both .release and .repeat must drop in non-flag-2 modes.
        let nonPress: [KeyEncoder.EventType] = [.release, .repeat]

        for mode in modes {
            for ch in chars {
                for mod in mods {
                    for evt in nonPress {
                        let out = enc.encode(chars: ch, modifiers: mod, mode: mode, eventType: evt)
                        XCTAssertEqual(
                            out, Data(),
                            """
                            Non-press event escaped outside flag 2:
                              chars=\(Array(ch.utf8)) mods=\(mod) mode=\(mode.rawValue) evt=\(evt)
                              out=\(Array(out))
                            """
                        )
                    }
                }
            }
        }
    }

    /// .repeat under Kitty flag 2 SHOULD emit (event-type = 2);
    /// pin it to differentiate from the negative case above.
    func test_repeatUnderFlag2_emitsCsiU() {
        let enc = KeyEncoder()
        let mode: BBTermMode = [.disambiguateEscCodes, .reportEventTypes]
        let out = enc.encode(chars: "\r", modifiers: [.shift], mode: mode, eventType: .repeat)
        XCTAssertEqual(out, Data("\u{1B}[13;2:2u".utf8),
                       "Repeat under flag 2 must emit `:2` event-type suffix")
    }

    // MARK: - modifyOtherKeys regression: ⌘ suppression

    /// `.command + modifyOtherKeys` must produce empty Data —
    /// suppression at the encode boundary applies regardless of mode.
    func test_modifyOtherKeys_commandIsSuppressed() {
        let enc = KeyEncoder()
        XCTAssertEqual(
            enc.encode(chars: ".", modifiers: [.command, .control], mode: [.modifyOtherKeys]),
            Data(),
            "⌘+ctrl+. must produce empty Data even with modifyOtherKeys lit"
        )
    }

    /// xterm CSI 27 carries exactly one codepoint per sequence, so
    /// multi-scalar input (decomposed `e` + U+0301 from IME, Vietnamese
    /// Telex composition, etc.) cannot be encoded that way without
    /// silently dropping the trailing scalars. The encoder must fall
    /// back to plain UTF-8 emission — same as the legacy fallback at
    /// the bottom of `encode` — so tmux/Emacs/nvim with
    /// `extended-keys on` see the full composed text.
    func test_multiScalar_modifyOtherKeys_fallsBackToUtf8() {
        let enc = KeyEncoder()
        let composed = "e\u{0301}"  // decomposed é
        let out = enc.encode(
            chars: composed,
            modifiers: [.shift],
            mode: [.modifyOtherKeys]
        )
        XCTAssertEqual(out, Data(composed.utf8),
                       "Multi-scalar modifyOtherKeys input must fall back to UTF-8")
        // Negative: the output must NOT be a CSI 27 sequence (which
        // would imply only the first scalar survived).
        let csi27Prefix: [UInt8] = [0x1B, 0x5B] + Array("27;".utf8)
        XCTAssertFalse(Array(out).starts(with: csi27Prefix),
                       "Multi-scalar modifyOtherKeys must NOT emit a CSI 27 sequence")
    }

    // MARK: - Helpers

    /// Returns true if `haystack` contains `needle` as a contiguous
    /// byte subsequence. Tiny utility for the flag-16 multi-scalar
    /// "must contain" assertion, which can't trivially express
    /// "the bytes 7-6-9 appear somewhere" via existing Data API.
    private func byteSliceContains(_ haystack: [UInt8], _ needle: [UInt8]) -> Bool {
        guard !needle.isEmpty, haystack.count >= needle.count else { return false }
        for start in 0...(haystack.count - needle.count) {
            if Array(haystack[start..<start + needle.count]) == needle {
                return true
            }
        }
        return false
    }
}
