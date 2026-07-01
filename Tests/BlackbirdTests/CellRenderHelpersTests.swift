import XCTest
import simd
@testable import Blackbird
import BBCore

/// GPU-free unit tests for the two pure static helpers on
/// `CellInstanceBuilder`: `attributeBits` (cell flags + hover state → the shader's
/// `SIMD4<UInt32>` attribute lane bundle) and `resolveColors` (cell fg/bg +
/// reverse/dim/opacity → resolved fg/bg/`hasBg`). Both are `static func`s
/// reachable via `@testable` with no `MTLDevice`, so every test here runs
/// (never skip-gated) on any host.
///
/// Authored blind against the contract: the expected values are recomputed
/// from the documented behaviour, not copied from the implementations of
/// `attributeBits` / `resolveColors`.
final class CellRenderHelpersTests: XCTestCase {

    // MARK: - Fixtures / expected-value recomputation

    /// Build a `BBCell` with sane defaults; the C-imported memberwise init
    /// order is `ch, fg, bg, flags, link_id, underline_color`.
    private func makeCell(
        ch: UInt32 = 0x41,            // 'A'
        fg: UInt32 = 0x00FF_FFFF,
        bg: UInt32 = 0x0000_0000,
        flags: UInt16 = 0,
        linkID: UInt16 = 0,
        underlineColor: UInt32 = UInt32.max  // UNDERLINE_COLOR_UNSET sentinel
    ) -> BBCell {
        BBCell(ch: ch, fg: fg, bg: bg, flags: flags,
               link_id: linkID, underline_color: underlineColor)
    }

    /// Mirrors `CellInstanceBuilder.rgbToSIMD` (which is `private`, so not reachable
    /// via `@testable`): unpack `0x00RRGGBB`, each byte / 255, alpha = 1.0.
    private func expectedRGB(_ rgb: UInt32) -> SIMD4<Float> {
        let inv: Float = 1.0 / 255.0
        return SIMD4<Float>(
            Float((rgb >> 16) & 0xFF) * inv,
            Float((rgb >> 8) & 0xFF) * inv,
            Float(rgb & 0xFF) * inv,
            1.0
        )
    }

    /// DIM halves the rgb lanes, leaving alpha untouched.
    private func dimmed(_ v: SIMD4<Float>) -> SIMD4<Float> {
        SIMD4<Float>(v.x * 0.5, v.y * 0.5, v.z * 0.5, v.w)
    }

    /// OR the raw values of a set of attribute masks.
    private func bits(_ masks: CellAttributeMask...) -> UInt32 {
        masks.reduce(UInt32(0)) { $0 | $1.rawValue }
    }

    private func assertSIMDEqual(
        _ actual: SIMD4<Float>, _ expected: SIMD4<Float>,
        accuracy: Float = 1e-6, _ message: String = "",
        file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertEqual(actual.x, expected.x, accuracy: accuracy, "x lane: \(message)", file: file, line: line)
        XCTAssertEqual(actual.y, expected.y, accuracy: accuracy, "y lane: \(message)", file: file, line: line)
        XCTAssertEqual(actual.z, expected.z, accuracy: accuracy, "z lane: \(message)", file: file, line: line)
        XCTAssertEqual(actual.w, expected.w, accuracy: accuracy, "w lane: \(message)", file: file, line: line)
    }

    /// Convenience: invoke `attributeBits` with all-quiet hover state unless
    /// overridden, so each test perturbs exactly one axis.
    private func attrBits(
        _ cell: BBCell,
        hoveredLinkID: UInt16 = 0,
        cmdHoverActiveOnRow: Bool = false,
        cmdHoverStartCol: Int32 = 0,
        cmdHoverEndCol: Int32 = 0,
        col: Int = 0
    ) -> SIMD4<UInt32> {
        CellInstanceBuilder.attributeBits(
            cell: cell,
            hoveredLinkID: hoveredLinkID,
            cmdHoverActiveOnRow: cmdHoverActiveOnRow,
            cmdHoverStartCol: cmdHoverStartCol,
            cmdHoverEndCol: cmdHoverEndCol,
            col: col
        )
    }

    // MARK: - attributeBits: structural lanes

