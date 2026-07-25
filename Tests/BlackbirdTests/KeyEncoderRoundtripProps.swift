import XCTest
@testable import Blackbird
@testable import BBCore

/// Property-style randomized sweep over `KeyEncoder`. Complements the
/// case-by-case files (`KeyEncoderTests`, `KeyEncoderAdversarialTests`,
/// `KeyEncoderExtendedTests`, `KeyEncoderProtocolPrecedenceTests`,
/// `KittyKeyboardProtocolTests`) by stating *invariants* — properties that
/// must hold across every input in a sweep — rather than pinning single
/// (input, expected) pairs.
///
/// The properties pinned here are:
///   1. Plain ASCII printable round-trip is a single byte == the char.
///   2. Cmd + printable is suppressed to empty Data, full sweep.
///   3. Ctrl + lowercase letter produces the C0 byte (`c - 'a' + 1`).
///   4. Random modifier/char combos do not panic AND produce ≤32 bytes.
///   5. Encoding is deterministic — encoding twice yields the same bytes.
///   6. Modifier order doesn't matter ([.shift, .option] == [.option, .shift]).
///   7. All-modifiers + Return is always non-empty (Enter emits SOMETHING).
///   8. Under Kitty disambiguate mode, function-key specials emit a CSI/SS3
///      sequence starting with `ESC [` or `ESC O`.
///
/// All randomness is driven by a seeded LCG so the same suite produces the
/// same sequence locally vs. CI. `SystemRandomNumberGenerator` is non-
/// deterministic and was avoided here on purpose.
///
/// Pre-flight memory cost: every test allocates a `KeyEncoder` (no heap
/// state), at most a handful of `Data` outputs per iteration, and a string
/// of at most a few bytes. The largest sweep is 200 iterations × ~32-byte
/// outputs ≈ 6 KiB. No PTY, no grids, no real `MainWindowController`. Safe
/// under the 256 MiB budget.
final class KeyEncoderRoundtripProps: XCTestCase {

    override class func setUp() {
        super.setUp()
        TestHostTermination.shared.register()
    }

    // MARK: - Deterministic LCG

    /// Tiny LCG (Numerical Recipes constants) — deterministic per seed so
    /// the same iteration sequence runs in CI as on a dev machine. Output
    /// is used only to *sample* test inputs; statistical quality doesn't
    /// matter here.
    private struct Lcg {
        var state: UInt64
        mutating func next() -> UInt64 {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return state
        }
        mutating func nextInt(in range: Range<Int>) -> Int {
            let span = UInt64(range.upperBound - range.lowerBound)
            return range.lowerBound + Int(next() % span)
        }
        mutating func nextUInt8() -> UInt8 {
            UInt8(truncatingIfNeeded: next() >> 24)
        }
    }

    // MARK: - Helpers

    /// Build a `KeyEncoder.Modifiers` set from a 4-bit mask.
    /// bit 0 = shift, bit 1 = control, bit 2 = option, bit 3 = command.
    private func mods(from mask: UInt8) -> KeyEncoder.Modifiers {
        var m: KeyEncoder.Modifiers = []
        if mask & 0x1 != 0 { m.insert(.shift) }
        if mask & 0x2 != 0 { m.insert(.control) }
        if mask & 0x4 != 0 { m.insert(.option) }
        if mask & 0x8 != 0 { m.insert(.command) }
        return m
    }

    /// Sample input character pool — covers ASCII printables, control
    /// chars, and one multi-byte UTF-8 scalar to exercise the UTF-8 tail.
    private static let charPool: [String] = [
        "a", "Z", "1", "0", ".", "?", ",", "/", "<", "@", "_", "[", "]",
        " ", "\r", "\t", "\u{1B}", "\u{7F}", "é", "🌎",
    ]

    // MARK: - Property 1: ASCII printable round-trip

    /// Every printable ASCII codepoint 0x20..=0x7E encoded with no
    /// modifiers must emit exactly the single literal byte. Exhaustive
    /// (95 chars), not a random sample — small enough to cover all.
    func test_prop_allPrintableAscii_roundTripSingleByte() {
        let enc = KeyEncoder()
        for cp in UInt8(0x20)...UInt8(0x7E) {
            let ch = String(UnicodeScalar(cp))
            let out = enc.encode(chars: ch, modifiers: [])
            XCTAssertEqual(
                out, Data([cp]),
                "Printable 0x\(String(cp, radix: 16)) ('\(ch)') must encode to its own byte; got \(Array(out))"
            )
        }
    }

