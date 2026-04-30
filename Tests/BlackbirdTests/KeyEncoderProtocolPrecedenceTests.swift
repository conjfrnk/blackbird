import XCTest
@testable import Blackbird
@testable import BBCore

/// **Compat-matrix pin:** this file backs the Kitty / mOK / legacy precedence
/// row in `docs/compat-matrix.md`. `git grep "compat-matrix.md"` resolves to
/// every test that gates a row in that doc.
///
/// Pins the deterministic precedence rules between Blackbird's three
/// keyboard-encoding paths:
///
///   1. **Kitty CSI u** (any of `disambiguateEscCodes`, `reportEventTypes`,
///      `reportAlternateKeys`, `reportAllKeysAsEsc`, `reportAssociatedText`).
///   2. **xterm modifyOtherKeys** (`CSI 27 ; <mod> ; <cp> ~`).
///   3. **Legacy** (printable bytes, ESC-Meta, controlByte mapping).
///
/// The contract — implied by the spec and pinned by the existing
/// `KittyKeyboardProtocolTests.test_modifyOtherKeys_kittyPrecedence_kittyWins`
/// — is:
///
///   * If **any** Kitty flag is set, modifyOtherKeys is suppressed entirely.
///   * If only modifyOtherKeys is set, modified printable keys take the
///     `CSI 27 ; mod ; cp ~` path.
///   * If neither is set, all keys take the legacy path.
///
/// The reason precedence matters: every TUI that asks for kitty
/// (Claude Code, nvim 0.10+, Helix, Zellij) also asks for modifyOtherKeys
/// in case the terminal doesn't speak kitty. The terminal must pick one
/// and stick with it deterministically — emitting both, or the wrong
/// one, produces double-key events the TUI can't reconcile.
///
/// Pre-flight memory cost: each test allocates one `KeyEncoder` (no
/// heap state) and a few short `Data` values (< 32 bytes each). 100-
/// iteration property test allocates ~3 KiB total. Safe under the
/// 256 MiB budget without an explicit `requireTestFitsInBudget` call.
final class KeyEncoderProtocolPrecedenceTests: XCTestCase {

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

    /// Every flag that should activate the Kitty CSI-u branch. Listed
    /// individually so a regression that drops one (e.g. the
    /// `kittyAnyActive` mask narrowing) fails the right test.
    private static let kittyFlagCases: [(name: String, mode: BBTermMode)] = [
        ("disambiguateEscCodes",  [.disambiguateEscCodes]),
        ("reportEventTypes",      [.reportEventTypes]),
        ("reportAlternateKeys",   [.reportAlternateKeys]),
        ("reportAllKeysAsEsc",    [.reportAllKeysAsEsc]),
        ("reportAssociatedText",  [.reportAssociatedText]),
    ]

    // MARK: - 1. Kitty-flag suppression of modifyOtherKeys (per-flag)

    /// For *every* Kitty flag in isolation: when paired with
    /// modifyOtherKeys, the encoder must NOT emit the `CSI 27 ; mod ; cp ~`
    /// shape. The output must either be the Kitty CSI-u shape or the
    /// legacy shape — never modifyOtherKeys.
    ///
    /// Pin all five flag bits independently so a refactor that derives
    /// `kittyAnyActive` from a too-narrow mask (e.g. only flag 1) is
    /// caught at this surface, not at integration-test time.
    func test_eachKittyFlag_suppressesModifyOtherKeys_onShiftEnter() {
        let enc = KeyEncoder()
        for (name, kittyFlag) in Self.kittyFlagCases {
            let combined: BBTermMode = kittyFlag.union([.modifyOtherKeys])
            let out = enc.encode(chars: "\r", modifiers: [.shift], mode: combined)

            // Negative assertion: must not be the modifyOtherKeys shape.
            // We use the actual byte string `[27;` to detect the
            // `CSI 27 ;` prefix — that prefix is unique to modifyOtherKeys.
            XCTAssertFalse(
                out.starts(with: Data("\u{1B}[27;".utf8)),
                "Kitty flag \(name) must suppress modifyOtherKeys; got bytes \(Array(out))"
            )

            // Positive assertion is per-flag because each flag has its
            // own legal output for Shift+Enter:
            //   - flag 1:                            ESC[13;2u
            //   - flag 2 alone (no flag 1):          ESC[27;2;13~ would be
            //     wrong; spec says flag 2 only emits CSI-u for keys that
            //     would *also* take the CSI-u path under flag 1, so plain
            //     Shift+Enter under flag 2 alone falls through to legacy CR.
            //   - flags 4/8/16 alone behaviours are similarly nuanced.
            //
            // Rather than re-spec every cell, we only assert the
            // suppression invariant here.
            switch name {
            case "disambiguateEscCodes":
                XCTAssertEqual(out, csiU(13, mod: 2),
                               "Flag 1 must take Kitty path → ESC[13;2u")
            default:
                // Other flags in isolation may legitimately fall through
                // to legacy `\r`. The only thing the precedence test
                // pins is "not modifyOtherKeys."
                break
            }
        }
    }

