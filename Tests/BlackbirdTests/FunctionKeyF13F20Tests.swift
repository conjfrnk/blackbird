import XCTest
import AppKit
@testable import Blackbird
@testable import BBCore

/// BUG-8 — F13–F20 typed mojibake into the shell.
///
/// AppKit encodes function / editing keys that have no printable form as
/// scalars in the Unicode Private Use Area (the `U+F700` block:
/// `NSF1FunctionKey` = U+F704 … `NSF35FunctionKey` = U+F726, plus Clear,
/// Insert, Help, …). `KeyEventClassifier` only mapped F1–F12, so an F13
/// keypress fell through to the character path and the raw private-use
/// scalar was written to the PTY as UTF-8 — the line editor rendered it as
/// garbage on the command line.
///
/// Two halves of the fix are pinned here:
///
///  1. **F13–F20 encode as VT220 function keys.** Same `CSI <n> ~` /
///     `CSI <n> ; <mod> ~` shape F5–F12 already use, with the real (gapped)
///     xterm/VT220 parameter numbers 25, 26, 28, 29, 31, 32, 33, 34. The
///     gaps at 27 and 30 are genuine — kitty and iTerm2 use the same table
///     — so a "tidied" 25…32 run is a bug, not a cleanup.
///  2. **A wholly-private-use string never reaches the PTY.**
///     `KeyEventClassifier.isPrivateUseOnly` is the predicate the key-down
///     path uses to drop such input, so the *next* unmapped special key
///     (F21+, Clear, Help, a media key) degrades to "nothing happened"
///     rather than to visible garbage.
///
/// Byte-level assertions throughout: these sequences are a wire contract
/// with terminfo / readline / TUIs, so the tests pin bytes, never
/// descriptions.
final class FunctionKeyF13F20Tests: XCTestCase {

    override class func setUp() {
        super.setUp()
        TestHostTermination.shared.register()
    }

    // MARK: - Helpers

    /// Unmodified VT220 function-key shape: `CSI <num> ~`.
    private func csiTilde(_ num: String) -> Data {
        Data("\u{1B}[\(num)~".utf8)
    }

    /// Modified VT220 function-key shape: `CSI <num> ; <modParam> ~`,
    /// where `modParam` is xterm's 1 + (shift 1 | alt 2 | ctrl 4).
    private func csiTilde(_ num: String, mod: Int) -> Data {
        Data("\u{1B}[\(num);\(mod)~".utf8)
    }

    /// The VT220 / xterm parameter numbers for F13–F20, written out
    /// literally rather than derived by arithmetic: the sequence is
    /// deliberately gapped (no 27, no 30) and any formula that reproduces
    /// it would just be the bug in disguise.
    private let f13ThroughF20: [(key: KeyEncoder.SpecialKey, num: String)] = [
        (.f13, "25"),
        (.f14, "26"),
        (.f15, "28"),
        (.f16, "29"),
        (.f17, "31"),
        (.f18, "32"),
        (.f19, "33"),
        (.f20, "34"),
    ]

    /// AppKit private-use scalar for F13…F20 (`NSF13FunctionKey` =
    /// U+F710 … `NSF20FunctionKey` = U+F717) paired with the macOS
    /// virtual key code the hardware actually reports, so the classifier
    /// is exercised with realistic events.
    private let appKitF13ThroughF20: [(scalar: UInt32, keyCode: UInt16, expected: KeyEncoder.SpecialKey)] = [
        (0xF710, 105, .f13),
        (0xF711, 107, .f14),
        (0xF712, 113, .f15),
        (0xF713, 106, .f16),
        (0xF714,  64, .f17),
        (0xF715,  79, .f18),
        (0xF716,  80, .f19),
        (0xF717,  90, .f20),
    ]