    func test_attributeBits_plainCell_isAllZeroFlags_andForwardsUnderlineColor() {
        let cell = makeCell(flags: 0, underlineColor: 0x00AB_CDEF)
        let r = attrBits(cell)
        XCTAssertEqual(r.x, 0, "plain cell with no flags or hover must produce an empty attribute bitset")
        XCTAssertEqual(r.y, 0, "y lane is contractually always 0")
        XCTAssertEqual(r.z, 0x00AB_CDEF, "z lane must forward cell.underline_color verbatim")
        XCTAssertEqual(r.w, 0, "w lane is contractually always 0")
    }

    func test_attributeBits_underlineColorForwarded_independentOfFlags() {
        // z lane carries underline_color regardless of which flags are set.
        for color: UInt32 in [0x0000_0000, 0x0012_3456, 0x00FF_FFFF, UInt32.max] {
            let cell = makeCell(flags: UInt16(UNDERLINE), underlineColor: color)
            XCTAssertEqual(attrBits(cell).z, color,
                           "z lane must equal underline_color (\(String(color, radix: 16)))")
        }
    }

    // MARK: - attributeBits: link hover

    func test_attributeBits_linkHover_setWhenHoveredIdMatchesCellLinkId() {
        let cell = makeCell(linkID: 7)
        let r = attrBits(cell, hoveredLinkID: 7)
        XCTAssertEqual(r.x, bits(.linkHover),
                       "matching non-zero hovered link id must set exactly the linkHover bit")
    }

    func test_attributeBits_linkHover_clearWhenHoveredIdMismatches() {
        let cell = makeCell(linkID: 3)
        XCTAssertEqual(attrBits(cell, hoveredLinkID: 7).x, 0,
                       "mismatched hovered link id must not set linkHover")
    }

    func test_attributeBits_linkHover_clearWhenHoveredIdZero_evenIfCellLinkIdZero() {
        // hoveredLinkID == 0 is the "nothing hovered" sentinel; a cell whose
        // link_id is also 0 must NOT light up just because 0 == 0.
        let cell = makeCell(linkID: 0)
        XCTAssertEqual(attrBits(cell, hoveredLinkID: 0).x, 0,
                       "hoveredLinkID == 0 must never set linkHover, even for link_id == 0")
    }

    func test_attributeBits_linkHover_clearWhenHoveredIdZero_andCellHasLink() {
        let cell = makeCell(linkID: 9)
        XCTAssertEqual(attrBits(cell, hoveredLinkID: 0).x, 0,
                       "hoveredLinkID == 0 must never set linkHover")
    }

    // MARK: - attributeBits: command (prompt) hover range

    func test_attributeBits_cmdHover_setWhenColInRangeInclusive() {
        let cell = makeCell()
        // Range [2, 5] inclusive on both ends.
        for col in 2...5 {
            let r = attrBits(cell, cmdHoverActiveOnRow: true,
                             cmdHoverStartCol: 2, cmdHoverEndCol: 5, col: col)
            XCTAssertEqual(r.x, bits(.linkHover),
                           "col \(col) inside [2,5] must set linkHover")
        }
    }

    func test_attributeBits_cmdHover_clearWhenColOutOfRange() {
        let cell = makeCell()
        for col in [-1, 0, 1, 6, 7, 100] {
            let r = attrBits(cell, cmdHoverActiveOnRow: true,
                             cmdHoverStartCol: 2, cmdHoverEndCol: 5, col: col)
            XCTAssertEqual(r.x, 0, "col \(col) outside [2,5] must not set linkHover")
        }
    }

    func test_attributeBits_cmdHover_clearWhenRowInactive_evenIfColInRange() {
        let cell = makeCell()
        let r = attrBits(cell, cmdHoverActiveOnRow: false,
                         cmdHoverStartCol: 2, cmdHoverEndCol: 5, col: 3)
        XCTAssertEqual(r.x, 0,
                       "cmdHoverActiveOnRow == false must suppress linkHover regardless of column")
    }

    // MARK: - attributeBits: per-flag bit mapping