    /// Symmetric check on a *modifier-only* control key (Ctrl+.) — a
    /// canonical modifyOtherKeys-only key (no legacy byte exists for it,
    /// so a regression that fell through to legacy would emit a stray '.'
    /// or empty Data, both diagnosable).
    func test_eachKittyFlag_plusModifyOtherKeys_ctrlDot_doesNotUseCsi27() {
        let enc = KeyEncoder()
        for (name, kittyFlag) in Self.kittyFlagCases {
            let combined: BBTermMode = kittyFlag.union([.modifyOtherKeys])
            let out = enc.encode(chars: ".", modifiers: [.control], mode: combined)
            XCTAssertFalse(
                out.starts(with: Data("\u{1B}[27;".utf8)),
                "Flag \(name) must suppress modifyOtherKeys for Ctrl+. ; got \(Array(out))"
            )
        }
    }

    // MARK: - 2. modifyOtherKeys alone — both levels light the bit

    /// The Rust core's `modify_other_keys` parser accepts both
    /// `CSI > 4 ; 1 m` (level 1, modify only "C-,", "C-." style keys)
    /// and `CSI > 4 ; 2 m` (level 2, modify essentially every modified
    /// key). The Swift mode bitfield does NOT distinguish levels — we
    /// surface a single boolean `BBTermMode.modifyOtherKeys`. Pin that
    /// the encoder treats both the same way (the level distinction is
    /// the parser's job; the encoder sees one bit).
    ///
    /// The end-to-end round trip exercises the parser → snapshot →
    /// encoder chain. Both `level=1` and `level=2` enable bytes must
    /// land the bit, and the encoder must emit identical CSI 27 traffic
    /// for an identical key.
    func test_modifyOtherKeysLevel1_andLevel2_produceSameEncoderOutput() throws {
        guard let term1 = BBTerm(size: .init(cols: 80, rows: 24)),
              let term2 = BBTerm(size: .init(cols: 80, rows: 24)) else {
            XCTFail("BBTerm init"); return
        }
        // Level 1 enable.
        term1.input("\u{1B}[>4;1m")
        // Level 2 enable.
        term2.input("\u{1B}[>4;2m")

        guard let snap1 = term1.snapshot(),
              let snap2 = term2.snapshot() else {
            XCTFail("snapshot"); return
        }
        XCTAssertTrue(snap1.termMode.contains(.modifyOtherKeys),
                      "Level 1 enable must light .modifyOtherKeys bit")
        XCTAssertTrue(snap2.termMode.contains(.modifyOtherKeys),
                      "Level 2 enable must light .modifyOtherKeys bit")

        let enc = KeyEncoder()
        let outLvl1 = enc.encode(chars: ".", modifiers: [.control], mode: snap1.termMode)
        let outLvl2 = enc.encode(chars: ".", modifiers: [.control], mode: snap2.termMode)
        XCTAssertEqual(outLvl1, csi27(mod: 5, cp: 46),
                       "Level 1 must produce CSI 27 ; 5 ; 46 ~ for Ctrl+.")
        XCTAssertEqual(outLvl1, outLvl2,
                       "Encoder must not distinguish modifyOtherKeys levels")
    }

    // MARK: - 3. Three precedence axes (Kitty / modifyOtherKeys / neither)