    /// Synthesize an AppKit key-down carrying `scalar` as both `characters`
    /// and `charactersIgnoringModifiers` — exactly how macOS delivers a
    /// function key. `NSEvent.specialKey` is derived from that scalar, so a
    /// synthesized event classifies identically to a hardware one (the F12
    /// anchor in `test_classifier_mapsAppKitF13ThroughF20_...` proves the
    /// harness itself is sound before the F13–F20 claims are made).
    private func functionKeyEvent(
        scalar: UInt32,
        keyCode: UInt16,
        flags: NSEvent.ModifierFlags = [.function]
    ) throws -> NSEvent {
        let chars = String(try XCTUnwrap(Unicode.Scalar(scalar),
                                         "U+\(String(scalar, radix: 16, uppercase: true)) is not a valid Unicode scalar"))
        return try XCTUnwrap(
            NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: flags,
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                characters: chars,
                charactersIgnoringModifiers: chars,
                isARepeat: false,
                keyCode: keyCode
            ),
            "NSEvent.keyEvent returned nil for keyCode \(keyCode)"
        )
    }

    // MARK: - 1. F13–F20 unmodified

    /// Every one of the eight new keys emits its VT220 `CSI <n> ~` form.
    /// Pre-fix, `encodeSpecial` had no case at all for these — the keys
    /// never reached the encoder — so this is the primary contract test.
    func test_f13ThroughF20_unmodified_emitVT220CsiTildeSequences() {
        let enc = KeyEncoder()
        for (key, num) in f13ThroughF20 {
            XCTAssertEqual(enc.encodeSpecial(key, modifiers: []), csiTilde(num),
                           "\(key) unmodified must be ESC[\(num)~")
        }
    }

    /// The numbering gaps at 27 and 30 are load-bearing: xterm, kitty and
    /// iTerm2 all skip them, and terminfo's `kf13`…`kf20` are built on the
    /// gapped table. A "corrected" contiguous 25…32 run would silently
    /// alias F15 onto the wrong terminfo entry, so assert the gap numbers
    /// are emitted by no key at all.
    func test_f13ThroughF20_neverEmitTheSkippedParameters27Or30() {
        let enc = KeyEncoder()
        let forbidden = [csiTilde("27"), csiTilde("30")]
        for (key, _) in f13ThroughF20 {
            let out = enc.encodeSpecial(key, modifiers: [])
            for bad in forbidden {
                XCTAssertNotEqual(out, bad,
                                  "\(key) emitted \(String(decoding: bad, as: UTF8.self).debugDescription) — "
                                  + "27 and 30 are deliberate gaps in the VT220 numbering, not free slots")
            }
        }
    }

    /// Every function key must be distinguishable on the wire. A copy-paste
    /// slip in the new table (e.g. `.f14` reusing `"25"`) would make two
    /// physical keys indistinguishable to the shell while every individual
    /// assertion above still passed for the key that was correct.
    func test_f1ThroughF20_unmodifiedEncodingsAreAllDistinct() {
        let enc = KeyEncoder()
        let all: [KeyEncoder.SpecialKey] = [
            .f1, .f2, .f3, .f4, .f5, .f6, .f7, .f8, .f9, .f10, .f11, .f12,
            .f13, .f14, .f15, .f16, .f17, .f18, .f19, .f20,
        ]
        let encodings = all.map { enc.encodeSpecial($0, modifiers: []) }
        XCTAssertEqual(Set(encodings).count, all.count,
                       "F1–F20 must map to 20 distinct byte sequences; got "
                       + "\(Set(encodings).count) unique among \(all.count) keys")
        // No key may encode to nothing — an unhandled case returning empty
        // Data is precisely how F13 fell through to the character path.
        for (key, bytes) in zip(all, encodings) {
            XCTAssertFalse(bytes.isEmpty, "\(key) must encode to bytes, not empty Data")
        }
    }

    // MARK: - 2. F13–F20 with modifiers

    /// Shift / Control / the full three-modifier chord all take the same
    /// `CSI <n> ; <mod> ~` path F5–F12 use (`modParam` = 1 + shift 1 +
    /// alt 2 + ctrl 4), rather than a bespoke branch for the new keys.
    func test_f13_withModifiers_csiTildeParamForm() {
        let enc = KeyEncoder()
        XCTAssertEqual(enc.encodeSpecial(.f13, modifiers: [.shift]),
                       csiTilde("25", mod: 2), "Shift+F13 → ESC[25;2~")
        XCTAssertEqual(enc.encodeSpecial(.f13, modifiers: [.control]),
                       csiTilde("25", mod: 5), "Ctrl+F13 → ESC[25;5~")
        XCTAssertEqual(enc.encodeSpecial(.f13, modifiers: [.shift, .option, .control]),
                       csiTilde("25", mod: 8), "Shift+Opt+Ctrl+F13 → ESC[25;8~")
    }

    func test_f17AndF20_withModifiers_csiTildeParamForm() {
        let enc = KeyEncoder()
        XCTAssertEqual(enc.encodeSpecial(.f17, modifiers: [.shift]),
                       csiTilde("31", mod: 2), "Shift+F17 → ESC[31;2~")
        XCTAssertEqual(enc.encodeSpecial(.f17, modifiers: [.control]),
                       csiTilde("31", mod: 5), "Ctrl+F17 → ESC[31;5~")
        XCTAssertEqual(enc.encodeSpecial(.f20, modifiers: [.shift]),
                       csiTilde("34", mod: 2), "Shift+F20 → ESC[34;2~")
        XCTAssertEqual(enc.encodeSpecial(.f20, modifiers: [.control]),
                       csiTilde("34", mod: 5), "Ctrl+F20 → ESC[34;5~")
    }

    /// Sweep: Shift on all eight, so a per-key regression can't hide behind
    /// the two spot-checked keys above.
    func test_f13ThroughF20_withShift_allCarryModifierParameterTwo() {
        let enc = KeyEncoder()
        for (key, num) in f13ThroughF20 {
            XCTAssertEqual(enc.encodeSpecial(key, modifiers: [.shift]),
                           csiTilde(num, mod: 2),
                           "Shift+\(key) must be ESC[\(num);2~")
        }
    }

    /// Native-Option mode makes Option invisible to the shell for special
    /// keys (Option+Up is plain `ESC[A`). The new keys must inherit that
    /// shared rule rather than reimplement modifier handling: Option+F13
    /// collapses back to the unmodified `ESC[25~`.
    func test_f13_nativeOptionMode_stripsOptionLikeEveryOtherSpecialKey() {
        let enc = KeyEncoder(optionIsMeta: false)
        XCTAssertEqual(enc.encodeSpecial(.f13, modifiers: [.option]),
                       csiTilde("25"),
                       "Native-Option must strip .option from F13 exactly as it does for arrows")
        // Control keeps Option visible (the Meta+Ctrl chord exception), so
        // Ctrl+Option+F13 is still the full mod=7 form.
        XCTAssertEqual(enc.encodeSpecial(.f13, modifiers: [.option, .control]),
                       csiTilde("25", mod: 7),
                       "Ctrl+Option+F13 must keep the Meta bit → ESC[25;7~")
    }

    /// Kitty flag 2 (`reportEventTypes`) release/repeat framing is derived
    /// from the shared `(lead, terminator)` table, so F13 must gain it for
    /// free. F5 is asserted alongside as the anchor: identical shape, only
    /// the lead differs.
    func test_f13_kittyReportEventTypes_releaseUsesSharedCsiParamShape() {
        let enc = KeyEncoder()
        let flag2: BBTermMode = [.disambiguateEscCodes, .reportEventTypes]
        XCTAssertEqual(
            enc.encodeSpecial(.f5, modifiers: [], mode: flag2, eventType: .release),
            Data("\u{1B}[15;1:3~".utf8),
            "anchor: F5 release under flag 2 is ESC[15;1:3~"
        )
        XCTAssertEqual(
            enc.encodeSpecial(.f13, modifiers: [], mode: flag2, eventType: .release),
            Data("\u{1B}[25;1:3~".utf8),
            "F13 release under flag 2 must be ESC[25;1:3~ — same path as F5, only the lead differs"
        )
        XCTAssertEqual(
            enc.encodeSpecial(.f20, modifiers: [.shift], mode: flag2, eventType: .release),
            Data("\u{1B}[34;2:3~".utf8),
            "Shift+F20 release under flag 2 must be ESC[34;2:3~"
        )
        // Without flag 2 a release emits nothing — legacy TUIs must never
        // see post-keystroke traffic.
        XCTAssertEqual(
            enc.encodeSpecial(.f13, modifiers: [], mode: [], eventType: .release),
            Data(),
            "F13 release without reportEventTypes must emit no bytes"
        )
    }

    // MARK: - 3. Classifier maps the AppKit private-use scalars

    /// `KeyEventClassifier.specialKey(for:)` must recognise the F13–F20
    /// `NSEvent.SpecialKey` values. F12 is asserted first as a harness
    /// anchor: it proves a synthesized `NSEvent` really does expose
    /// `specialKey`, so a nil result for F13 is the classifier's gap and
    /// not an artifact of the test.
    func test_classifier_mapsAppKitF13ThroughF20_withF12Anchor() throws {
        let f12 = try functionKeyEvent(scalar: 0xF70F, keyCode: 111)
        XCTAssertEqual(KeyEventClassifier.specialKey(for: f12), .f12,
                       "anchor: a synthesized U+F70F event must already classify as .f12")

        for (scalar, keyCode, expected) in appKitF13ThroughF20 {
            let event = try functionKeyEvent(scalar: scalar, keyCode: keyCode)
            XCTAssertEqual(
                KeyEventClassifier.specialKey(for: event), expected,
                "U+\(String(scalar, radix: 16, uppercase: true)) (keyCode \(keyCode)) must classify as \(expected); "
                + "returning nil is what sent the raw private-use scalar to the PTY"
            )
        }
    }

    /// Some keyboards report function keys with `.numericPad` set as well.
    /// The F13 mapping must win over the keypad fallback branch, which
    /// keys off virtual key codes and would otherwise swallow the event.
    func test_classifier_f13WithNumericPadFlag_stillMapsToF13() throws {
        let event = try functionKeyEvent(scalar: 0xF710, keyCode: 105,
                                         flags: [.function, .numericPad])
        XCTAssertEqual(KeyEventClassifier.specialKey(for: event), .f13,
                       "F13 must classify as .f13 even when the event also carries .numericPad")
    }

    /// Ties the two halves of the fix together: the exact string AppKit
    /// hands us for F13 is the thing that used to be written to the PTY,
    /// and it is wholly private-use — so even if a key were left unmapped,
    /// the predicate catches it.
    func test_appKitF13Characters_areRecognisedAsPrivateUseOnly() throws {
        for (scalar, keyCode, _) in appKitF13ThroughF20 {
            let event = try functionKeyEvent(scalar: scalar, keyCode: keyCode)
            let chars = try XCTUnwrap(event.charactersIgnoringModifiers,
                                      "synthesized event must carry charactersIgnoringModifiers")
            XCTAssertTrue(
                KeyEventClassifier.isPrivateUseOnly(chars),
                "U+\(String(scalar, radix: 16, uppercase: true)) is what the shell rendered as garbage; "
                + "it must be classified as private-use so the key-down path drops it"
            )
        }
    }

    /// The whole `U+F700` function-key block AppKit uses — F1–F35, arrows,
    /// Insert, Clear, Help, the media keys — is private-use. 72 single-scalar
    /// strings; negligible cost.
    func test_isPrivateUseOnly_coversTheEntireAppKitFunctionKeyBlock() throws {
        for value in UInt32(0xF700)...UInt32(0xF747) {
            let scalar = try XCTUnwrap(Unicode.Scalar(value),
                                       "U+\(String(value, radix: 16, uppercase: true)) must be a valid scalar")
            XCTAssertTrue(KeyEventClassifier.isPrivateUseOnly(String(scalar)),
                          "U+\(String(value, radix: 16, uppercase: true)) is inside the BMP PUA")
        }
    }

    // MARK: - 4. isPrivateUseOnly semantics

    /// Empty input is *not* private-use. "Nothing to type" must not be
    /// reported as "suppress this" — the distinction matters for callers
    /// that branch on the predicate before deciding to fall through.
    func test_isPrivateUseOnly_emptyStringIsFalse() {
        XCTAssertFalse(KeyEventClassifier.isPrivateUseOnly(""),
                       "an empty string has nothing to suppress and must return false")
    }

    /// BMP Private Use Area — U+E000…U+F8FF inclusive — plus the scalars
    /// immediately outside it.
    func test_isPrivateUseOnly_bmpBoundaries() {
        // Inclusive endpoints.
        XCTAssertTrue(KeyEventClassifier.isPrivateUseOnly("\u{E000}"),
                      "U+E000 is the first BMP private-use scalar")
        XCTAssertTrue(KeyEventClassifier.isPrivateUseOnly("\u{F8FF}"),
                      "U+F8FF is the last BMP private-use scalar")
        // Interior sample: the block AppKit actually uses.
        XCTAssertTrue(KeyEventClassifier.isPrivateUseOnly("\u{F710}"),
                      "U+F710 (NSF13FunctionKey) is inside the BMP PUA")

        // Just above the block: U+F900 is a CJK compatibility ideograph,
        // ordinary text that must reach the PTY untouched.
        XCTAssertFalse(KeyEventClassifier.isPrivateUseOnly("\u{F900}"),
                       "U+F900 is a CJK compatibility ideograph, above the BMP PUA")

        // Just below the block: U+DFFF is the documented lower neighbour,
        // but it is a low surrogate — Swift cannot build a Unicode.Scalar
        // (let alone a String) from it, so the predicate is unreachable
        // there by construction. Pin that fact, then assert the nearest
        // scalar a String CAN carry below the PUA.
        XCTAssertNil(Unicode.Scalar(UInt32(0xDFFF)),
                     "U+DFFF is a surrogate: no String can contain it, so it can never reach the predicate")
        XCTAssertFalse(KeyEventClassifier.isPrivateUseOnly("\u{D7FF}"),
                       "U+D7FF is the highest scalar below the surrogate range and is not private-use")
    }

    /// Supplementary private-use planes 15 and 16, at their documented
    /// endpoints — U+F0000…U+FFFFD and U+100000…U+10FFFD — plus the
    /// scalars just outside each.
    func test_isPrivateUseOnly_supplementaryPlaneBoundaries() {
        XCTAssertTrue(KeyEventClassifier.isPrivateUseOnly("\u{F0000}"),
                      "U+F0000 is the first plane-15 private-use scalar")
        XCTAssertTrue(KeyEventClassifier.isPrivateUseOnly("\u{FFFFD}"),
                      "U+FFFFD is the last plane-15 private-use scalar")
        XCTAssertTrue(KeyEventClassifier.isPrivateUseOnly("\u{100000}"),
                      "U+100000 is the first plane-16 private-use scalar")
        XCTAssertTrue(KeyEventClassifier.isPrivateUseOnly("\u{10FFFD}"),
                      "U+10FFFD is the last plane-16 private-use scalar")

        // Immediately below plane 15's PUA.
        XCTAssertFalse(KeyEventClassifier.isPrivateUseOnly("\u{EFFFF}"),
                       "U+EFFFF sits just below the plane-15 PUA and is not private-use")
        XCTAssertFalse(KeyEventClassifier.isPrivateUseOnly("\u{E0001}"),
                       "U+E0001 (LANGUAGE TAG, plane 14) is not private-use")
        // Immediately above each PUA range: the plane-terminating
        // noncharacters. The ranges end at ...FFFD by definition, so
        // ...FFFE / ...FFFF are outside them.
        XCTAssertFalse(KeyEventClassifier.isPrivateUseOnly("\u{FFFFE}"),
                       "U+FFFFE is a noncharacter — the plane-15 PUA ends at U+FFFFD")
        XCTAssertFalse(KeyEventClassifier.isPrivateUseOnly("\u{10FFFE}"),
                       "U+10FFFE is a noncharacter — the plane-16 PUA ends at U+10FFFD")
    }

    /// Ordinary typed text must never be suppressed. These are the strings
    /// the encoder legitimately sends to the shell every keystroke.
    func test_isPrivateUseOnly_ordinaryTextIsFalse() {
        let ordinary = ["a", "Z", "1", " ", "\u{1B}", "\r", "\t", "\u{7F}",
                        "hello world", "漢", "😀", "é", "~", "\0"]
        for text in ordinary {
            XCTAssertFalse(KeyEventClassifier.isPrivateUseOnly(text),
                           "\(text.debugDescription) is ordinary input and must not be suppressed")
        }
    }

    /// "Every scalar" is the rule: one ordinary scalar anywhere in the
    /// string disqualifies it. Suppressing mixed content would silently
    /// swallow real typed text (e.g. an IME commit that happens to carry a
    /// private-use glyph from a custom font).
    func test_isPrivateUseOnly_mixedContentIsFalse() {
        XCTAssertFalse(KeyEventClassifier.isPrivateUseOnly("a\u{F710}"),
                       "leading ordinary scalar disqualifies the string")
        XCTAssertFalse(KeyEventClassifier.isPrivateUseOnly("\u{F710}a"),
                       "trailing ordinary scalar disqualifies the string")
        XCTAssertFalse(KeyEventClassifier.isPrivateUseOnly("\u{E000}x\u{F8FF}"),
                       "an ordinary scalar in the middle disqualifies the string")
        XCTAssertFalse(KeyEventClassifier.isPrivateUseOnly("\u{F0000}\u{F900}"),
                       "a supplementary private-use scalar plus one ordinary scalar is not private-use-only")
    }

    /// Multi-scalar strings that are *wholly* private-use still qualify,
    /// including ones that mix the three PUA ranges.
    func test_isPrivateUseOnly_multiScalarAllPrivateUseIsTrue() {
        XCTAssertTrue(KeyEventClassifier.isPrivateUseOnly("\u{F710}\u{F711}"),
                      "two BMP private-use scalars are private-use-only")
        XCTAssertTrue(KeyEventClassifier.isPrivateUseOnly("\u{E000}\u{F0000}\u{10FFFD}"),
                      "scalars drawn from all three private-use ranges are private-use-only")
    }

    // MARK: - 5. Regression guard on the pre-existing keys

    /// The pre-existing table must be byte-for-byte unchanged by the F13–F20
    /// addition. F5–F12 in particular share the `~` family the new keys join,
    /// so an off-by-one while extending the table would land here first.
    func test_preExistingFunctionKeys_unmodifiedEncodingsUnchanged() {
        let enc = KeyEncoder()
        // F1–F4 are SS3: ESC O P/Q/R/S — no numeric lead.
        XCTAssertEqual(enc.encodeSpecial(.f1, modifiers: []), Data([0x1B, 0x4F, 0x50]), "F1 → ESC O P")
        XCTAssertEqual(enc.encodeSpecial(.f2, modifiers: []), Data([0x1B, 0x4F, 0x51]), "F2 → ESC O Q")
        XCTAssertEqual(enc.encodeSpecial(.f3, modifiers: []), Data([0x1B, 0x4F, 0x52]), "F3 → ESC O R")
        XCTAssertEqual(enc.encodeSpecial(.f4, modifiers: []), Data([0x1B, 0x4F, 0x53]), "F4 → ESC O S")

        // F5–F12 keep their own gapped numbering (no 16, no 22).
        let legacyTilde: [(KeyEncoder.SpecialKey, String)] = [
            (.f5, "15"), (.f6, "17"), (.f7, "18"), (.f8, "19"),
            (.f9, "20"), (.f10, "21"), (.f11, "23"), (.f12, "24"),
        ]
        for (key, num) in legacyTilde {
            XCTAssertEqual(enc.encodeSpecial(key, modifiers: []), csiTilde(num),
                           "\(key) unmodified must still be ESC[\(num)~")
        }
    }

    func test_preExistingFunctionKeys_modifiedEncodingsUnchanged() {
        let enc = KeyEncoder()
        XCTAssertEqual(enc.encodeSpecial(.f12, modifiers: [.shift]),
                       csiTilde("24", mod: 2), "Shift+F12 → ESC[24;2~")
        XCTAssertEqual(enc.encodeSpecial(.f12, modifiers: [.control]),
                       csiTilde("24", mod: 5), "Ctrl+F12 → ESC[24;5~")
        XCTAssertEqual(enc.encodeSpecial(.f12, modifiers: [.shift, .option, .control]),
                       csiTilde("24", mod: 8), "Shift+Opt+Ctrl+F12 → ESC[24;8~")
        XCTAssertEqual(enc.encodeSpecial(.f5, modifiers: [.shift]),
                       csiTilde("15", mod: 2), "Shift+F5 → ESC[15;2~")
        XCTAssertEqual(enc.encodeSpecial(.f1, modifiers: [.shift]),
                       Data("\u{1B}[1;2P".utf8), "Shift+F1 → ESC[1;2P")
    }

    /// The non-function special keys share the same `csiParamShape` table
    /// the new entries extend; pin the neighbours that would break if the
    /// table were mis-edited.
    func test_preExistingNavAndArrowKeys_encodingsUnchanged() {
        let enc = KeyEncoder()
        XCTAssertEqual(enc.encodeSpecial(.up, modifiers: []), Data([0x1B, 0x5B, 0x41]), "Up → ESC[A")
        XCTAssertEqual(enc.encodeSpecial(.down, modifiers: []), Data([0x1B, 0x5B, 0x42]), "Down → ESC[B")
        XCTAssertEqual(enc.encodeSpecial(.right, modifiers: []), Data([0x1B, 0x5B, 0x43]), "Right → ESC[C")
        XCTAssertEqual(enc.encodeSpecial(.left, modifiers: []), Data([0x1B, 0x5B, 0x44]), "Left → ESC[D")
        XCTAssertEqual(enc.encodeSpecial(.home, modifiers: []), Data([0x1B, 0x5B, 0x48]), "Home → ESC[H")
        XCTAssertEqual(enc.encodeSpecial(.end, modifiers: []), Data([0x1B, 0x5B, 0x46]), "End → ESC[F")
        XCTAssertEqual(enc.encodeSpecial(.insert, modifiers: []), csiTilde("2"), "Insert → ESC[2~")
        XCTAssertEqual(enc.encodeSpecial(.delete, modifiers: []), csiTilde("3"), "Delete → ESC[3~")
        XCTAssertEqual(enc.encodeSpecial(.pageUp, modifiers: []), csiTilde("5"), "PageUp → ESC[5~")
        XCTAssertEqual(enc.encodeSpecial(.pageDown, modifiers: []), csiTilde("6"), "PageDown → ESC[6~")
    }

    /// The classifier's pre-existing mappings must survive the new cases —
    /// in particular Backspace stays unmapped (it must emit the DEL byte via
    /// the character path, not `CSI 3 ~`), and the arrow cluster still maps.
    func test_classifier_preExistingMappingsUnchanged() throws {
        let up = try functionKeyEvent(scalar: 0xF700, keyCode: 126, flags: [.function, .numericPad])
        XCTAssertEqual(KeyEventClassifier.specialKey(for: up), .up, "U+F700 must still classify as .up")

        let f1 = try functionKeyEvent(scalar: 0xF704, keyCode: 122)
        XCTAssertEqual(KeyEventClassifier.specialKey(for: f1), .f1, "U+F704 must still classify as .f1")

        // U+F728 is NSDeleteFunctionKey (forward delete) → .delete.
        let forwardDelete = try functionKeyEvent(scalar: 0xF728, keyCode: 117)
        XCTAssertEqual(KeyEventClassifier.specialKey(for: forwardDelete), .delete,
                       "U+F728 (forward delete) must still classify as .delete")

        // Backspace is NOT a special key here by design: it must take the
        // character path so the PTY receives DEL (0x7F).
        let backspace = try XCTUnwrap(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: 0, context: nil, characters: "\u{7F}",
                charactersIgnoringModifiers: "\u{7F}", isARepeat: false, keyCode: 51
            ),
            "NSEvent.keyEvent returned nil for Backspace"
        )
        XCTAssertNil(KeyEventClassifier.specialKey(for: backspace),
                     "Backspace must stay unmapped so it emits DEL (0x7F) via the character path")
    }
}