    func test_attributeBits_eachStyleFlagMapsToExactlyOneBit() {
        let cases: [(UInt16, CellAttributeMask, String)] = [
            (UInt16(STRIKE), .strike, "STRIKE"),
            (UInt16(UNDERLINE), .underline, "UNDERLINE"),
            (UInt16(UNDERLINE_DOUBLE), .underlineDouble, "UNDERLINE_DOUBLE"),
            (UInt16(UNDERCURL), .undercurl, "UNDERCURL"),
            (UInt16(UNDERLINE_DOTTED), .underlineDotted, "UNDERLINE_DOTTED"),
            (UInt16(UNDERLINE_DASHED), .underlineDashed, "UNDERLINE_DASHED"),
        ]
        for (flag, mask, name) in cases {
            let cell = makeCell(flags: flag, underlineColor: 0x0011_2233)
            let r = attrBits(cell)
            XCTAssertEqual(r.x, mask.rawValue,
                           "\(name) must map to exactly its single attribute bit")
            XCTAssertEqual(r.y, 0, "\(name): y lane stays 0")
            XCTAssertEqual(r.z, 0x0011_2233, "\(name): z lane forwards underline_color")
            XCTAssertEqual(r.w, 0, "\(name): w lane stays 0")
        }
    }

    func test_attributeBits_unrelatedFlagsDoNotSetStyleBits() {
        // BOLD / ITALIC / WIDE_CHAR are real BBCell flags that attributeBits
        // does not translate into the shader attribute lane.
        let cell = makeCell(flags: UInt16(BOLD) | UInt16(ITALIC) | UInt16(WIDE_CHAR))
        XCTAssertEqual(attrBits(cell).x, 0,
                       "bold/italic/wide flags carry no attribute-lane bit")
    }

    func test_attributeBits_combinedFlagsAndHover_orTogether() {
        let cell = makeCell(flags: UInt16(UNDERLINE) | UInt16(STRIKE), linkID: 4)
        // link hover via matching id + the two style flags should all OR in.
        let r = attrBits(cell, hoveredLinkID: 4)
        XCTAssertEqual(r.x, bits(.linkHover, .underline, .strike),
                       "underline + strike + link hover must OR into a single bitset")
    }

    func test_attributeBits_combinedUnderlineStyles_orTogether_viaCmdHover() {
        let cell = makeCell(flags: UInt16(UNDERLINE_DOUBLE) | UInt16(UNDERLINE_DASHED))
        let r = attrBits(cell, cmdHoverActiveOnRow: true,
                         cmdHoverStartCol: 0, cmdHoverEndCol: 10, col: 5)
        XCTAssertEqual(r.x, bits(.linkHover, .underlineDouble, .underlineDashed),
                       "cmd-hover linkHover must OR with multiple underline-style bits")
    }

    // MARK: - resolveColors: alpha / hasBg rules

    func test_resolveColors_defaultBg_isTransparent_andNoQuad_evenWhenKeepOpaque() {
        // cell.bg == defaultBg, not reversed → bg alpha forced to 0 and no quad,
        // overriding keepBgOpaque.
        let cell = makeCell(fg: 0x00FF_8040, bg: 0x0010_1010)
        let out = CellInstanceBuilder.resolveColors(
            cell: cell, defaultBg: 0x0010_1010,
            keepBgOpaque: true, backgroundOpacity: 0.5)
        XCTAssertFalse(out.hasBg, "default-bg cell must not paint a background quad")
        assertSIMDEqual(out.fg, expectedRGB(0x00FF_8040), "fg unchanged for plain cell")
        var expectedBg = expectedRGB(0x0010_1010)
        expectedBg.w = 0.0
        assertSIMDEqual(out.bg, expectedBg, "default bg alpha must be 0 regardless of keepBgOpaque")
    }

    func test_resolveColors_explicitBg_keepOpaque_alphaOne() {
        let cell = makeCell(fg: 0x00FF_FFFF, bg: 0x0020_4060)
        let out = CellInstanceBuilder.resolveColors(
            cell: cell, defaultBg: 0x0000_0000,
            keepBgOpaque: true, backgroundOpacity: 0.5)
        XCTAssertTrue(out.hasBg, "explicit non-default bg must paint a quad")
        XCTAssertEqual(out.bg.w, 1.0, accuracy: 1e-6, "keepBgOpaque must force bg alpha to 1.0")
        var expectedBg = expectedRGB(0x0020_4060)
        expectedBg.w = 1.0
        assertSIMDEqual(out.bg, expectedBg, "bg rgb from cell.bg, alpha 1.0")
        assertSIMDEqual(out.fg, expectedRGB(0x00FF_FFFF), "fg from cell.fg")
    }