    /// Truth table: for a single key (Ctrl+.), exhaust the four
    /// combinations of {Kitty on/off} × {modifyOtherKeys on/off} and
    /// pin each output. Catches a regression that swaps the two paths
    /// or accidentally drops one when both bits flip simultaneously.
    func test_precedenceTruthTable_ctrlDot() {
        let enc = KeyEncoder()
        let kitty: BBTermMode = [.disambiguateEscCodes]
        let mok:   BBTermMode = [.modifyOtherKeys]

        // Both off → legacy path. Ctrl+. has no controlByte mapping,
        // so the encoder falls through to plain '.' (existing
        // KeyEncoderTests pins this).
        XCTAssertEqual(
            enc.encode(chars: ".", modifiers: [.control], mode: []),
            Data([0x2E]),
            "Both protocols off → legacy plain '.' for Ctrl+."
        )

        // Only modifyOtherKeys → CSI 27 ; 5 ; 46 ~.
        XCTAssertEqual(
            enc.encode(chars: ".", modifiers: [.control], mode: mok),
            csi27(mod: 5, cp: 46),
            "Only modifyOtherKeys → CSI 27 path"
        )

        // Only kitty disambiguation: documented gap. Per Kitty's spec,
        // ANY modified printable (including Ctrl+., Alt+s, etc.) should
        // emit CSI u under flag 1. Blackbird currently only covers the
        // four C0-aliasing colliders (i/m/h/[) + `?` plus the explicit
        // disambiguation keys (Enter/Esc/Tab/Backspace). Modified
        // printables that don't have a C0 alias fall through to the
        // legacy byte. Tracked as architecture-defer: "flag 1 modified
        // printable → CSI u" is a separate encoder-shape change that
        // would need to coordinate with the TerminalView fast-path and
        // existing legacy callers.
        XCTAssertEqual(
            enc.encode(chars: ".", modifiers: [.control], mode: kitty),
            Data([0x2E]),
            "Flag 1 alone: modified-printable CSI u shaping is deferred; legacy byte for now"
        )

        // Both → kitty wins (suppresses modifyOtherKeys), but same gap
        // as above means the output today is the legacy byte. When the
        // flag-1-modified-printable work lands, this and the single-
        // protocol case both flip to CSI u together.
        XCTAssertEqual(
            enc.encode(chars: ".", modifiers: [.control], mode: kitty.union(mok)),
            Data([0x2E]),
            "Kitty suppresses modifyOtherKeys; legacy shape until flag-1 mod-printable work lands"
        )
    }

    /// Same truth table for a *legacy-mappable* key (Shift+Enter):
    /// confirms the precedence holds even when the legacy path produces
    /// a non-trivial byte (CR, not just the literal char).
    func test_precedenceTruthTable_shiftEnter() {
        let enc = KeyEncoder()
        let kitty: BBTermMode = [.disambiguateEscCodes]
        let mok:   BBTermMode = [.modifyOtherKeys]

        // Both off → legacy: Shift+Enter collapses to plain CR (Cocoa
        // delivers '\r' as chars; the encoder's printable path emits the
        // single byte).
        XCTAssertEqual(
            enc.encode(chars: "\r", modifiers: [.shift], mode: []),
            Data([0x0D]),
            "Both protocols off → legacy CR for Shift+Enter"
        )
        // Only modifyOtherKeys → CSI 27 ; 2 ; 13 ~.
        XCTAssertEqual(
            enc.encode(chars: "\r", modifiers: [.shift], mode: mok),
            csi27(mod: 2, cp: 13),
            "Only modifyOtherKeys → CSI 27 path"
        )
        // Only kitty → CSI 13 ; 2 u.
        XCTAssertEqual(
            enc.encode(chars: "\r", modifiers: [.shift], mode: kitty),
            csiU(13, mod: 2),
            "Only kitty → CSI u path"
        )
        // Both → kitty wins.
        XCTAssertEqual(
            enc.encode(chars: "\r", modifiers: [.shift], mode: kitty.union(mok)),
            csiU(13, mod: 2),
            "Both protocols on → kitty wins"
        )
    }

    // MARK: - 4. Property test: legacy invariant under flag noise