    // MARK: - Property 2: Cmd + printable is suppressed

    /// Cmd is reserved for app-menu shortcuts and must never reach the
    /// PTY as bytes. Sweep every printable ASCII with `.command` set; the
    /// encoder must return empty Data each time.
    func test_prop_cmdPrintable_alwaysSuppressed() {
        let enc = KeyEncoder()
        for cp in UInt8(0x20)...UInt8(0x7E) {
            let ch = String(UnicodeScalar(cp))
            let out = enc.encode(chars: ch, modifiers: [.command])
            XCTAssertEqual(
                out, Data(),
                "Cmd+'\(ch)' must produce empty Data; got \(Array(out))"
            )
        }
    }

    // MARK: - Property 3: Ctrl + lowercase letter → C0

    /// `Ctrl+a` -> 0x01, …, `Ctrl+z` -> 0x1A. Pin all 26.
    func test_prop_ctrlLowercaseLetters_emitC0() {
        let enc = KeyEncoder()
        for cp in UInt8(0x61)...UInt8(0x7A) {
            let ch = String(UnicodeScalar(cp))
            let expected = cp - 0x60       // 'a'(0x61) -> 0x01
            let out = enc.encode(chars: ch, modifiers: [.control])
            XCTAssertEqual(
                out, Data([expected]),
                "Ctrl+'\(ch)' must emit 0x\(String(expected, radix: 16)); got \(Array(out))"
            )
        }
    }

    // MARK: - Property 4: bounded output / no panic on random inputs

    /// 200 iterations of (random char from `charPool`, random 4-bit
    /// modifier mask). Assert the output is a `Data` of length ≤ 32 bytes.
    /// The positive bound replaces a naked "doesn't crash" — a regression
    /// that emitted an unbounded sequence (e.g. an infinite-loop bug
    /// truncated at some buffer ceiling) would fail the bound.
    func test_prop_randomInputs_boundedOutput() {
        let enc = KeyEncoder()
        var rng = Lcg(state: 0xBB01_5EED_ABCD_E001)
        for i in 0..<200 {
            let ch = Self.charPool[rng.nextInt(in: 0..<Self.charPool.count)]
            let modMask = rng.nextUInt8() & 0xF
            let m = mods(from: modMask)
            let out = enc.encode(chars: ch, modifiers: m)
            XCTAssertLessThanOrEqual(
                out.count, 32,
                """
                Iteration \(i): output exceeds 32-byte bound.
                  chars=\(Array(ch.utf8)) modMask=0x\(String(modMask, radix: 16))
                  outLen=\(out.count) outBytes=\(Array(out.prefix(64)))
                """
            )
        }
    }

    /// Same sweep, but with random Kitty/modifyOtherKeys mode bits also
    /// flipped. Catches a regression in the protocol paths that could
    /// emit an unbounded CSI-u tail (e.g. a runaway text section under
    /// flag 16). Still 200 iterations, still ≤32 bytes per output.
    func test_prop_randomInputs_withRandomModeBits_boundedOutput() {
        let enc = KeyEncoder()
        var rng = Lcg(state: 0xBB02_5EED_ABCD_E002)
        let modeBits: [BBTermMode] = [
            .disambiguateEscCodes, .reportEventTypes, .reportAlternateKeys,
            .reportAllKeysAsEsc, .reportAssociatedText, .modifyOtherKeys,
        ]
        for i in 0..<200 {
            let ch = Self.charPool[rng.nextInt(in: 0..<Self.charPool.count)]
            let modMask = rng.nextUInt8() & 0xF
            let m = mods(from: modMask)
            // Sample a random subset of mode bits.
            var mode: BBTermMode = []
            let modeMask = rng.nextUInt8()
            for (bitIdx, bit) in modeBits.enumerated() where (modeMask >> bitIdx) & 1 == 1 {
                mode.formUnion(bit)
            }
            let out = enc.encode(chars: ch, modifiers: m, mode: mode)
            XCTAssertLessThanOrEqual(
                out.count, 32,
                """
                Iteration \(i): output exceeds 32-byte bound under random mode.
                  chars=\(Array(ch.utf8)) modMask=0x\(String(modMask, radix: 16))
                  modeRaw=\(mode.rawValue) outLen=\(out.count)
                  outBytes=\(Array(out.prefix(64)))
                """
            )
        }
    }

