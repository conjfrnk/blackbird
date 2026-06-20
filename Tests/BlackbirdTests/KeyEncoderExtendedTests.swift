import XCTest
@testable import Blackbird
@testable import BBCore

/// Extended coverage for `KeyEncoder` — focuses on CSI u modifier encoding
/// and modified special-key sequences. Kept separate from
/// `KeyEncoderTests.swift` so existing assertions are not duplicated.
///
/// Every assertion in this file pins a *deterministic* encoder output.
/// Historically two tests used `XCTSkip` as a silent-pass escape hatch when
/// the auditor couldn't predict the branch — both have been rewritten to
/// assert the single byte sequence the encoder actually produces today
/// (audit swift-tests-input F5).
final class KeyEncoderExtendedTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        TestHostTermination.shared.register()
    }

    // MARK: - Helpers

    /// ESC `[ 1 ; <param> <letter>` CSI sequence bytes.
    private func csiOne(param: UInt8, letter: UInt8) -> Data {
        // Render `param` as its decimal ASCII representation (handles two
        // digits like "10" for Shift+Alt+Ctrl).
        let paramAscii = Array(String(param).utf8)
        var bytes: [UInt8] = [0x1B, 0x5B, 0x31, 0x3B]    // ESC [ 1 ;
        bytes.append(contentsOf: paramAscii)
        bytes.append(letter)                              // A / B / C / D
        return Data(bytes)
    }

    // MARK: - 1. Shift+printable doesn't produce CSI u

    func test_shiftPrintableIsJustPrintable() {
        let encoder = KeyEncoder()
        // Shift+`,` on a US keyboard is `<` — the OS already delivered the
        // shifted glyph in `chars`, so we must emit a single literal byte,
        // not an `ESC [ 60 ; 2 u` CSI u sequence.
        XCTAssertEqual(encoder.encode(chars: "<", modifiers: [.shift]),
                       Data([0x3C]))
        // Upper-case letter: already covered by existing `test_printableAscii`
        // for `Z`. Try a different letter so we're not duplicating.
        XCTAssertEqual(encoder.encode(chars: "A", modifiers: [.shift]),
                       Data([0x41]))
    }

    // MARK: - 2. Control+Shift+c

    /// Legacy mode: Ctrl+Shift+c must collapse to the classic SIGINT byte
    /// 0x03. The encoder walks the `controlByte(for:)` path as soon as
    /// `.control` is in the modifier set, independent of `.shift`. Pinning
    /// this keeps POSIX SIGINT working regardless of whether the user's
    /// layout happens to produce 'C' or 'c' — AppKit will deliver 'c' as
    /// `chars` when Shift+C is pressed with .shift+.control modifiers.
    ///
    /// The auditor's F5 note flagged this test for `XCTSkip` misuse: the
    /// old version accepted *either* 0x03 *or* the `CSI 99;6u` modifyOtherKeys
    /// form and skipped silently on the latter. The encoder has never
    /// emitted modifyOtherKeys; the skip was dead code masking a regression.
    func test_controlShiftC_isPlainControl() {
        let encoder = KeyEncoder()
        // Legacy mode (no kitty disambiguate bit): Ctrl+Shift+c → 0x03.
        XCTAssertEqual(
            encoder.encode(chars: "c", modifiers: [.control, .shift]),
            Data([0x03]),
            "Ctrl+Shift+c must collapse to classic SIGINT byte 0x03 — not CSI 99;6u"
        )
        // AppKit in practice hands us 'C' (uppercase) with Shift+Ctrl. The
        // controlByte table covers 0x41-0x5A so 'C' also maps to 0x03.
        XCTAssertEqual(
            encoder.encode(chars: "C", modifiers: [.control, .shift]),
            Data([0x03]),
            "Ctrl+Shift+C (uppercase) must also collapse to 0x03"
        )
    }

    // MARK: - 3. Shift + arrows

    func test_shiftArrows_csiOneTwo() {
        let encoder = KeyEncoder()
        // Shift+Up is already covered implicitly nowhere — `KeyEncoderTests`
        // only has unmodified arrows, so all four of these are new.
        XCTAssertEqual(encoder.encodeSpecial(.up,    modifiers: [.shift]),
                       csiOne(param: 2, letter: 0x41))
        XCTAssertEqual(encoder.encodeSpecial(.down,  modifiers: [.shift]),
                       csiOne(param: 2, letter: 0x42))
        XCTAssertEqual(encoder.encodeSpecial(.right, modifiers: [.shift]),
                       csiOne(param: 2, letter: 0x43))
        XCTAssertEqual(encoder.encodeSpecial(.left,  modifiers: [.shift]),
                       csiOne(param: 2, letter: 0x44))
    }

    // MARK: - 4. Control + arrows

    func test_controlArrows_csiOneFive() {
        let encoder = KeyEncoder()
        XCTAssertEqual(encoder.encodeSpecial(.up,    modifiers: [.control]),
                       csiOne(param: 5, letter: 0x41))
        XCTAssertEqual(encoder.encodeSpecial(.down,  modifiers: [.control]),
                       csiOne(param: 5, letter: 0x42))
        XCTAssertEqual(encoder.encodeSpecial(.right, modifiers: [.control]),
                       csiOne(param: 5, letter: 0x43))
        XCTAssertEqual(encoder.encodeSpecial(.left,  modifiers: [.control]),
                       csiOne(param: 5, letter: 0x44))
    }

    // Bonus: verify a multi-modifier combo forms the correct param value.
    // Shift(1) + Alt(2) + Control(4) = 7, +1 base = 8. Contract example.
    func test_shiftAltControlUp_paramEight() {
        let encoder = KeyEncoder()
        XCTAssertEqual(
            encoder.encodeSpecial(.up, modifiers: [.shift, .option, .control]),
            csiOne(param: 8, letter: 0x41)
        )
    }

    // MARK: - 5. F1..F4 unmodified

    func test_f1ThroughF4_ssOSequences() {
        let encoder = KeyEncoder()
        XCTAssertEqual(encoder.encodeSpecial(.f1, modifiers: []),
                       Data([0x1B, 0x4F, 0x50]))    // ESC O P
        XCTAssertEqual(encoder.encodeSpecial(.f2, modifiers: []),
                       Data([0x1B, 0x4F, 0x51]))    // ESC O Q
        XCTAssertEqual(encoder.encodeSpecial(.f3, modifiers: []),
                       Data([0x1B, 0x4F, 0x52]))    // ESC O R
        XCTAssertEqual(encoder.encodeSpecial(.f4, modifiers: []),
                       Data([0x1B, 0x4F, 0x53]))    // ESC O S
    }

    // MARK: - 6. F5 and F12

    func test_f5AndF12_csiTildeForms() {
        let encoder = KeyEncoder()
        // F5 -> ESC [ 1 5 ~
        XCTAssertEqual(encoder.encodeSpecial(.f5, modifiers: []),
                       Data([0x1B, 0x5B, 0x31, 0x35, 0x7E]))
        // F12 -> ESC [ 2 4 ~
        XCTAssertEqual(encoder.encodeSpecial(.f12, modifiers: []),
                       Data([0x1B, 0x5B, 0x32, 0x34, 0x7E]))
    }

    // Bonus: check F6..F11 too — the contract spells them out explicitly.
    func test_f6ThroughF11_csiTildeForms() {
        let encoder = KeyEncoder()
        XCTAssertEqual(encoder.encodeSpecial(.f6,  modifiers: []),
                       Data([0x1B, 0x5B, 0x31, 0x37, 0x7E])) // ESC[17~
        XCTAssertEqual(encoder.encodeSpecial(.f7,  modifiers: []),
                       Data([0x1B, 0x5B, 0x31, 0x38, 0x7E])) // ESC[18~
        XCTAssertEqual(encoder.encodeSpecial(.f8,  modifiers: []),
                       Data([0x1B, 0x5B, 0x31, 0x39, 0x7E])) // ESC[19~
        XCTAssertEqual(encoder.encodeSpecial(.f9,  modifiers: []),
                       Data([0x1B, 0x5B, 0x32, 0x30, 0x7E])) // ESC[20~
        XCTAssertEqual(encoder.encodeSpecial(.f10, modifiers: []),
                       Data([0x1B, 0x5B, 0x32, 0x31, 0x7E])) // ESC[21~
        XCTAssertEqual(encoder.encodeSpecial(.f11, modifiers: []),
                       Data([0x1B, 0x5B, 0x32, 0x33, 0x7E])) // ESC[23~
    }

    // MARK: - 7. Delete + Insert

    func test_deleteAndInsert() {
        let encoder = KeyEncoder()
        // Forward delete: ESC [ 3 ~
        XCTAssertEqual(encoder.encodeSpecial(.delete, modifiers: []),
                       Data([0x1B, 0x5B, 0x33, 0x7E]))
        // Insert: ESC [ 2 ~
        XCTAssertEqual(encoder.encodeSpecial(.insert, modifiers: []),
                       Data([0x1B, 0x5B, 0x32, 0x7E]))
    }

    // MARK: - 8. Home + End

    func test_homeAndEnd_applicationLess() {
        let encoder = KeyEncoder()
        XCTAssertEqual(encoder.encodeSpecial(.home, modifiers: []),
                       Data([0x1B, 0x5B, 0x48]))  // ESC [ H
        XCTAssertEqual(encoder.encodeSpecial(.end, modifiers: []),
                       Data([0x1B, 0x5B, 0x46]))  // ESC [ F
    }

    // MARK: - 9. PageUp / PageDown

    func test_pageUpAndPageDown() {
        let encoder = KeyEncoder()
        XCTAssertEqual(encoder.encodeSpecial(.pageUp, modifiers: []),
                       Data([0x1B, 0x5B, 0x35, 0x7E]))  // ESC [ 5 ~
        XCTAssertEqual(encoder.encodeSpecial(.pageDown, modifiers: []),
                       Data([0x1B, 0x5B, 0x36, 0x7E]))  // ESC [ 6 ~
    }

    // MARK: - 10. Option+arrow and optionIsMeta

    /// Native-Option mode: `encodeSpecial` strips `.option` from the
    /// effective modifier set (see `KeyEncoder.swift:175`) so Option+Up
    /// emits the plain unmodified arrow `ESC[A` — Option is invisible to
    /// the shell in Native mode. This is deterministic: `modBits` collapses
    /// to 1 after the strip, `hasMods` is false, and `applicationCursorKeys`
    /// defaults to false.
    ///
    /// The auditor's F5 note flagged this test for `XCTSkip` misuse: the
    /// old version had an `else if` branch for `ESC[1;3A` that would skip
    /// silently if the encoder ever stopped stripping `.option`. That
    /// regression needs to *fail* CI, not skip it.
    func test_optionArrow_optionIsMetaFalse_passthrough() {
        let encoder = KeyEncoder(optionIsMeta: false)
        XCTAssertEqual(
            encoder.encodeSpecial(.up, modifiers: [.option]),
            Data([0x1B, 0x5B, 0x41]),
            "Native-Option mode must strip .option and emit plain ESC[A"
        )
    }

    func test_optionArrow_optionIsMetaTrue_usesModernCsiModifier() {
        let encoder = KeyEncoder(optionIsMeta: true)
        let result = encoder.encodeSpecial(.up, modifiers: [.option])
        // We chose xterm's modern modifyCursorKeys convention across the
        // encoder: Alt = modifier bit 2, so Alt+Up → ESC [ 1 ; 3 A.
        // Legacy "metafied" encoding (ESC ESC [ A) belongs to older terms
        // and is intentionally not emitted — it round-trips through a
        // double-ESC which some shells treat as a literal Esc key press.
        XCTAssertEqual(result, csiOne(param: 3, letter: 0x41))
    }

    // MARK: - Native Option mode passes macOS-shaped glyphs through verbatim

    func test_optionPrintable_native_sendsChar() {
        let encoder = KeyEncoder(optionIsMeta: false)
        // Option+E → `´` (U+00B4 ACUTE ACCENT) on US layout; Native mode
        // must send those bytes straight through so the shell can paste the
        // accent character in. Meta mode (optionIsMeta=true) would instead
        // prepend ESC to the base letter.
        let result = encoder.encode(chars: "´", modifiers: [.option])
        XCTAssertEqual(result, Data("´".utf8),
                       "Native mode must pass Option-modified glyph verbatim")
    }

    func test_optionPrintable_meta_prependsEsc() {
        let encoder = KeyEncoder(optionIsMeta: true)
        // Caller (TerminalView) in Meta mode supplies charactersIgnoringModifiers
        // (the base key), NOT the Option-modified glyph, and expects ESC-prefix.
        let result = encoder.encode(chars: "e", modifiers: [.option])
        XCTAssertEqual(result, Data([0x1B, 0x65]),
                       "Meta mode must produce ESC+base-char, not the shifted glyph")
    }

    // MARK: - ⌘-prefix events must never produce PTY bytes

    // TerminalView filters ⌘ at the event boundary (⌘C / ⌘V / ⌘T etc. are
    // app-level shortcuts). The encoder is defence-in-depth: if anyone ever
    // calls it with a .command modifier, it returns empty Data so stray
    // app-layer bytes can't leak through as PTY input. Also covers
    // ⌘+arrow-like combinations reaching encodeSpecial implicitly — the
    // printable path is where leaks would typically originate.
    func test_commandPlusPrintable_isSuppressed() {
        let encoder = KeyEncoder()
        XCTAssertEqual(encoder.encode(chars: "a", modifiers: [.command]), Data(),
                       "⌘+printable must never produce shell bytes")
        XCTAssertEqual(encoder.encode(chars: "c", modifiers: [.command]), Data(),
                       "⌘C must not reach the shell as 'c'")
        // Combined modifiers where .command is set also suppress.
        XCTAssertEqual(encoder.encode(chars: "c", modifiers: [.command, .shift]), Data())
        XCTAssertEqual(encoder.encode(chars: "a", modifiers: [.command, .control]), Data(),
                       "⌘ wins over ⌃ — the byte 0x01 must not leak from ⌘⌃A")
    }

    // MARK: - F2. Modifier encoding on non-arrow special keys

    /// Helper for the `CSI <num> ; <modParam> ~` shape used by Page/Delete/Insert
    /// and F5..F12. `num` is supplied as its decimal ASCII string (so "3", "5",
    /// "17", "24", etc.) — this is what the encoder actually writes to the wire.
    private func csiTilde(num: String, mod: UInt8) -> Data {
        var bytes: [UInt8] = [0x1B, 0x5B]
        bytes.append(contentsOf: Array(num.utf8))
        bytes.append(0x3B)                      // ;
        bytes.append(contentsOf: Array(String(mod).utf8))
        bytes.append(0x7E)                      // ~
        return Data(bytes)
    }

    /// Helper for the `CSI 1 ; <modParam> <final>` shape used by arrows,
    /// Home/End, and F1..F4. Different from `csiOne` above only in that the
    /// modParam can be multi-digit and the `final` takes a string literal
    /// for readability (we use .ascii bytes the same way).
    private func csiOneLetter(final: UInt8, mod: UInt8) -> Data {
        var bytes: [UInt8] = [0x1B, 0x5B, 0x31, 0x3B]   // ESC [ 1 ;
        bytes.append(contentsOf: Array(String(mod).utf8))
        bytes.append(final)
        return Data(bytes)
    }

    // F1..F4 — `CSI 1 ; M <final>` (final = P/Q/R/S).

    func test_f1_withModifiers_csiOneForm() {
        let enc = KeyEncoder()
        // F1 + Shift   → ESC[1;2P
        XCTAssertEqual(enc.encodeSpecial(.f1, modifiers: [.shift]),
                       csiOneLetter(final: 0x50, mod: 2))
        // F1 + Control → ESC[1;5P
        XCTAssertEqual(enc.encodeSpecial(.f1, modifiers: [.control]),
                       csiOneLetter(final: 0x50, mod: 5))
        // F1 + Option (optionIsMeta default true) → alt bit set, mod=3
        XCTAssertEqual(enc.encodeSpecial(.f1, modifiers: [.option]),
                       csiOneLetter(final: 0x50, mod: 3))
        // F1 + Command → suppressed at encode() boundary, but encodeSpecial
        // ignores .command entirely (modifierParam never sets a bit for it).
        // Result: mod=1, which collapses to the unmodified SS3 form ESC O P.
        XCTAssertEqual(enc.encodeSpecial(.f1, modifiers: [.command]),
                       Data([0x1B, 0x4F, 0x50]))
    }

    func test_f1ThroughF4_shiftControl_combinedModifier() {
        let enc = KeyEncoder()
        // Shift(1) + Ctrl(4) = 5, +1 base = 6.
        XCTAssertEqual(enc.encodeSpecial(.f1, modifiers: [.shift, .control]),
                       csiOneLetter(final: 0x50, mod: 6))
        XCTAssertEqual(enc.encodeSpecial(.f2, modifiers: [.shift, .control]),
                       csiOneLetter(final: 0x51, mod: 6))
        XCTAssertEqual(enc.encodeSpecial(.f3, modifiers: [.shift, .control]),
                       csiOneLetter(final: 0x52, mod: 6))
        XCTAssertEqual(enc.encodeSpecial(.f4, modifiers: [.shift, .control]),
                       csiOneLetter(final: 0x53, mod: 6))
    }

    func test_f1_allThreeModsCombined_paramEight() {
        let enc = KeyEncoder()
        // Shift(1) + Alt(2) + Ctrl(4) = 7, +1 = 8.
        XCTAssertEqual(
            enc.encodeSpecial(.f1, modifiers: [.shift, .option, .control]),
            csiOneLetter(final: 0x50, mod: 8)
        )
    }

    // F5..F12 — `CSI <code> ; M ~`.

    func test_f5_withModifiers_csiTildeForm() {
        let enc = KeyEncoder()
        XCTAssertEqual(enc.encodeSpecial(.f5, modifiers: [.shift]),
                       csiTilde(num: "15", mod: 2))    // ESC[15;2~
        XCTAssertEqual(enc.encodeSpecial(.f5, modifiers: [.control]),
                       csiTilde(num: "15", mod: 5))    // ESC[15;5~
    }

    func test_f12_withModifiers_csiTildeForm() {
        let enc = KeyEncoder()
        XCTAssertEqual(enc.encodeSpecial(.f12, modifiers: [.shift]),
                       csiTilde(num: "24", mod: 2))    // ESC[24;2~
        XCTAssertEqual(enc.encodeSpecial(.f12, modifiers: [.control]),
                       csiTilde(num: "24", mod: 5))    // ESC[24;5~
        // Shift+Alt+Ctrl → mod 8
        XCTAssertEqual(
            enc.encodeSpecial(.f12, modifiers: [.shift, .option, .control]),
            csiTilde(num: "24", mod: 8)
        )
    }

    func test_f6ThroughF11_shiftModifier() {
        let enc = KeyEncoder()
        // Each F-key's unmodified code carries over to the modified form.
        XCTAssertEqual(enc.encodeSpecial(.f6,  modifiers: [.shift]),
                       csiTilde(num: "17", mod: 2))
        XCTAssertEqual(enc.encodeSpecial(.f7,  modifiers: [.shift]),
                       csiTilde(num: "18", mod: 2))
        XCTAssertEqual(enc.encodeSpecial(.f8,  modifiers: [.shift]),
                       csiTilde(num: "19", mod: 2))
        XCTAssertEqual(enc.encodeSpecial(.f9,  modifiers: [.shift]),
                       csiTilde(num: "20", mod: 2))
        XCTAssertEqual(enc.encodeSpecial(.f10, modifiers: [.shift]),
                       csiTilde(num: "21", mod: 2))
        XCTAssertEqual(enc.encodeSpecial(.f11, modifiers: [.shift]),
                       csiTilde(num: "23", mod: 2))
    }

    // Home / End with modifiers — same CSI 1;M <final> shape as arrows.

    func test_home_withModifiers_csiOneForm() {
        let enc = KeyEncoder()
        XCTAssertEqual(enc.encodeSpecial(.home, modifiers: [.shift]),
                       csiOneLetter(final: 0x48, mod: 2))   // ESC[1;2H
        XCTAssertEqual(enc.encodeSpecial(.home, modifiers: [.control]),
                       csiOneLetter(final: 0x48, mod: 5))   // ESC[1;5H
        XCTAssertEqual(
            enc.encodeSpecial(.home, modifiers: [.shift, .control]),
            csiOneLetter(final: 0x48, mod: 6)               // ESC[1;6H
        )
    }

    func test_end_withModifiers_csiOneForm() {
        let enc = KeyEncoder()
        XCTAssertEqual(enc.encodeSpecial(.end, modifiers: [.shift]),
                       csiOneLetter(final: 0x46, mod: 2))   // ESC[1;2F
        XCTAssertEqual(enc.encodeSpecial(.end, modifiers: [.control]),
                       csiOneLetter(final: 0x46, mod: 5))   // ESC[1;5F
    }

    // PageUp / PageDown with modifiers — CSI 5;M~ / CSI 6;M~.

    func test_pageUp_withModifiers() {
        let enc = KeyEncoder()
        XCTAssertEqual(enc.encodeSpecial(.pageUp, modifiers: [.shift]),
                       csiTilde(num: "5", mod: 2))          // ESC[5;2~
        XCTAssertEqual(enc.encodeSpecial(.pageUp, modifiers: [.control]),
                       csiTilde(num: "5", mod: 5))          // ESC[5;5~
    }

    func test_pageDown_withModifiers() {
        let enc = KeyEncoder()
        XCTAssertEqual(enc.encodeSpecial(.pageDown, modifiers: [.shift]),
                       csiTilde(num: "6", mod: 2))          // ESC[6;2~
        XCTAssertEqual(enc.encodeSpecial(.pageDown, modifiers: [.control]),
                       csiTilde(num: "6", mod: 5))          // ESC[6;5~
    }

    // Delete / Insert with modifiers — CSI 3;M~ / CSI 2;M~.

    func test_delete_withModifiers() {
        let enc = KeyEncoder()
        XCTAssertEqual(enc.encodeSpecial(.delete, modifiers: [.shift]),
                       csiTilde(num: "3", mod: 2))          // ESC[3;2~
        XCTAssertEqual(enc.encodeSpecial(.delete, modifiers: [.control]),
                       csiTilde(num: "3", mod: 5))          // ESC[3;5~
        XCTAssertEqual(
            enc.encodeSpecial(.delete, modifiers: [.shift, .option, .control]),
            csiTilde(num: "3", mod: 8)                      // ESC[3;8~
        )
    }

    func test_insert_withModifiers() {
        let enc = KeyEncoder()
        XCTAssertEqual(enc.encodeSpecial(.insert, modifiers: [.shift]),
                       csiTilde(num: "2", mod: 2))          // ESC[2;2~
        XCTAssertEqual(enc.encodeSpecial(.insert, modifiers: [.control]),
                       csiTilde(num: "2", mod: 5))          // ESC[2;5~
    }

    // MARK: - F3. applicationCursorKeys (DECCKM) branch

    /// Without modifiers, DECCKM swaps arrows / Home / End from CSI form
    /// (`ESC [ <final>`) to SS3 form (`ESC O <final>`). vim, less, and
    /// essentially every full-screen TUI sets this via `ESC [ ? 1 h`. A
    /// regression that reverted to CSI would pass every other input test
    /// and silently break arrow keys in vim.
    func test_applicationCursorKeys_unmodifiedArrows_ssO() {
        let enc = KeyEncoder()
        XCTAssertEqual(
            enc.encodeSpecial(.up, modifiers: [], applicationCursorKeys: true),
            Data([0x1B, 0x4F, 0x41])    // ESC O A
        )
        XCTAssertEqual(
            enc.encodeSpecial(.down, modifiers: [], applicationCursorKeys: true),
            Data([0x1B, 0x4F, 0x42])    // ESC O B
        )
        XCTAssertEqual(
            enc.encodeSpecial(.right, modifiers: [], applicationCursorKeys: true),
            Data([0x1B, 0x4F, 0x43])    // ESC O C
        )
        XCTAssertEqual(
            enc.encodeSpecial(.left, modifiers: [], applicationCursorKeys: true),
            Data([0x1B, 0x4F, 0x44])    // ESC O D
        )
    }

    func test_applicationCursorKeys_unmodifiedHomeEnd_ssO() {
        let enc = KeyEncoder()
        XCTAssertEqual(
            enc.encodeSpecial(.home, modifiers: [], applicationCursorKeys: true),
            Data([0x1B, 0x4F, 0x48])    // ESC O H
        )
        XCTAssertEqual(
            enc.encodeSpecial(.end, modifiers: [], applicationCursorKeys: true),
            Data([0x1B, 0x4F, 0x46])    // ESC O F
        )
    }

    /// With any modifier, applicationCursorKeys must be *ignored* — the
    /// modern xterm CSI 1;M form wins. This matches xterm's own DECCKM
    /// behaviour: SS3 is only used for unmodified navigation keys.
    func test_applicationCursorKeys_withModifiers_stillUsesCsiOneForm() {
        let enc = KeyEncoder()
        XCTAssertEqual(
            enc.encodeSpecial(.up, modifiers: [.shift], applicationCursorKeys: true),
            csiOneLetter(final: 0x41, mod: 2)           // ESC[1;2A, not ESC O A
        )
        XCTAssertEqual(
            enc.encodeSpecial(.left, modifiers: [.control], applicationCursorKeys: true),
            csiOneLetter(final: 0x44, mod: 5)           // ESC[1;5D
        )
        XCTAssertEqual(
            enc.encodeSpecial(.home, modifiers: [.shift, .control], applicationCursorKeys: true),
            csiOneLetter(final: 0x48, mod: 6)           // ESC[1;6H
        )
    }

    /// Non-navigation keys (F-keys, Page, Delete, Insert) ignore DECCKM
    /// entirely — their encoding doesn't change with or without the flag.
    /// Pin this so a refactor that accidentally threads appCursor into every
    /// branch doesn't break PageUp in vim.
    func test_applicationCursorKeys_doesNotAffectPageOrDelete() {
        let enc = KeyEncoder()
        XCTAssertEqual(
            enc.encodeSpecial(.pageUp, modifiers: [], applicationCursorKeys: true),
            Data([0x1B, 0x5B, 0x35, 0x7E])   // ESC [ 5 ~ (same as with flag off)
        )
        XCTAssertEqual(
            enc.encodeSpecial(.delete, modifiers: [], applicationCursorKeys: true),
            Data([0x1B, 0x5B, 0x33, 0x7E])   // ESC [ 3 ~
        )
        // F5 — CSI 15~ shape is independent of appCursor.
        XCTAssertEqual(
            enc.encodeSpecial(.f5, modifiers: [], applicationCursorKeys: true),
            Data([0x1B, 0x5B, 0x31, 0x35, 0x7E])
        )
    }

    // MARK: - F4. appKeypad mode — pin current no-op behaviour

    /// `BBTermMode.appKeypad` (bit 2, DECKPAM via `ESC =`) is tracked in the
    /// core mode bitfield but the encoder does not consume it today. Pin
    /// today's behaviour so any future DECKPAM implementation has to update
    /// these assertions deliberately rather than silently affect printable
    /// digit / operator keys.
    ///
    /// There is no `SpecialKey.kp*` case in the encoder — AppKit delivers
    /// numeric keypad presses as plain digit characters through `encode()`,
    /// which is the path these tests exercise.
    func test_appKeypad_modeBit_doesNotAlterPlainDigits() {
        let enc = KeyEncoder()
        let kp: BBTermMode = [.appKeypad]
        // Digits should pass through untouched under appKeypad.
        XCTAssertEqual(enc.encode(chars: "0", modifiers: [], mode: kp), Data([0x30]))
        XCTAssertEqual(enc.encode(chars: "1", modifiers: [], mode: kp), Data([0x31]))
        XCTAssertEqual(enc.encode(chars: "5", modifiers: [], mode: kp), Data([0x35]))
        XCTAssertEqual(enc.encode(chars: "9", modifiers: [], mode: kp), Data([0x39]))
    }

    func test_appKeypad_modeBit_doesNotAlterOperatorChars() {
        let enc = KeyEncoder()
        let kp: BBTermMode = [.appKeypad]
        // Operator characters on the numeric keypad (the ones DECKPAM
        // would historically rewrite as `ESC O <letter>` sequences) must
        // still pass as literal bytes until someone implements DECKPAM.
        XCTAssertEqual(enc.encode(chars: "+", modifiers: [], mode: kp), Data([0x2B]))
        XCTAssertEqual(enc.encode(chars: "-", modifiers: [], mode: kp), Data([0x2D]))
        XCTAssertEqual(enc.encode(chars: "*", modifiers: [], mode: kp), Data([0x2A]))
        XCTAssertEqual(enc.encode(chars: "/", modifiers: [], mode: kp), Data([0x2F]))
        XCTAssertEqual(enc.encode(chars: ".", modifiers: [], mode: kp), Data([0x2E]))
        // Keypad Enter reaches the encoder as "\r" (same as main Enter).
        XCTAssertEqual(enc.encode(chars: "\r", modifiers: [], mode: kp), Data([0x0D]))
    }

    func test_appKeypad_combinedWithDisambiguate_doesNotChangePlainDigits() {
        // Even when kitty flag 1 is also active, appKeypad is a no-op
        // for the `encode()` path — DECPAM only rewrites keys routed
        // through `encodeSpecial` (kp0..9 / kpEnter / kpPlus / etc.).
        let enc = KeyEncoder()
        let both: BBTermMode = [.appKeypad, .disambiguateEscCodes]
        XCTAssertEqual(enc.encode(chars: "7", modifiers: [], mode: both),
                       Data([0x37]))
    }

    // MARK: - DECPAM (application keypad mode) via encodeSpecial

    /// When DECPAM is active and the user presses a numeric keypad key,
    /// encodeSpecial emits SS3 sequences per the xterm keypad mapping.
    /// Digit 0..9 → ESC O p..y, operators → dedicated letters, Enter → M.
    func test_appKeypad_on_digits_emitSS3() {
        let enc = KeyEncoder()
        let pairs: [(KeyEncoder.SpecialKey, UInt8)] = [
            (.kp0, 0x70), (.kp1, 0x71), (.kp2, 0x72), (.kp3, 0x73),
            (.kp4, 0x74), (.kp5, 0x75), (.kp6, 0x76), (.kp7, 0x77),
            (.kp8, 0x78), (.kp9, 0x79),
        ]
        for (key, final) in pairs {
            XCTAssertEqual(
                enc.encodeSpecial(
                    key, modifiers: [], applicationKeypad: true
                ),
                Data([0x1B, 0x4F, final]),
                "DECPAM \(key) should emit ESC O \(String(UnicodeScalar(final)))"
            )
        }
    }

    func test_appKeypad_on_operators_emitSS3() {
        let enc = KeyEncoder()
        let pairs: [(KeyEncoder.SpecialKey, UInt8)] = [
            (.kpEnter, 0x4D),     // M
            (.kpPlus, 0x6B),      // k
            (.kpMinus, 0x6D),     // m
            (.kpMultiply, 0x6A),  // j
            (.kpDivide, 0x6F),    // o
            (.kpDecimal, 0x6E),   // n
            (.kpEquals, 0x58),    // X
        ]
        for (key, final) in pairs {
            XCTAssertEqual(
                enc.encodeSpecial(
                    key, modifiers: [], applicationKeypad: true
                ),
                Data([0x1B, 0x4F, final])
            )
        }
    }

    func test_appKeypad_off_fallBackToLegacyDigit() {
        // When DECPAM is off the keypad keys should pass their legacy
        // character through. Callers normally never route keypad events
        // through encodeSpecial without DECPAM, but the fallback
        // guards a future routing refactor.
        let enc = KeyEncoder()
        XCTAssertEqual(
            enc.encodeSpecial(.kp5, modifiers: [], applicationKeypad: false),
            Data([0x35])
        )
        XCTAssertEqual(
            enc.encodeSpecial(.kpEnter, modifiers: [], applicationKeypad: false),
            Data([0x0D])
        )
    }

    // MARK: - F10 / H7 (audit). optionIsMeta interaction with Ctrl+Option+arrow

    /// Native mode strips `.option` from `effectiveMods` for printables
    /// and special keys — Option produces OS dead-keys / glyphs and the
    /// shell shouldn't see it. EXCEPTION: when Ctrl is also held there
    /// is no dead-key in play, so the user's clear intent is Meta+Ctrl
    /// (Emacs M-C-* bindings). Both Native and Meta modes must report
    /// mod=7 (alt+ctrl) for Ctrl+Option+Up. Audit H7.
    func test_ctrlOptionUp_nativeAndMetaModesBothReportAltCtrl() {
        let native = KeyEncoder(optionIsMeta: false)
        XCTAssertEqual(
            native.encodeSpecial(.up, modifiers: [.control, .option]),
            csiOneLetter(final: 0x41, mod: 7),
            "Native mode preserves Option when Ctrl is also held — "
            + "Emacs M-C-Up reaches the shell intact"
        )
        let meta = KeyEncoder(optionIsMeta: true)
        XCTAssertEqual(
            meta.encodeSpecial(.up, modifiers: [.control, .option]),
            csiOneLetter(final: 0x41, mod: 7),
            "Meta mode: Alt bit + Ctrl bit both present in modParam"
        )
    }

    /// The Native-mode strip only applies to Option-only chords. With
    /// Ctrl absent, Option+Up still reports plain ESC[A in Native mode
    /// (Option is invisible). Pins the inverse so the H7 fix doesn't
    /// regress the Option-only behaviour that Native mode is for.
    func test_optionUp_nativeMode_strippedWithoutCtrl() {
        let native = KeyEncoder(optionIsMeta: false)
        XCTAssertEqual(
            native.encodeSpecial(.up, modifiers: [.option]),
            Data([0x1B, 0x5B, 0x41]),
            "Native mode + Option-only: still strips Option (modParam=1, no mods)"
        )
    }

    // MARK: - H4. Flag 8 multi-scalar IME commit falls back to UTF-8

    /// CSI u carries one base codepoint, so an IME commit of a decomposed
    /// grapheme (NFD `à` = `\u{0061}\u{0300}`) under flag 8 must NOT emit
    /// `ESC[97u` (which silently drops U+0300). The encoder falls back to
    /// the bare UTF-8 bytes — every TUI that opted into flag 8 already
    /// accepts UTF-8 text input, so this is the safe path.
    func test_flag8_multiScalar_nfdGraveAccent_fallsBackToUtf8() {
        let enc = KeyEncoder()
        let composed = "\u{0061}\u{0300}"   // 'a' + COMBINING GRAVE = NFD à
        XCTAssertEqual(
            enc.encode(chars: composed, modifiers: [], mode: [.reportAllKeysAsEsc]),
            Data(composed.utf8),
            "NFD à under flag 8 must fall back to UTF-8, not silently truncate to ESC[97u"
        )
    }

    /// Keycap `#️⃣` is `U+0023 U+FE0F U+20E3` — three scalars, one grapheme.
    /// Under flag 8 the existing single-scalar path would emit `ESC[35u` and
    /// drop VS-16 + COMBINING ENCLOSING KEYCAP, leaving the TUI to render
    /// a bare `#`. UTF-8 fallback preserves the keycap.
    func test_flag8_multiScalar_keycap_fallsBackToUtf8() {
        let enc = KeyEncoder()
        let keycap = "#\u{FE0F}\u{20E3}"
        XCTAssertEqual(
            enc.encode(chars: keycap, modifiers: [], mode: [.reportAllKeysAsEsc]),
            Data(keycap.utf8),
            "Keycap #️⃣ under flag 8 must fall back to UTF-8"
        )
    }

    /// Regression: the multi-scalar fallback must NOT short-circuit the
    /// single-scalar CSI u path. Plain unmodified `a` under flag 8 still
    /// emits `ESC[97u`.
    func test_flag8_singleScalarAscii_stillEmitsCsiU() {
        let enc = KeyEncoder()
        XCTAssertEqual(
            enc.encode(chars: "a", modifiers: [], mode: [.reportAllKeysAsEsc]),
            Data("\u{1B}[97u".utf8),
            "Single-scalar 'a' under flag 8 must still emit ESC[97u"
        )
    }

    /// Regression: the SINGLE-scalar precomposed `à` (U+00E0) is a grapheme
    /// that's also one Unicode scalar — must take the single-scalar CSI u
    /// path, NOT the multi-scalar UTF-8 fallback. The base codepoint goes
    /// out unchanged (224 = 0xE0); flag 8 doesn't normalize Latin-1 to a
    /// US-layout base.
    func test_flag8_singleScalarPrecomposedGrave_takesSingleScalarPath() {
        let enc = KeyEncoder()
        let precomposed = "\u{00E0}"        // single scalar à
        XCTAssertEqual(
            enc.encode(chars: precomposed, modifiers: [], mode: [.reportAllKeysAsEsc]),
            Data("\u{1B}[224u".utf8),
            "Single-scalar U+00E0 must take the CSI u path, not UTF-8 fallback"
        )
    }

    // MARK: - Ctrl+Option+letter Meta prefix (legacy mode)

    /// Bug: in legacy mode (empty `mode`, optionIsMeta=true) the encoder
    /// dropped the ESC Meta prefix for Ctrl+Option+letter and sent the bare
    /// C0 byte (`^F`), degrading Emacs/readline `M-C-f` (backward/forward-
    /// word over s-expressions) down to a plain forward-char. The arrow keys
    /// already report mod=7 (alt+ctrl) via the H7 fix; printable Ctrl+Option
    /// chords must match — "Option as Meta" prepends ESC (0x1B) before the
    /// C0 control byte, so Ctrl+Option+f → ESC + 0x06.
    func test_ctrlOptionLetter_metaMode_prependsEscBeforeC0() {
        let encoder = KeyEncoder(optionIsMeta: true)
        // Ctrl+f → C0 0x06; "Option as Meta" prepends ESC (0x1B).
        XCTAssertEqual(
            encoder.encode(chars: "f", modifiers: [.control, .option], mode: []),
            Data([0x1B, 0x06]),
            "Ctrl+Option+f in legacy/Meta mode must be ESC + ^F (M-C-f), not bare ^F"
        )
    }

    func test_ctrlOptionLetterA_metaMode_prependsEscBeforeC0() {
        let encoder = KeyEncoder(optionIsMeta: true)
        // Ctrl+a → C0 0x01; Meta prepends ESC.
        XCTAssertEqual(
            encoder.encode(chars: "a", modifiers: [.control, .option], mode: []),
            Data([0x1B, 0x01]),
            "Ctrl+Option+a in legacy/Meta mode must be ESC + ^A (M-C-a), not bare ^A"
        )
    }

    func test_ctrlOptionLetter_nativeMode_noEscPrefix() {
        let encoder = KeyEncoder(optionIsMeta: false)
        // Native-Option mode has no Meta bit — Option is invisible, so
        // Ctrl+Option+f encodes as just the bare C0 byte ^F (0x06).
        XCTAssertEqual(
            encoder.encode(chars: "f", modifiers: [.control, .option], mode: []),
            Data([0x06]),
            "Native-Option mode must send bare ^F for Ctrl+Option+f — no ESC prefix"
        )
    }

    func test_ctrlLetter_noOption_unchanged() {
        let encoder = KeyEncoder(optionIsMeta: true)
        // Plain Ctrl+f (Option not held) is unchanged: bare C0 0x06.
        // Pins the no-regression case — the Meta prefix only attaches when
        // Option is actually held.
        XCTAssertEqual(
            encoder.encode(chars: "f", modifiers: [.control], mode: []),
            Data([0x06]),
            "Plain Ctrl+f (no Option) must stay bare ^F — no ESC prefix"
        )
    }
}