    /// **Property:** for a key+modifier pair where neither protocol
    /// is active, the output must be a pure function of `(chars,
    /// modifiers)` — no other mode bit may leak into the output.
    ///
    /// This catches a regression where some non-keyboard mode bit
    /// (altScreen, bracketedPaste, mouseDrag, etc.) accidentally
    /// branched the encoder. We exhaustively flip every non-Kitty
    /// non-modifyOtherKeys bit in the mode bitfield and assert the
    /// output equals the bit-empty-mode output.
    ///
    /// 100 iterations: keys drawn from a small alphabet × a randomised
    /// modifier set × a random *non-keyboard* mode sample. Total
    /// allocation budget: ~6 KiB.
    func test_property_legacyOutputIndependentOfNonKeyboardModeBits() {
        let enc = KeyEncoder()

        // Non-keyboard mode bits — every BBTermMode flag that is NOT
        // a kitty flag and NOT modifyOtherKeys.
        let nonKeyboardBits: [BBTermMode] = [
            .altScreen, .appCursor, .appKeypad, .bracketedPaste,
            .mouseReportClick, .mouseMotion, .mouseDrag, .sgrMouse,
            .focusInOut, .showCursor, .lineWrap,
        ]
        let chars: [String] = ["a", "Z", "1", ".", "?", "\r", "\t", "\u{1B}",
                               "\u{7F}", " ", "@", "_", "<", "/"]
        let modCombos: [KeyEncoder.Modifiers] = [
            [], [.shift], [.option], [.control], [.shift, .option],
            [.shift, .control], [.option, .control],
            [.shift, .option, .control],
        ]

        var rng = SystemRandomNumberGenerator()
        for i in 0..<100 {
            let ch = chars[Int.random(in: 0..<chars.count, using: &rng)]
            let mods = modCombos[Int.random(in: 0..<modCombos.count, using: &rng)]

            // Construct a random non-keyboard mode bitfield.
            var noise: BBTermMode = []
            for bit in nonKeyboardBits where Bool.random(using: &rng) {
                noise.formUnion(bit)
            }

            // Reference output with mode = empty.
            let ref = enc.encode(chars: ch, modifiers: mods, mode: [])
            // Output with random non-keyboard mode noise.
            let actual = enc.encode(chars: ch, modifiers: mods, mode: noise)

            XCTAssertEqual(
                ref, actual,
                """
                Iteration \(i): non-keyboard mode bits leaked into encoding.
                  chars=\(ch.unicodeScalars.map { $0.value })
                  mods=\(mods)
                  noise=\(noise.rawValue)
                  ref=\(Array(ref))
                  actual=\(Array(actual))
                """
            )
        }
    }

    // MARK: - 5. Modifier param arithmetic (1 + bits)

    /// xterm + Kitty share the modifier-param arithmetic:
    ///   shift = 1, alt = 2, ctrl = 4, super = 8, …
    ///   final param = 1 + sum(bits).
    /// Pin every single-bit and every two-bit combo + one three-bit.
    /// Cocoa's `.command` is suppressed at the encode boundary, so it
    /// never participates in modifier arithmetic.
    func test_modifierParam_singleBits() {
        let enc = KeyEncoder()
        // Use Shift+Enter / Ctrl+Enter / Alt+Enter under Kitty flag 1
        // — `\r` keeps the test focused on modifier math, not on which
        // codepoint reaches the wire.
        XCTAssertEqual(enc.encode(chars: "\r", modifiers: [.shift], mode: [.disambiguateEscCodes]),
                       csiU(13, mod: 2), "shift → 1+1=2")
        XCTAssertEqual(enc.encode(chars: "\r", modifiers: [.option], mode: [.disambiguateEscCodes]),
                       csiU(13, mod: 3), "alt → 1+2=3")
        XCTAssertEqual(enc.encode(chars: "\r", modifiers: [.control], mode: [.disambiguateEscCodes]),
                       csiU(13, mod: 5), "ctrl → 1+4=5")
    }

    func test_modifierParam_twoBits() {
        let enc = KeyEncoder()
        let kitty: BBTermMode = [.disambiguateEscCodes]
        // shift+alt = 1+1+2 = 4
        XCTAssertEqual(enc.encode(chars: "\r", modifiers: [.shift, .option], mode: kitty),
                       csiU(13, mod: 4), "shift+alt → 4")
        // shift+ctrl = 1+1+4 = 6
        XCTAssertEqual(enc.encode(chars: "\r", modifiers: [.shift, .control], mode: kitty),
                       csiU(13, mod: 6), "shift+ctrl → 6")
        // alt+ctrl = 1+2+4 = 7
        XCTAssertEqual(enc.encode(chars: "\r", modifiers: [.option, .control], mode: kitty),
                       csiU(13, mod: 7), "alt+ctrl → 7")
    }

    func test_modifierParam_threeBits() {
        let enc = KeyEncoder()
        // shift+alt+ctrl = 1+1+2+4 = 8 (the highest legal xterm mod).
        XCTAssertEqual(
            enc.encode(chars: "\r", modifiers: [.shift, .option, .control], mode: [.disambiguateEscCodes]),
            csiU(13, mod: 8),
            "shift+alt+ctrl → 8"
        )
        // Same arithmetic via modifyOtherKeys path.
        XCTAssertEqual(
            enc.encode(chars: ".", modifiers: [.shift, .option, .control], mode: [.modifyOtherKeys]),
            csi27(mod: 8, cp: 46),
            "shift+alt+ctrl via modifyOtherKeys → mod=8"
        )
    }