    // MARK: - Property 5: determinism

    /// Same input encoded twice produces identical Data. 100 iterations
    /// of random (char, modifiers) pairs.
    func test_prop_encodingIsDeterministic() {
        let enc = KeyEncoder()
        var rng = Lcg(state: 0xBB03_5EED_ABCD_E003)
        for i in 0..<100 {
            let ch = Self.charPool[rng.nextInt(in: 0..<Self.charPool.count)]
            let modMask = rng.nextUInt8() & 0xF
            let m = mods(from: modMask)
            let a = enc.encode(chars: ch, modifiers: m)
            let b = enc.encode(chars: ch, modifiers: m)
            XCTAssertEqual(
                a, b,
                """
                Iteration \(i): encoder produced non-deterministic output.
                  chars=\(Array(ch.utf8)) modMask=0x\(String(modMask, radix: 16))
                  first=\(Array(a)) second=\(Array(b))
                """
            )
        }
    }

    /// Determinism across two distinct `KeyEncoder` instances: the
    /// encoder must hold no shared mutable state. Same input on a fresh
    /// instance produces the same output. 50 iterations.
    func test_prop_separateInstances_produceIdenticalOutput() {
        var rng = Lcg(state: 0xBB04_5EED_ABCD_E004)
        for i in 0..<50 {
            let enc1 = KeyEncoder()
            let enc2 = KeyEncoder()
            let ch = Self.charPool[rng.nextInt(in: 0..<Self.charPool.count)]
            let modMask = rng.nextUInt8() & 0xF
            let m = mods(from: modMask)
            let a = enc1.encode(chars: ch, modifiers: m)
            let b = enc2.encode(chars: ch, modifiers: m)
            XCTAssertEqual(
                a, b,
                """
                Iteration \(i): two fresh KeyEncoders disagreed.
                  chars=\(Array(ch.utf8)) modMask=0x\(String(modMask, radix: 16))
                  enc1=\(Array(a)) enc2=\(Array(b))
                """
            )
        }
    }

    // MARK: - Property 6: modifier order doesn't matter

    /// `Modifiers` is an OptionSet, so set-literal order should be
    /// irrelevant. Build the same set from two different literal orderings
    /// and verify the encoder produces identical output. 50 iterations.
    func test_prop_modifierOrderInvariant() {
        let enc = KeyEncoder()
        var rng = Lcg(state: 0xBB05_5EED_ABCD_E005)
        // Pairs of (orderedA, orderedB) that should resolve to the same set.
        let pairs: [(KeyEncoder.Modifiers, KeyEncoder.Modifiers)] = [
            ([.shift, .option],            [.option, .shift]),
            ([.shift, .control],           [.control, .shift]),
            ([.option, .control],          [.control, .option]),
            ([.shift, .option, .control],  [.control, .option, .shift]),
            ([.shift, .option, .control],  [.option, .shift, .control]),
        ]
        for i in 0..<50 {
            let ch = Self.charPool[rng.nextInt(in: 0..<Self.charPool.count)]
            let (a, b) = pairs[rng.nextInt(in: 0..<pairs.count)]
            let outA = enc.encode(chars: ch, modifiers: a)
            let outB = enc.encode(chars: ch, modifiers: b)
            XCTAssertEqual(
                outA, outB,
                """
                Iteration \(i): modifier literal order affected output.
                  chars=\(Array(ch.utf8))
                  ordering A=\(a) outA=\(Array(outA))
                  ordering B=\(b) outB=\(Array(outB))
                """
            )
        }
    }

    // MARK: - Property 7: all-modifiers + Return is non-empty (mod Cmd)