    func test_resolveColors_explicitBg_notOpaque_usesBackgroundOpacity() {
        let cell = makeCell(fg: 0x00FF_FFFF, bg: 0x0020_4060)
        let opacity: Float = 0.35
        let out = CellInstanceBuilder.resolveColors(
            cell: cell, defaultBg: 0x0000_0000,
            keepBgOpaque: false, backgroundOpacity: opacity)
        XCTAssertTrue(out.hasBg, "explicit non-default bg must paint a quad")
        XCTAssertEqual(out.bg.w, opacity, accuracy: 1e-6,
                       "non-opaque explicit bg must use backgroundOpacity for alpha")
    }

    // MARK: - resolveColors: reverse + dim

    func test_resolveColors_reverse_swapsFgAndBg_andForcesQuad() {
        // cell.bg == defaultBg, but REVERSE must still paint a quad and swap.
        let cell = makeCell(fg: 0x0010_2030, bg: 0x0000_0000, flags: UInt16(REVERSE))
        let out = CellInstanceBuilder.resolveColors(
            cell: cell, defaultBg: 0x0000_0000,
            keepBgOpaque: true, backgroundOpacity: 0.5)
        XCTAssertTrue(out.hasBg, "reverse must force a background quad even when cell.bg == defaultBg")
        // fg now holds the original bg colour; bg now holds the original fg.
        assertSIMDEqual(out.fg, expectedRGB(0x0000_0000), "reverse: fg becomes original bg")
        var expectedBg = expectedRGB(0x0010_2030)
        expectedBg.w = 1.0  // not (!reverse && bg==default) → keepBgOpaque path
        assertSIMDEqual(out.bg, expectedBg, "reverse: bg becomes original fg, alpha 1.0")
    }

    func test_resolveColors_dim_halvesFg_leavesAlpha() {
        let cell = makeCell(fg: 0x0080_4020, bg: 0x0000_0000, flags: UInt16(DIM))
        let out = CellInstanceBuilder.resolveColors(
            cell: cell, defaultBg: 0x0000_0000,
            keepBgOpaque: true, backgroundOpacity: 0.5)
        let expectedFg = dimmed(expectedRGB(0x0080_4020))
        assertSIMDEqual(out.fg, expectedFg, "DIM must halve fg rgb and leave alpha at 1.0")
        XCTAssertEqual(out.fg.w, 1.0, accuracy: 1e-6, "DIM must not touch the fg alpha lane")
    }

    func test_resolveColors_dimAppliedAfterReverse() {
        // DIM + REVERSE: the dim halving must hit the post-swap fg, which
        // originates from cell.bg.
        let cell = makeCell(fg: 0x00FF_FFFF, bg: 0x0080_8080,
                            flags: UInt16(REVERSE) | UInt16(DIM))
        let out = CellInstanceBuilder.resolveColors(
            cell: cell, defaultBg: 0x0000_0000,
            keepBgOpaque: true, backgroundOpacity: 0.5)
        // fg = dim(rgb(cell.bg)); proves dim runs AFTER the reverse swap.
        assertSIMDEqual(out.fg, dimmed(expectedRGB(0x0080_8080)),
                        "dim must apply to the reversed fg (sourced from cell.bg)")
        var expectedBg = expectedRGB(0x00FF_FFFF)
        expectedBg.w = 1.0
        assertSIMDEqual(out.bg, expectedBg, "reverse: bg becomes original fg (undimmed), alpha 1.0")
        XCTAssertTrue(out.hasBg, "reverse forces a quad")
    }

    // MARK: - resolveColors: orthogonality to attribute-only fields

    func test_resolveColors_underlineColorAndStyleFlags_doNotAffectColours() {
        let plain = makeCell(fg: 0x00AA_5500, bg: 0x0022_3344,
                             flags: 0, underlineColor: UInt32.max)
        let styled = makeCell(fg: 0x00AA_5500, bg: 0x0022_3344,
                              flags: UInt16(UNDERLINE) | UInt16(STRIKE),
                              underlineColor: 0x00DE_AD12)
        let a = CellInstanceBuilder.resolveColors(
            cell: plain, defaultBg: 0x0000_0000,
            keepBgOpaque: false, backgroundOpacity: 0.4)
        let b = CellInstanceBuilder.resolveColors(
            cell: styled, defaultBg: 0x0000_0000,
            keepBgOpaque: false, backgroundOpacity: 0.4)
        assertSIMDEqual(a.fg, b.fg, "underline/strike flags must not change fg")
        assertSIMDEqual(a.bg, b.bg, "underline/strike flags + underline_color must not change bg")
        XCTAssertEqual(a.hasBg, b.hasBg, "style flags must not change hasBg")
    }
}