    /// `.command` must not contribute to the modifier param. Even when
    /// the encoder receives [.command, .shift], the resulting CSI u
    /// must show modifier=2 (shift only) — except the encoder
    /// suppresses ⌘ at the encode boundary entirely, so the actual
    /// observed output is empty Data.
    func test_modifierParam_commandIsSuppressed_notSummed() {
        let enc = KeyEncoder()
        // Even though shift would produce mod=2 alone, ⌘+shift is
        // suppressed at the encode() boundary.
        XCTAssertEqual(
            enc.encode(chars: "\r", modifiers: [.command, .shift], mode: [.disambiguateEscCodes]),
            Data(),
            "⌘+shift+Enter must produce empty Data, never CSI u with mod that includes a Cmd bit"
        )
        XCTAssertEqual(
            enc.encode(chars: ".", modifiers: [.command, .control], mode: [.modifyOtherKeys]),
            Data(),
            "⌘+ctrl+. must produce empty Data, never CSI 27 ; * ; 46 ~"
        )
    }

    // MARK: - 6. Release events outside Kitty flag 2

    /// Releases are a Kitty-flag-2-only feature. In legacy mode, in
    /// modifyOtherKeys mode, and even in Kitty-without-flag-2 mode,
    /// release events must produce nothing — propagating them would
    /// double every keystroke from the TUI's perspective.
    func test_release_legacyMode_emitsNothing() {
        let enc = KeyEncoder()
        XCTAssertEqual(
            enc.encode(chars: "a", modifiers: [], mode: [], eventType: .release),
            Data(),
            "Release in legacy mode must produce nothing"
        )
        XCTAssertEqual(
            enc.encode(chars: "\r", modifiers: [.shift], mode: [], eventType: .release),
            Data(),
            "Release of Shift+Enter in legacy mode must produce nothing"
        )
    }

    func test_release_modifyOtherKeysMode_emitsNothing() {
        let enc = KeyEncoder()
        XCTAssertEqual(
            enc.encode(chars: ".", modifiers: [.control], mode: [.modifyOtherKeys], eventType: .release),
            Data(),
            "Release in modifyOtherKeys mode must produce nothing"
        )
    }

    func test_release_kittyWithoutFlag2_emitsNothing() {
        let enc = KeyEncoder()
        // Kitty flag 1 only — no event-type reporting.
        XCTAssertEqual(
            enc.encode(chars: "\r", modifiers: [.shift], mode: [.disambiguateEscCodes], eventType: .release),
            Data(),
            "Release with kitty flag 1 alone (no flag 2) must produce nothing"
        )
        // Kitty flag 4 alone (no flag 2).
        XCTAssertEqual(
            enc.encode(chars: "A", modifiers: [.shift], mode: [.reportAlternateKeys], eventType: .release),
            Data(),
            "Release with kitty flag 4 alone (no flag 2) must produce nothing"
        )
    }

    // MARK: - 7. Multi-scalar input

    /// IME and pasted strings can deliver multi-scalar `chars`.
    /// Astral-plane emoji (e.g. 🌎 = U+1F30E, encoded as a UTF-16
    /// surrogate pair but a single Unicode scalar) and multi-scalar
    /// strings (e.g. ZWJ family emoji) are common.
    ///
    /// In legacy mode + no modifiers, the encoder's contract is to
    /// emit the UTF-8 bytes of the string verbatim. Pinning this
    /// guards against a regression that truncated to the first byte
    /// or applied controlByte mapping to multi-byte scalars.
    func test_multiScalar_astralEmoji_passesThroughUTF8() {
        let enc = KeyEncoder()
        // 🌎 (U+1F30E) — single scalar, four UTF-8 bytes.
        let earth = "🌎"
        XCTAssertEqual(
            enc.encode(chars: earth, modifiers: [], mode: []),
            Data(earth.utf8),
            "Astral-plane emoji must pass through as raw UTF-8"
        )
    }

    func test_multiScalar_zwjFamily_passesThroughUTF8() {
        let enc = KeyEncoder()
        // 👨‍👩‍👧 — Man + ZWJ + Woman + ZWJ + Girl. Five scalars,
        // 17 UTF-8 bytes. AppKit IME can hand this through `insertText`
        // verbatim.
        let family = "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}"
        XCTAssertEqual(
            enc.encode(chars: family, modifiers: [], mode: []),
            Data(family.utf8),
            "ZWJ family emoji must pass through as raw UTF-8"
        )
    }

