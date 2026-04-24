import XCTest
import simd
@testable import Blackbird

/// Pin the data-structure invariants of `CellInstance` and
/// `CellAttributeMask` against the wire-level contract documented in
/// `Sources/Renderer/Shaders.metal`. The shader's `CellInstance`
/// declaration is the public interface — every field offset, every
/// attribute bit, and the 80-byte stride live in BOTH places. A drift
/// in either side that escaped a code review would surface as
/// UV-scrambled glyphs or "random cells draw solid black" at runtime.
///
/// **Why this file exists** (F-S4-001 audit finding, v0.1.9 sweep): the
/// in-source `_cellInstanceLayoutPinned` constant is gated by
/// `assert(...)` calls and is reachable only via `_pinCellInstanceLayout()`,
/// which has zero call sites in `Sources/` or `Tests/`. The asserts
/// therefore never execute, and even if they did, `assert` is stripped
/// in `-O` release builds. This test file is the belt-and-braces
/// contract pin: it runs the same checks `_cellInstanceLayoutPinned`
/// nominally enforces, plus per-bit attribute pins the in-source
/// asserts do not cover.
///
/// **Why no Metal device:** every assertion in this file is on Swift
/// memory layout / bit values. None requires a GPU. The tests therefore
/// run on every CI runner, including ones without a GPU, with no
/// XCTSkip path needed.
///
/// **Memory pre-flight** (per MEMORY `feedback_test_memory_safety`):
/// the entire suite allocates one `CellInstance` instance per test
/// (~80 bytes), zero textures, and never constructs a renderer. Total
/// ≪ 1 KiB — well under the 256 MB budget enforced by
/// `requireTestFitsInBudget`.
final class CellInstanceLayoutTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        TestHostTermination.shared.register()
    }

    // MARK: - Stride / alignment contract

    /// `MemoryLayout<CellInstance>.stride` must be exactly 80 bytes.
    /// The shader's `CellInstance` struct in Shaders.metal:4-12 is
    /// 4× `float2` (8 B each = 32 B) + 2× `float4` (16 B each = 32 B)
    /// + 1× `uint4` (16 B) = 80 B. Metal vertex pulling reads
    /// `instances[iid]` at this stride; a Swift-side widening or
    /// packing change that doesn't update the shader struct would
    /// cause the GPU to re-interpret every byte from instance 1
    /// onwards as garbage UVs / colors.
    ///
    /// If this fails after a deliberate field change: update
    /// Shaders.metal's mirror struct in lockstep, then update this
    /// expected value. Both sides MUST be touched in the same commit.
    func test_stride_isEightyBytes() {
        XCTAssertEqual(
            MemoryLayout<CellInstance>.stride, 80,
            "CellInstance stride drifted from the 80-byte contract "
            + "mirrored in Shaders.metal — update the shader struct "
            + "BEFORE widening this value."
        )
    }

    /// `MemoryLayout<CellInstance>.alignment` must equal 16 bytes,
    /// matching Metal's natural alignment for `SIMD4<Float>` /
    /// `SIMD4<UInt32>`. A Swift-side change that ever produced a
    /// CellInstance with smaller alignment (e.g. by replacing a
    /// `SIMD4` field with two `SIMD2`s) would cause Metal's vertex
    /// pull to mis-align reads on architectures where the compiler
    /// assumed 16-byte alignment for the buffer's start address.
    func test_alignment_is16Bytes() {
        XCTAssertEqual(
            MemoryLayout<CellInstance>.alignment, 16,
            "CellInstance alignment must match Metal's natural 16-byte "
            + "alignment for SIMD4 types."
        )
    }

    /// `size` and `stride` should agree for `CellInstance` — there is
    /// no expected trailing padding because `attrs: SIMD4<UInt32>` is
    /// already a 16-byte aligned, 16-byte sized field. If a future
    /// field reorder produces an internal padding gap, `size <
    /// stride` and Metal's `setVertexBytes` callers (or any
    /// `MemoryLayout<CellInstance>.size` user) would silently truncate
    /// the buffer payload.
    func test_size_matchesStride() {
        XCTAssertEqual(
            MemoryLayout<CellInstance>.size, MemoryLayout<CellInstance>.stride,
            "CellInstance has unexpected trailing padding — every field "
            + "should be naturally aligned and the struct should be "
            + "pad-free at the tail."
        )
    }

    // MARK: - Field offsets / order

    /// Pin every field's byte offset against the shader's expected
    /// layout. The Metal vertex shader at Shaders.metal:32-67 reads
    /// `instances[iid].cellPosPx`, `.quadSizePx`, etc., relying on
    /// the field order declared at Shaders.metal:4-12. A Swift-side
    /// reorder that the shader doesn't mirror would cause
    /// `cellPosPx` reads to land in the `quadSizePx` slot and so on
    /// down the struct, producing scrambled positions and UVs.
    ///
    /// Expected layout (cumulative):
    ///   - cellPosPx:   offset  0, size  8 (SIMD2<Float>)
    ///   - quadSizePx:  offset  8, size  8 (SIMD2<Float>)
    ///   - uvOrigin:    offset 16, size  8 (SIMD2<Float>)
    ///   - uvSize:      offset 24, size  8 (SIMD2<Float>)
    ///   - fgColor:     offset 32, size 16 (SIMD4<Float>)
    ///   - bgColor:     offset 48, size 16 (SIMD4<Float>)
    ///   - attrs:       offset 64, size 16 (SIMD4<UInt32>)
    ///   - total stride 80
    func test_fieldOffsets_matchShaderLayout() {
        XCTAssertEqual(MemoryLayout.offset(of: \CellInstance.cellPosPx),  0,
                       "cellPosPx must be the first field at offset 0")
        XCTAssertEqual(MemoryLayout.offset(of: \CellInstance.quadSizePx), 8,
                       "quadSizePx must immediately follow cellPosPx (offset 8)")
        XCTAssertEqual(MemoryLayout.offset(of: \CellInstance.uvOrigin),  16,
                       "uvOrigin must follow quadSizePx (offset 16)")
        XCTAssertEqual(MemoryLayout.offset(of: \CellInstance.uvSize),    24,
                       "uvSize must follow uvOrigin (offset 24)")
        XCTAssertEqual(MemoryLayout.offset(of: \CellInstance.fgColor),   32,
                       "fgColor must follow uvSize (offset 32)")
        XCTAssertEqual(MemoryLayout.offset(of: \CellInstance.bgColor),   48,
                       "bgColor must follow fgColor (offset 48)")
        XCTAssertEqual(MemoryLayout.offset(of: \CellInstance.attrs),     64,
                       "attrs must be last, at offset 64 (16 bytes wide)")
    }

    /// Each field's stride must match the SIMD type's natural size.
    /// A Swift-side reduction (e.g. a hypothetical `SIMD3<Float>`
    /// substitution that compiled but rounded to 12 bytes) would
    /// shift every following field's offset and break the shader's
    /// vertex pull.
    func test_fieldStrides_matchSimdTypes() {
        XCTAssertEqual(MemoryLayout<SIMD2<Float>>.stride,   8)
        XCTAssertEqual(MemoryLayout<SIMD4<Float>>.stride,  16)
        XCTAssertEqual(MemoryLayout<SIMD4<UInt32>>.stride, 16)
    }

    // MARK: - CellAttributeMask bit assignments
    //
    // The shader (Shaders.metal:71-85) declares `BB_ATTR_*` constants
    // by raw bit value, NOT by referencing `CellAttributeMask`. The
    // Swift OptionSet is the source of truth, but the shader's named
    // constants must mirror the same bit positions exactly. A Swift-
    // side renumbering would silently rebrand the shader's behaviour:
    // the renamed bit lights `BB_ATTR_LINK_HOVER` instead of
    // `BB_ATTR_STRIKE`, etc.
    //
    // These tests pin each bit by raw integer value. If a refactor
    // ever needs to renumber, the shader constants in Shaders.metal
    // MUST be updated in the same commit to match.

    func test_attrBit_linkHover_isBitZero() {
        XCTAssertEqual(
            CellAttributeMask.linkHover.rawValue, UInt32(1) << 0,
            "linkHover must occupy bit 0 — shader uses `BB_ATTR_LINK_HOVER = 1u << 0`"
        )
    }

    func test_attrBit_strike_isBitOne() {
        XCTAssertEqual(
            CellAttributeMask.strike.rawValue, UInt32(1) << 1,
            "strike must occupy bit 1 — shader uses `BB_ATTR_STRIKE = 1u << 1`"
        )
    }

    func test_attrBit_underline_isBitTwo() {
        XCTAssertEqual(
            CellAttributeMask.underline.rawValue, UInt32(1) << 2,
            "underline must occupy bit 2 — shader uses `BB_ATTR_UNDERLINE = 1u << 2`"
        )
    }

    func test_attrBit_underlineDouble_isBitThree() {
        XCTAssertEqual(
            CellAttributeMask.underlineDouble.rawValue, UInt32(1) << 3,
            "underlineDouble must occupy bit 3 — shader uses `BB_ATTR_UNDERLINE_DOUBLE = 1u << 3`"
        )
    }

    func test_attrBit_undercurl_isBitFour() {
        XCTAssertEqual(
            CellAttributeMask.undercurl.rawValue, UInt32(1) << 4,
            "undercurl must occupy bit 4 — shader uses `BB_ATTR_UNDERCURL = 1u << 4`"
        )
    }

    func test_attrBit_underlineDotted_isBitFive() {
        XCTAssertEqual(
            CellAttributeMask.underlineDotted.rawValue, UInt32(1) << 5,
            "underlineDotted must occupy bit 5 — shader uses `BB_ATTR_UNDERLINE_DOTTED = 1u << 5`"
        )
    }

    func test_attrBit_underlineDashed_isBitSix() {
        XCTAssertEqual(
            CellAttributeMask.underlineDashed.rawValue, UInt32(1) << 6,
            "underlineDashed must occupy bit 6 — shader uses `BB_ATTR_UNDERLINE_DASHED = 1u << 6`"
        )
    }

    /// Regression for the v0.1.9 color-emoji bit (audit reference:
    /// the existing `test_isColorGlyphBitHasExpectedValue` in
    /// GlyphAtlasTests pins this once. We pin it again here in the
    /// CellInstance contract suite because the shader at
    /// Shaders.metal:80, 107 reads this exact bit by raw value to
    /// branch onto the color-atlas sampling path. A regression that
    /// renumbered this bit would route every emoji through the mono
    /// path → grey silhouettes (the very bug that motivated the fix
    /// in commit ab89b64).
    func test_attrBit_isColorGlyph_isBitSeven() {
        XCTAssertEqual(
            CellAttributeMask.isColorGlyph.rawValue, UInt32(1) << 7,
            "isColorGlyph must occupy bit 7 — shader uses `BB_ATTR_IS_COLOR_GLYPH = 1u << 7`. "
            + "If this regresses, every emoji renders as a gray silhouette in production."
        )
    }

    /// `anyUnderline` is the OR of the five underline-style bits.
    /// The shader at Shaders.metal:81-85 mirrors this composition as
    /// `BB_ATTR_ANY_UNDERLINE = BB_ATTR_UNDERLINE | …`. A Swift-side
    /// addition (e.g. a future SGR 4:6 “triple underline”) that
    /// updated the OptionSet but not the shader would short-circuit
    /// the underline branch on the new bit and silently skip the
    /// paint.
    func test_attrBit_anyUnderline_isUnionOfFiveStyles() {
        let expected: UInt32 =
            (1 << 2) |  // underline
            (1 << 3) |  // underlineDouble
            (1 << 4) |  // undercurl
            (1 << 5) |  // underlineDotted
            (1 << 6)    // underlineDashed
        XCTAssertEqual(
            CellAttributeMask.anyUnderline.rawValue, expected,
            "anyUnderline must equal the OR of all five underline-style bits — "
            + "shader uses `BB_ATTR_ANY_UNDERLINE` to short-circuit the underline composite."
        )
        // anyUnderline must NOT include linkHover, strike, or isColorGlyph
        // (link-hover is a separate accent path; strike and isColorGlyph
        // are not underline styles).
        XCTAssertFalse(
            CellAttributeMask.anyUnderline.contains(.linkHover),
            "linkHover must not be in anyUnderline — it's a separate accent path"
        )
        XCTAssertFalse(
            CellAttributeMask.anyUnderline.contains(.strike),
            "strike must not be in anyUnderline — it's a horizontal mid-band, not an underline"
        )
        XCTAssertFalse(
            CellAttributeMask.anyUnderline.contains(.isColorGlyph),
            "isColorGlyph must not be in anyUnderline — it's an atlas-routing flag"
        )
    }

    /// The eight defined render-state bits must all live in the
    /// low byte (bits 0-7). The struct header at CellInstance.swift:11
    /// reserves bits 8-31 for future per-cell data (e.g. underline-color
    /// indices). A regression that placed a new render-state bit at
    /// position ≥ 8 would either collide with future use or get masked
    /// by a future shader change that explicitly only reads
    /// `attrs.x & 0xFF`.
    func test_attrBits_allFitInLowByte() {
        let allKnown: CellAttributeMask = [
            .linkHover,
            .strike,
            .underline,
            .underlineDouble,
            .undercurl,
            .underlineDotted,
            .underlineDashed,
            .isColorGlyph,
        ]
        XCTAssertEqual(
            allKnown.rawValue & 0xFFFF_FF00, 0,
            "every defined render-state bit must live in the low byte (bits 0-7); "
            + "bits 8-31 are reserved for future per-cell data per the struct header"
        )
        // And the union covers exactly bits 0-7.
        XCTAssertEqual(
            allKnown.rawValue, 0xFF,
            "the eight defined bits must cover bits 0-7 contiguously — "
            + "a hole would mean a missing case here, an extra bit would mean a contract drift"
        )
    }

    /// All bits must be unique — no two CellAttributeMask values
    /// share the same bit position. A regression that aliased two
    /// bits (e.g. `static let strike = CellAttributeMask(rawValue: 1
    /// << 2)` colliding with `.underline`) would silently fold both
    /// states into one shader branch.
    func test_attrBits_areAllDistinct() {
        let cases: [(String, CellAttributeMask)] = [
            ("linkHover",       .linkHover),
            ("strike",          .strike),
            ("underline",       .underline),
            ("underlineDouble", .underlineDouble),
            ("undercurl",       .undercurl),
            ("underlineDotted", .underlineDotted),
            ("underlineDashed", .underlineDashed),
            ("isColorGlyph",    .isColorGlyph),
        ]
        var seen: [UInt32: String] = [:]
        for (name, mask) in cases {
            if let collidingName = seen[mask.rawValue] {
                XCTFail(
                    "\(name) shares bit \(String(mask.rawValue, radix: 2)) with "
                    + "\(collidingName) — every CellAttributeMask must occupy a unique bit"
                )
            } else {
                seen[mask.rawValue] = name
            }
        }
        XCTAssertEqual(seen.count, cases.count, "expected \(cases.count) unique bits")
    }

    // MARK: - attrs.x packing — round-trip a CellInstance through the bit channel
    //
    // The shader at Shaders.metal:62-63 reads `out.flags = inst.attrs.x`
    // and `out.underlineColorPacked = inst.attrs.z` — i.e., the attrs
    // SIMD4 is laid out as { .x = flagBitmask, .y = reserved, .z =
    // packed-underline-color, .w = reserved }. These tests construct
    // a CellInstance with each bit set in `.x`, then verify the
    // round-trip via the SIMD4 element accessor. They don't run the
    // shader (we can't from xctest without a Metal device + drawable),
    // but they DO catch a Swift-side bug that wrote the bit into the
    // wrong SIMD4 lane.

    /// Helper: build a minimal CellInstance with the given attrs bitmask
    /// in `.x` and zeros everywhere else. Production code never
    /// constructs CellInstance from outside MetalRenderer.buildInstances,
    /// but the struct is internal and exposed via @testable, so this
    /// is the contractually correct test surface.
    private func makeInstance(flags: UInt32, underlineColorPacked: UInt32 = 0) -> CellInstance {
        return CellInstance(
            cellPosPx:  SIMD2<Float>(0, 0),
            quadSizePx: SIMD2<Float>(8, 16),
            uvOrigin:   SIMD2<Float>(0, 0),
            uvSize:     SIMD2<Float>(0, 0),
            fgColor:    SIMD4<Float>(1, 1, 1, 1),
            bgColor:    SIMD4<Float>(0, 0, 0, 1),
            attrs:      SIMD4<UInt32>(flags, 0, underlineColorPacked, 0)
        )
    }

    func test_pack_linkHoverBit_landsInAttrsX() {
        let inst = makeInstance(flags: CellAttributeMask.linkHover.rawValue)
        XCTAssertEqual(inst.attrs.x & 0x1, 0x1,
                       "linkHover bit must be readable as `attrs.x & (1<<0)`")
        XCTAssertEqual(inst.attrs.x, 1,
                       "isolated linkHover must produce attrs.x == 1")
    }

    func test_pack_strikeBit_landsInAttrsX() {
        let inst = makeInstance(flags: CellAttributeMask.strike.rawValue)
        XCTAssertEqual(inst.attrs.x, 0b10,
                       "isolated strike must produce attrs.x == 0b10 (== 2)")
    }

    func test_pack_underlineBit_landsInAttrsX() {
        let inst = makeInstance(flags: CellAttributeMask.underline.rawValue)
        XCTAssertEqual(inst.attrs.x, 0b100, "isolated underline must produce attrs.x == 4")
    }

    func test_pack_underlineDoubleBit_landsInAttrsX() {
        let inst = makeInstance(flags: CellAttributeMask.underlineDouble.rawValue)
        XCTAssertEqual(inst.attrs.x, 0b1000, "isolated underlineDouble must produce attrs.x == 8")
    }

    func test_pack_undercurlBit_landsInAttrsX() {
        let inst = makeInstance(flags: CellAttributeMask.undercurl.rawValue)
        XCTAssertEqual(inst.attrs.x, 0b10000, "isolated undercurl must produce attrs.x == 16")
    }

    func test_pack_underlineDottedBit_landsInAttrsX() {
        let inst = makeInstance(flags: CellAttributeMask.underlineDotted.rawValue)
        XCTAssertEqual(inst.attrs.x, 0b100000, "isolated underlineDotted must produce attrs.x == 32")
    }

    func test_pack_underlineDashedBit_landsInAttrsX() {
        let inst = makeInstance(flags: CellAttributeMask.underlineDashed.rawValue)
        XCTAssertEqual(inst.attrs.x, 0b1000000, "isolated underlineDashed must produce attrs.x == 64")
    }

    func test_pack_isColorGlyphBit_landsInAttrsX() {
        let inst = makeInstance(flags: CellAttributeMask.isColorGlyph.rawValue)
        XCTAssertEqual(inst.attrs.x, 0b10000000,
                       "isolated isColorGlyph must produce attrs.x == 128 — "
                       + "shader branches on `(flags & BB_ATTR_IS_COLOR_GLYPH) != 0u`")
    }

    /// All eight bits set simultaneously must produce attrs.x = 0xFF.
    /// In practice the renderer never sets all eight (e.g. dotted +
    /// dashed are mutually exclusive at the parser level), but the
    /// shader's `BB_ATTR_ANY_UNDERLINE` check uses bitwise-and with
    /// independent flags, so a stuck-bits scenario must not crash or
    /// trigger UB.
    func test_pack_allBitsSet_producesLowByte() {
        let allBits: CellAttributeMask = [
            .linkHover, .strike, .underline, .underlineDouble,
            .undercurl, .underlineDotted, .underlineDashed, .isColorGlyph,
        ]
        let inst = makeInstance(flags: allBits.rawValue)
        XCTAssertEqual(inst.attrs.x, 0xFF,
                       "all eight bits set must produce attrs.x == 0xFF (255)")
        // `.y` and `.w` must remain zero — the struct header
        // documents these as "reserved (0)" and a regression that
        // bled flags into them would be the kind of silent corruption
        // the audit (glyph-atlas F8) flagged as catchable only by a
        // direct layout test.
        XCTAssertEqual(inst.attrs.y, 0, "attrs.y is reserved and must remain zero")
        XCTAssertEqual(inst.attrs.w, 0, "attrs.w is reserved and must remain zero")
    }

    // MARK: - attrs.z — packed CSI 58 underline color

    /// The struct header at CellInstance.swift:55-58 documents
    /// `attrs.z` as `0x00RRGGBB` for an explicit underline colour, or
    /// `0xFFFFFFFF` as the "fall back to fg" sentinel. The shader at
    /// Shaders.metal:151 unpacks via `if (in.underlineColorPacked !=
    /// 0xFFFFFFFFu)`. A regression that flipped the sentinel value
    /// (e.g. to 0 or 0x00000000) would either route every underline
    /// through the explicit-colour path (wasting cycles + producing
    /// solid-black underlines on cells with no SGR 58) or the
    /// fallback path (ignoring user-set colours).
    func test_underlineColorSentinel_isAllOnes() {
        let sentinel: UInt32 = 0xFFFF_FFFF
        let inst = makeInstance(flags: 0, underlineColorPacked: sentinel)
        XCTAssertEqual(inst.attrs.z, sentinel,
                       "0xFFFFFFFF sentinel must round-trip through attrs.z unchanged")
    }

    /// An explicit RGB colour packed as 0x00RRGGBB lands in `attrs.z`
    /// in exactly the same numeric form. The shader at
    /// Shaders.metal:152-155 unpacks
    ///   r = ((packed >> 16) & 0xFF) / 255
    ///   g = ((packed >>  8) & 0xFF) / 255
    ///   b = ((packed      ) & 0xFF) / 255
    /// — a Swift-side packing bug that swapped R and B (writing
    /// 0x00BBGGRR instead) would land here and the shader would
    /// produce blue underlines for red SGR 58s.
    func test_underlineColorPacking_RgbLayout() {
        // CSI 58:2:255:128:64 (orange-ish). Packed: 0x00FF8040.
        let packed: UInt32 = 0x00FF_8040
        let inst = makeInstance(flags: 0, underlineColorPacked: packed)
        XCTAssertEqual(inst.attrs.z, packed,
                       "RGB packing must round-trip through attrs.z unchanged")
        // Verify the shader's unpack arithmetic on the Swift side: R
        // is the high byte, B is the low byte. If a refactor ever
        // reverses the byte order, this test pins the contract.
        let r = (inst.attrs.z >> 16) & 0xFF
        let g = (inst.attrs.z >>  8) & 0xFF
        let b = (inst.attrs.z      ) & 0xFF
        XCTAssertEqual(r, 0xFF, "R byte must be at bits 16-23")
        XCTAssertEqual(g, 0x80, "G byte must be at bits 8-15")
        XCTAssertEqual(b, 0x40, "B byte must be at bits 0-7")
    }

    /// `attrs.z = 0` is a valid explicit colour (pure black). The
    /// shader treats `0 != 0xFFFFFFFF`, so this lands in the
    /// explicit-colour branch and produces a black underline. Pin
    /// this so a refactor that ever changed the sentinel to `0`
    /// would fail catastrophically (every cell would suddenly route
    /// through fallback).
    func test_underlineColorBlack_isExplicitNotSentinel() {
        let inst = makeInstance(flags: 0, underlineColorPacked: 0)
        XCTAssertEqual(inst.attrs.z, 0)
        XCTAssertNotEqual(inst.attrs.z, 0xFFFF_FFFF,
                          "the 'black explicit underline' value must NOT equal the sentinel — "
                          + "a regression that flipped them would invert every cell's behaviour")
    }

    // MARK: - F-S4-001: layout pin function exists and is callable
    //
    // The audit found that `_pinCellInstanceLayout()` is defined but
    // never called, so the asserts inside `_cellInstanceLayoutPinned`
    // are effectively dead code. We can't test that the asserts fire
    // (they would crash the test host on debug builds and silently
    // pass in release), but we CAN test that the function exists and
    // is callable — i.e., a future commit that deletes it (rather
    // than wiring it up) breaks compilation here, forcing the author
    // to confront the contract pin.
    //
    // The real fix per F-S4-001 is to convert `assert` → `precondition`
    // and call `_pinCellInstanceLayout()` from `MetalRenderer.init`.
    // This test is the third leg: a unit test that statically pins
    // the contract, so even if the precondition is also stripped or
    // the call site is forgotten, the layout invariants stay verified
    // every CI run.

    /// Calling `_pinCellInstanceLayout()` must not crash on a debug
    /// build (the in-source asserts pass at the current 80/16 layout)
    /// and must compile on a release build (the function is `@inline(never)`
    /// and is always present in the binary). This test pins the
    /// function's existence; the layout-stride / alignment tests above
    /// pin the actual values.
    func test_pinFunctionExists_andDoesNotCrash() {
        _pinCellInstanceLayout()
        // If the call returned, the asserts (if any fire) passed.
        // We assert true so the test has at least one observable
        // outcome and isn't a "vacuous pass".
        XCTAssertTrue(true)
    }
}
