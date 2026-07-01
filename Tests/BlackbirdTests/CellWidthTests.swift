import XCTest
@testable import Blackbird

/// Contract pins for `CellWidth` — the Swift-side string→terminal-cell width
/// model used to size and anchor the IME preedit overlay before composing text
/// reaches the grid. These tests are GPU/MTLDevice-free: `CellWidth` is pure
/// arithmetic over `UnicodeScalar` / `Character`, so the whole contract is
/// exercisable without booting a `TerminalView`.
///
/// Two layers are pinned independently:
///   - `width(for:)`  — per-scalar East-Asian-Width classification (0/1/2).
///   - `terminalCellWidth(of:)` — per-grapheme accumulation, including the
///     VS16 (U+FE0F) / U+20E3 keycap promotion and the ZWJ-cluster rule that a
///     multi-scalar emoji grapheme counts as ONE wide glyph, not the sum.
final class CellWidthTests: XCTestCase {

    // MARK: - width(for:) — scalar level

    func testScalarWidth_asciiIsOne() {
        XCTAssertEqual(CellWidth.width(for: UnicodeScalar(0x0061)!), 1) // 'a'
    }

    func testScalarWidth_cjkIdeographIsTwo() {
        XCTAssertEqual(CellWidth.width(for: UnicodeScalar(0x4E00)!), 2) // 一
    }

    func testScalarWidth_hangulSyllableIsTwo() {
        XCTAssertEqual(CellWidth.width(for: UnicodeScalar(0xAC00)!), 2) // 가
    }

    func testScalarWidth_fullwidthFormIsTwo() {
        XCTAssertEqual(CellWidth.width(for: UnicodeScalar(0xFF21)!), 2) // Ａ
    }

    func testScalarWidth_emojiIsTwo() {
        XCTAssertEqual(CellWidth.width(for: UnicodeScalar(0x1F300)!), 2) // 🌀
    }

    func testScalarWidth_combiningMarkIsZero() {
        XCTAssertEqual(CellWidth.width(for: UnicodeScalar(0x0300)!), 0) // combining grave
    }

    func testScalarWidth_zwjIsZero() {
        XCTAssertEqual(CellWidth.width(for: UnicodeScalar(0x200D)!), 0) // ZWJ
    }

    /// As a LONE scalar VS16 is zero-width — it only widens by promoting the
    /// base it follows (verified at grapheme level below).
    func testScalarWidth_vs16LoneScalarIsZero() {
        XCTAssertEqual(CellWidth.width(for: UnicodeScalar(0xFE0F)!), 0)
    }

    // MARK: - terminalCellWidth(of:) — grapheme level

    func testStringWidth_emptyIsZero() {
        XCTAssertEqual(CellWidth.terminalCellWidth(of: ""), 0)
    }

    func testStringWidth_asciiIsOne() {
        XCTAssertEqual(CellWidth.terminalCellWidth(of: "a"), 1)
    }

    func testStringWidth_cjkIdeographIsTwo() {
        XCTAssertEqual(CellWidth.terminalCellWidth(of: "\u{4E00}"), 2) // 一
    }

    func testStringWidth_hangulSyllableIsTwo() {
        XCTAssertEqual(CellWidth.terminalCellWidth(of: "\u{AC00}"), 2) // 가
    }

    func testStringWidth_fullwidthFormIsTwo() {
        XCTAssertEqual(CellWidth.terminalCellWidth(of: "\u{FF21}"), 2) // Ａ
    }

    func testStringWidth_emojiIsTwo() {
        XCTAssertEqual(CellWidth.terminalCellWidth(of: "\u{1F300}"), 2) // 🌀
    }

    /// A base + combining-mark grapheme renders in the base's cell: the
    /// combining mark contributes 0, so the cluster is 1 cell, not 1+0 summed
    /// across separate cells.
    func testStringWidth_baseWithCombiningMarkIsOne() {
        XCTAssertEqual(CellWidth.terminalCellWidth(of: "a\u{0300}"), 1) // à
    }

    /// A lone ZWJ grapheme is zero-width.
    func testStringWidth_loneZwjIsZero() {
        XCTAssertEqual(CellWidth.terminalCellWidth(of: "\u{200D}"), 0)
    }

    /// Emoji-presentation promotion: U+26A0 (warning sign) is a narrow symbol
    /// on its own, but base + VS16 renders as a 2-cell emoji. The grapheme
    /// must report 2 so the preedit overlay matches where the grid draws it.
    func testStringWidth_vs16PromotesBaseToTwo() {
        XCTAssertEqual(CellWidth.terminalCellWidth(of: "\u{26A0}\u{FE0F}"), 2) // ⚠️
    }

    /// Keycap sequence U+0031 U+FE0F U+20E3: neither '1' nor the enclosing
    /// keycap combiner is in a wide range, but the VS16 + U+20E3 promotion
    /// must lift the whole grapheme to 2.
    func testStringWidth_keycapIsTwo() {
        XCTAssertEqual(CellWidth.terminalCellWidth(of: "1\u{FE0F}\u{20E3}"), 2) // 1️⃣
    }

    /// A ZWJ family emoji is ONE grapheme that renders as one wide glyph —
    /// it must count as 2 cells, NOT the per-scalar sum (2+0+2+0+2 = 6).
    func testStringWidth_zwjFamilyIsTwoNotSummed() {
        // man + ZWJ + woman + ZWJ + girl
        let family = "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}"
        XCTAssertEqual(CellWidth.terminalCellWidth(of: family), 2)
    }

    // MARK: - accumulation across multiple graphemes

    func testStringWidth_accumulatesAcrossGraphemes() {
        XCTAssertEqual(CellWidth.terminalCellWidth(of: "ab"), 2)          // 1 + 1
        XCTAssertEqual(CellWidth.terminalCellWidth(of: "a\u{4E00}"), 3)   // 1 + 2
    }
}