    func test_multiScalar_combiningAccent_passesThrough() {
        let enc = KeyEncoder()
        // "é" decomposed: 'e' + combining acute (U+0301).
        let composed = "e\u{0301}"
        XCTAssertEqual(
            enc.encode(chars: composed, modifiers: [], mode: []),
            Data(composed.utf8),
            "Combining-character sequence must pass through as raw UTF-8"
        )
    }

    /// Multi-scalar + Option-as-Meta: the legacy path prepends ESC and
    /// then emits the full string. A regression that prepended ESC to
    /// only the first scalar (truncating the rest) would silently
    /// corrupt IME composition reaching the shell.
    func test_multiScalar_metaPrefix_appliesToFullString() {
        let enc = KeyEncoder(optionIsMeta: true)
        let s = "🌎"
        XCTAssertEqual(
            enc.encode(chars: s, modifiers: [.option], mode: []),
            Data([0x1B] + Array(s.utf8)),
            "Meta-prefix must precede the full UTF-8 byte sequence"
        )
    }

    // MARK: - 8. Empty-string + modifier interactions

    /// AppKit can deliver empty `chars` with modifiers (e.g. a dead
    /// key being composed). The legacy path returns empty Data; the
    /// Kitty / modifyOtherKeys paths must NOT invent a codepoint to
    /// emit.
    func test_emptyChars_withModifier_neverInventsCodepoint() {
        let enc = KeyEncoder()
        // Legacy.
        XCTAssertEqual(enc.encode(chars: "", modifiers: [.shift], mode: []), Data())
        // Kitty.
        XCTAssertEqual(enc.encode(chars: "", modifiers: [.shift], mode: [.disambiguateEscCodes]), Data())
        // modifyOtherKeys.
        XCTAssertEqual(enc.encode(chars: "", modifiers: [.control], mode: [.modifyOtherKeys]), Data())
        // Even Kitty flag 8 (which catches ALL keys) must not emit on
        // an empty chars input — there is no key to encode.
        XCTAssertEqual(enc.encode(chars: "", modifiers: [], mode: [.reportAllKeysAsEsc]), Data())
    }

    // MARK: - 9. End-to-end: ESC[>4;1m and ESC[>4;2m both light the bit

    /// Direct round-trip: feed each modifyOtherKeys enable byte into a
    /// real BBTerm and assert `BBTermMode.modifyOtherKeys` lights.
    /// This guards the parser side; the previous test
    /// (`test_modifyOtherKeysLevel1_andLevel2_produceSameEncoderOutput`)
    /// asserts the encoder side.
    func test_endToEnd_level1_lightsBit() {
        guard let term = BBTerm(size: .init(cols: 80, rows: 24)) else {
            XCTFail("BBTerm init"); return
        }
        term.input("\u{1B}[>4;1m")
        guard let snap = term.snapshot() else {
            XCTFail("snapshot"); return
        }
        XCTAssertTrue(snap.termMode.contains(.modifyOtherKeys),
                      "ESC[>4;1m must light .modifyOtherKeys")
    }

    func test_endToEnd_level2_lightsBit() {
        guard let term = BBTerm(size: .init(cols: 80, rows: 24)) else {
            XCTFail("BBTerm init"); return
        }
        term.input("\u{1B}[>4;2m")
        guard let snap = term.snapshot() else {
            XCTFail("snapshot"); return
        }
        XCTAssertTrue(snap.termMode.contains(.modifyOtherKeys),
                      "ESC[>4;2m must light .modifyOtherKeys")
    }

    /// Reset (`CSI > 4 ; 0 m`) must clear the bit. Symmetric with the
    /// enable test; documented in the Rust core's parser.
    func test_endToEnd_level0_clearsBit() {
        guard let term = BBTerm(size: .init(cols: 80, rows: 24)) else {
            XCTFail("BBTerm init"); return
        }
        term.input("\u{1B}[>4;2m")          // enable level 2
        term.input("\u{1B}[>4;0m")          // disable
        guard let snap = term.snapshot() else {
            XCTFail("snapshot"); return
        }
        XCTAssertFalse(snap.termMode.contains(.modifyOtherKeys),
                       "ESC[>4;0m must clear .modifyOtherKeys")
    }
}
