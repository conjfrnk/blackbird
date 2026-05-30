import XCTest
@testable import Blackbird
@testable import BBCore

/// Fail-first regression coverage for audit **S3S-002**: keypad keys routed
/// through `encodeSpecial` with application-keypad mode (DECPAM) OFF used to
/// emit a bare legacy byte and silently DISCARD every modifier
/// (`Option-as-Meta`, Kitty disambiguation / flag 8, xterm `modifyOtherKeys`).
///
/// The fix routes a DECPAM-off keypad key's plain character through the same
/// `encode(chars:modifiers:mode:)` path a normal printable digit / operator
/// takes, so all of those protocols apply to keypad keys exactly as they do to
/// the top-row digits. With no modifiers and no protocol mode the output is the
/// same bare legacy byte as before (kp5 -> 0x35, kpEnter -> CR 0x0D).
///
/// The oracle in `test_decpamOff_parityWithPlainChar_matrix` compares the two
/// methods directly rather than hardcoding framed byte sequences, so the
/// `encode(chars:)` path — itself independently pinned by `KeyEncoderTests` and
/// `KeyEncoderExtendedTests` — is the source of truth and the assertion is
/// never tautological. On the OLD bare-byte code the matrix and the headline
/// repro both FAIL wherever a modifier or protocol mode is present; post-fix
/// they pass. Pure function calls only — trivial memory/time cost.
final class KeyEncoderKeypadModifierTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        TestHostTermination.shared.register()
    }

    // MARK: - 1. Headline fail-first repro (the exact S3S-002 finding)

    /// Option+keypad-9 in Meta mode, DECPAM off. The OLD code returned the
    /// bare byte `Data([0x39])` and dropped the `.option` Meta modifier; the
    /// fix routes through `encode(chars:)` so Option-as-Meta prepends ESC,
    /// producing `ESC "9"` == `Data([0x1B, 0x39])`. Fails pre-fix, passes
    /// post-fix.
    func test_decpamOff_optionKp9_metaMode_prependsEsc() {
        let enc = KeyEncoder(optionIsMeta: true)
        XCTAssertEqual(
            enc.encodeSpecial(.kp9, modifiers: [.option], applicationKeypad: false),
            Data([0x1B, 0x39]),
            "DECPAM-off Option+kp9 in Meta mode must emit ESC \"9\" "
            + "(0x1B 0x39), not the bare byte 0x39 — S3S-002"
        )
    }

    // MARK: - 2. Parity oracle — DECPAM-off keypad key == its plain character

    /// The documented contract: a DECPAM-off keypad key must encode
    /// IDENTICALLY to its plain character through `encode(chars:)`, carrying
    /// every modifier and every protocol mode bit. The OLD code violated this
    /// (it dropped modifiers/mode), so this matrix FAILS pre-fix at every cell
    /// where the modifier set or mode is non-trivial, and PASSES post-fix.
    ///
    /// We compare the two encoder methods directly — the framed byte sequences
    /// are never hardcoded here, so the oracle is the independently-tested
    /// `encode(chars:)` path.
    func test_decpamOff_parityWithPlainChar_matrix() {
        // Full keypad table so the production legacyChar mapping is pinned
        // end-to-end (a wrong char, e.g. kpMinus -> "+", would break parity).
        let pairs: [(KeyEncoder.SpecialKey, String)] = [
            (.kp0, "0"), (.kp1, "1"), (.kp2, "2"), (.kp3, "3"), (.kp4, "4"),
            (.kp5, "5"), (.kp6, "6"), (.kp7, "7"), (.kp8, "8"), (.kp9, "9"),
            (.kpEnter, "\r"),
            (.kpPlus, "+"),
            (.kpMinus, "-"),
            (.kpMultiply, "*"),
            (.kpDivide, "/"),
            (.kpDecimal, "."),
            (.kpEquals, "="),
        ]
        let modifierSets: [KeyEncoder.Modifiers] = [
            [],
            [.option],
            [.shift],
            [.control],
            [.option, .shift],
        ]
        let modes: [BBTermMode] = [
            [],
            [.modifyOtherKeys],
            [.reportAllKeysAsEsc],
            [.disambiguateEscCodes],
        ]
        for optionIsMeta in [true, false] {
            let enc = KeyEncoder(optionIsMeta: optionIsMeta)
            for (key, plainChar) in pairs {
                for mods in modifierSets {
                    for mode in modes {
                        let special = enc.encodeSpecial(
                            key,
                            modifiers: mods,
                            applicationKeypad: false,
                            mode: mode
                        )
                        let plain = enc.encode(
                            chars: plainChar,
                            modifiers: mods,
                            mode: mode
                        )
                        XCTAssertEqual(
                            special, plain,
                            "DECPAM-off \(key) must encode identically to its "
                            + "plain char \(plainChar.debugDescription) — "
                            + "modifiers=\(mods.rawValue) mode=\(mode.rawValue) "
                            + "optionIsMeta=\(optionIsMeta)"
                        )
                    }
                }
            }
        }
    }

    // MARK: - 3. Regression guards (must stay true)

    /// Unmodified DECPAM-off keypad keys emit the same bare legacy byte they
    /// always have — the unmodified fast path is unchanged by the fix.
    func test_decpamOff_unmodified_bareLegacyByteUnchanged() {
        for optionIsMeta in [true, false] {
            let enc = KeyEncoder(optionIsMeta: optionIsMeta)
            XCTAssertEqual(
                enc.encodeSpecial(.kp5, modifiers: [], applicationKeypad: false),
                Data([0x35]),
                "DECPAM-off kp5 unmodified must stay 0x35 "
                + "(optionIsMeta=\(optionIsMeta))"
            )
            XCTAssertEqual(
                enc.encodeSpecial(.kpEnter, modifiers: [], applicationKeypad: false),
                Data([0x0D]),
                "DECPAM-off kpEnter unmodified must stay CR 0x0D "
                + "(optionIsMeta=\(optionIsMeta))"
            )
        }
    }

    /// The DECPAM-ON (application-keypad) SS3 path is completely unchanged by
    /// the fix — `kp9` with DECPAM on still emits `ESC O y`.
    func test_decpamOn_ss3PathUnchanged() {
        let enc = KeyEncoder()
        XCTAssertEqual(
            enc.encodeSpecial(.kp9, modifiers: [], applicationKeypad: true),
            Data([0x1B, 0x4F, 0x79]),    // ESC O y
            "DECPAM-on kp9 must still emit SS3 ESC O y — unaffected by S3S-002 fix"
        )
    }
}