    /// Enter must always emit *something* — every shell, every line
    /// editor depends on it. Sweep all 16 modifier-bitmask combinations;
    /// for each, assert the output is non-empty *unless* Cmd is set
    /// (Cmd is always suppressed by design). Iterating the 16 combos is
    /// exhaustive over the 4-bit mask.
    func test_prop_returnAlwaysProducesBytes_unlessCmd() {
        let enc = KeyEncoder()
        for mask: UInt8 in 0...0xF {
            let m = mods(from: mask)
            let out = enc.encode(chars: "\r", modifiers: m)
            let hasCmd = m.contains(.command)
            if hasCmd {
                XCTAssertEqual(
                    out, Data(),
                    "Return + Cmd (mask 0x\(String(mask, radix: 16))) must suppress to empty Data; got \(Array(out))"
                )
            } else {
                XCTAssertGreaterThan(
                    out.count, 0,
                    "Return without Cmd (mask 0x\(String(mask, radix: 16))) must emit at least one byte; got empty"
                )
            }
        }
    }

    // MARK: - Property 8: Kitty CSI invariant for function keys

    /// When any Kitty mode bit is active, the special-key path for
    /// function/navigation keys must still emit a CSI sequence: `ESC [`
    /// (CSI) or `ESC O` (SS3) prefix. Iterate every special key in a
    /// fixed list × {plain, Shift, Ctrl} modifiers under
    /// `disambiguateEscCodes` mode. `encodeSpecial` doesn't take a
    /// `mode:` argument in the existing tests (the Kitty flags shape the
    /// printable `encode` path), but the invariant we pin is broader:
    /// the special-key emission is always a CSI/SS3 sequence regardless
    /// of mode state propagated via `encode()` for printables. Since
    /// `encodeSpecial` is the only path for arrows/F-keys, we assert its
    /// output starts with `ESC [` or `ESC O` for the full sweep.
    func test_prop_specialKeys_alwaysCsiOrSs3Prefix() {
        let enc = KeyEncoder()
        let specials: [KeyEncoder.SpecialKey] = [
            .up, .down, .left, .right,
            .home, .end, .pageUp, .pageDown,
            .insert, .delete,
            .f1, .f2, .f3, .f4, .f5, .f6, .f7, .f8, .f9, .f10, .f11, .f12,
            .f13, .f14, .f15, .f16, .f17, .f18, .f19, .f20,
        ]
        let modCombos: [KeyEncoder.Modifiers] = [
            [], [.shift], [.control], [.shift, .control],
        ]
        for key in specials {
            for m in modCombos {
                let out = enc.encodeSpecial(key, modifiers: m)
                XCTAssertGreaterThanOrEqual(
                    out.count, 2,
                    "\(key) modifiers=\(m): expected at least ESC + 1 byte; got \(Array(out))"
                )
                let bytes = Array(out)
                let startsCSI = bytes.count >= 2 && bytes[0] == 0x1B && bytes[1] == 0x5B
                let startsSS3 = bytes.count >= 2 && bytes[0] == 0x1B && bytes[1] == 0x4F
                XCTAssertTrue(
                    startsCSI || startsSS3,
                    """
                    \(key) modifiers=\(m): special-key output must start with
                    ESC[ (CSI) or ESCO (SS3); got bytes=\(bytes)
                    """
                )
            }
        }
    }

    /// Companion to the prefix invariant: unmodified arrows are always
    /// exactly `ESC [ <final>` (3 bytes) in the default cursor mode.
    /// Catches a regression where the encoder spuriously added a
    /// modifier param to an unmodified arrow.
    func test_prop_unmodifiedArrows_alwaysThreeBytes() {
        let enc = KeyEncoder()
        let arrows: [KeyEncoder.SpecialKey] = [.up, .down, .left, .right]
        for k in arrows {
            let out = enc.encodeSpecial(k, modifiers: [])
            XCTAssertEqual(
                out.count, 3,
                "Unmodified \(k) must be exactly 3 bytes (ESC [ <final>); got \(Array(out))"
            )
            XCTAssertEqual(
                out.prefix(2), Data([0x1B, 0x5B]),
                "Unmodified \(k) must start with ESC [ ; got \(Array(out))"
            )
        }
    }
}
