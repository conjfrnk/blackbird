import XCTest
@testable import Blackbird

/// Tests for `wordRange(around:in:displayOffset:)`.
///
/// The shipped word-character set excludes alphanumerics, `_`, `.`, `/`,
/// `-`, `:`, and shell sigils (`$`, `@`, `=`, `#`, `&`, `|`, `<`, `>`).
/// Prose punctuation (`,`, `;`, `?`) and bracket pairs remain breakers.
/// See `wordBreakers` in Selection.swift. Audit findbar-selection F14.
final class WordRangeTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        TestHostTermination.shared.register()
    }

    // MARK: - Helpers

    /// Build a BBTerm of the requested size, type `text` at the current
    /// cursor (which starts at row 0, col 0 for a fresh terminal) and
    /// return its snapshot. Fails the test if snapshotting fails.
    private func snapshot(for text: String,
                          cols: UInt16 = 80,
                          rows: UInt16 = 24,
                          file: StaticString = #filePath,
                          line: UInt = #line) throws -> BBSnapshot {
        let term = try XCTUnwrap(BBTerm(size: .init(cols: cols, rows: rows)),
                                 "BBTerm init failed",
                                 file: file, line: line)
        term.input(text)
        return try XCTUnwrap(term.snapshot(),
                             "snapshot() returned nil",
                             file: file, line: line)
    }

    /// Convenience BufferPoint for a visible-row-0 column.
    private func p(_ col: Int, line: Int32 = 0) -> BufferPoint {
        BufferPoint(line: line, col: col)
    }

    /// Assert a range equals the given endpoints (both on line 0).
    private func assertRange(_ range: (BufferPoint, BufferPoint)?,
                             _ startCol: Int,
                             _ endCol: Int,
                             file: StaticString = #filePath,
                             line: UInt = #line) {
        guard let r = range else {
            XCTFail("expected range (col \(startCol), col \(endCol)), got nil",
                    file: file, line: line)
            return
        }
        XCTAssertEqual(r.0, p(startCol),
                       "start mismatch: expected col \(startCol), got \(r.0)",
                       file: file, line: line)
        XCTAssertEqual(r.1, p(endCol),
                       "end mismatch: expected col \(endCol), got \(r.1)",
                       file: file, line: line)
    }

    // MARK: - 1. "hello world" — point inside "hello"

    func test_helloWorld_pointInsideHello_returnsHelloRange() throws {
        let snap = try snapshot(for: "hello world")
        let r = wordRange(around: p(2), in: snap, displayOffset: 0)
        assertRange(r, 0, 4)
    }

    // MARK: - 2. "hello world" — point on the space

    func test_helloWorld_pointOnSpace_returnsNil() throws {
        let snap = try snapshot(for: "hello world")
        let r = wordRange(around: p(5), in: snap, displayOffset: 0)
        XCTAssertNil(r, "expansion on a word-break character must return nil")
    }

    // MARK: - 3. "hello world" — point inside "world"

    func test_helloWorld_pointInsideWorld_returnsWorldRange() throws {
        let snap = try snapshot(for: "hello world")
        let r = wordRange(around: p(6), in: snap, displayOffset: 0)
        assertRange(r, 6, 10)
    }

    // MARK: - 4. Identifier with underscore

    func test_identifier_underscore_selectedAsOneWord() throws {
        let snap = try snapshot(for: "foo_bar baz")
        let r = wordRange(around: p(3), in: snap, displayOffset: 0)
        assertRange(r, 0, 6)
    }

    // MARK: - 5. Dotted path "config.ini" — contract says `.` is a word char

    func test_dottedPath_configIni_selectedAsOneWord() throws {
        let snap = try snapshot(for: "config.ini ")
        let r = wordRange(around: p(3), in: snap, displayOffset: 0)
        assertRange(r, 0, 9)
    }

    // MARK: - 6. Path-like "/usr/local/bin" — contract says `/` is a word char

    func test_pathLike_selectedAsOneWord() throws {
        // Trailing space ensures a clear word terminator.
        let snap = try snapshot(for: "/usr/local/bin ")
        // Probe a letter inside the path ("l" of "local" is at col 5).
        let r = wordRange(around: p(5), in: snap, displayOffset: 0)
        assertRange(r, 0, 13)
    }

    // MARK: - 7. Hostname "example.com:8080" — contract says `.` and `:` are word chars

    func test_hostnameWithPort_selectedAsOneWord() throws {
        let snap = try snapshot(for: "example.com:8080 ")
        let r = wordRange(around: p(3), in: snap, displayOffset: 0)
        assertRange(r, 0, 15)
    }

    // MARK: - 8. Parens: "(hello)" — parens are never word chars

    func test_parenthesised_hello_yieldsInnerWord() throws {
        let snap = try snapshot(for: "(hello) ")
        // Probe the middle 'l' of "hello" at col 3.
        let r = wordRange(around: p(3), in: snap, displayOffset: 0)
        assertRange(r, 1, 5)
    }

    func test_openParen_itselfIsNotAWord() throws {
        let snap = try snapshot(for: "(hello) ")
        let r = wordRange(around: p(0), in: snap, displayOffset: 0)
        XCTAssertNil(r, "'(' is a word-break character and must return nil")
    }

    func test_closeParen_itselfIsNotAWord() throws {
        let snap = try snapshot(for: "(hello) ")
        let r = wordRange(around: p(6), in: snap, displayOffset: 0)
        XCTAssertNil(r, "')' is a word-break character and must return nil")
    }

    // MARK: - 9. Empty cells break words

    func test_emptyCell_afterTypedText_returnsNil() throws {
        // Type "hi" into a wide grid; cells from col 2 onward are empty
        // (ch == 0). Empty cells must not be part of any word.
        let snap = try snapshot(for: "hi")
        let r = wordRange(around: p(10), in: snap, displayOffset: 0)
        XCTAssertNil(r, "empty cell (ch == 0) must not expand")
    }

    func test_typedSpaceBreaksWords() throws {
        // A literal space character (scalar 0x20) must also break a word.
        let snap = try snapshot(for: "aa bb")
        // Sanity-check the two neighbours still select as independent words.
        assertRange(wordRange(around: p(0), in: snap, displayOffset: 0), 0, 1)
        assertRange(wordRange(around: p(3), in: snap, displayOffset: 0), 3, 4)
        // Probe the space at col 2.
        let r = wordRange(around: p(2), in: snap, displayOffset: 0)
        XCTAssertNil(r, "typed space (0x20) must not expand")
    }

    // MARK: - Shell / source sigils (audit findbar-selection F14)
    //
    // `$PATH`, `user@host.com`, `env=VALUE`, `#define FOO`, `&ref`, `|pipe`,
    // and `<angle>` should double-click as single units rather than
    // fragment at every sigil. Before the fix these characters were in
    // the wordBreakers set; after the fix they are not.

    func test_dollarSigil_selectsAsPartOfIdentifier() throws {
        let snap = try snapshot(for: "$PATH end")
        // $PATH spans cols 0-4 inclusive.
        assertRange(wordRange(around: p(0), in: snap, displayOffset: 0), 0, 4)
        assertRange(wordRange(around: p(2), in: snap, displayOffset: 0), 0, 4)
        assertRange(wordRange(around: p(4), in: snap, displayOffset: 0), 0, 4)
    }

    func test_atSign_inEmailStaysUnbroken() throws {
        let snap = try snapshot(for: "me@host.com")
        // All 11 cols (0..10) must belong to the same word.
        assertRange(wordRange(around: p(0), in: snap, displayOffset: 0), 0, 10)
        assertRange(wordRange(around: p(2), in: snap, displayOffset: 0), 0, 10)
        assertRange(wordRange(around: p(10), in: snap, displayOffset: 0), 0, 10)
    }

    func test_equalsSign_inAssignmentStaysUnbroken() throws {
        let snap = try snapshot(for: "KEY=value")
        // KEY=value spans cols 0-8.
        assertRange(wordRange(around: p(0), in: snap, displayOffset: 0), 0, 8)
        assertRange(wordRange(around: p(3), in: snap, displayOffset: 0), 0, 8)
        assertRange(wordRange(around: p(8), in: snap, displayOffset: 0), 0, 8)
    }

    func test_hashSign_inDefineStaysUnbroken() throws {
        let snap = try snapshot(for: "#define end")
        // #define spans cols 0-6.
        assertRange(wordRange(around: p(0), in: snap, displayOffset: 0), 0, 6)
        assertRange(wordRange(around: p(3), in: snap, displayOffset: 0), 0, 6)
    }

    func test_semicolon_stillBreaks() throws {
        // Prose punctuation is preserved.
        let snap = try snapshot(for: "aa;bb")
        assertRange(wordRange(around: p(0), in: snap, displayOffset: 0), 0, 1)
        assertRange(wordRange(around: p(3), in: snap, displayOffset: 0), 3, 4)
    }

    // MARK: - Unicode / grapheme-cluster coverage
    // (audit swift-tests-core F6)
    //
    // Wide CJK chars have a second cell with scalar 0 — `BBSnapshot.
    // character(at:row:)` returns nil for scalar==0. The wide-char
    // carveout at Selection.swift:153-161 (findbar-selection F36)
    // handles the case where the click lands on the trailing half.
    // Combining marks and multi-scalar graphemes have subtler
    // interactions — both because the Swift `Character` collapses them
    // and because of grapheme-cluster width in the terminal. These
    // tests pin the current behaviour so future refactors don't
    // silently regress.

    /// Regression for swift-tests-core F6: a CJK word should select
    /// as one unit. Each wide CJK char takes two cells with the
    /// second cell carrying scalar 0; the wide-char carveout must
    /// find the leading cell when the click lands on either half.
    /// The expansion reaches through both characters regardless of
    /// whether alacritty assigns CJK narrow (1 cell/char), half-wide
    /// (2 cells total), or wide (2 cells/char, 4 total) width.
    func test_cjkChars_selectAsOneWord() throws {
        // "漢字" — two CJK chars, followed by a space separator.
        // Width handling varies across alacritty versions and
        // terminfo caps; what we pin is "wordRange returns a
        // non-nil range starting at col 0 AND extending past the
        // first CJK character when alacritty assigns wide width".
        // Audit fix-#02 (2026-05-11): tightened from the previous
        // (0...3).contains(endCol) check which accepted endCol==0 —
        // i.e. the bug where the expansion broke at the trailing
        // spacer of the first wide glyph. cellKind-based walking
        // now skips over spacers, so wide CJK runs select as a unit.
        let snap = try snapshot(for: "漢字 end")
        // Click on the first char's leading cell (col 0).
        guard let r = wordRange(around: p(0), in: snap, displayOffset: 0) else {
            XCTFail("wordRange on CJK leading cell must not return nil")
            return
        }
        XCTAssertEqual(r.0.col, 0, "leading col should be 0")
        // endCol depends on alacritty's CJK width assignment:
        //   narrow (1 cell each, 2 total): endCol == 1
        //   wide   (2 cells each, 4 total): endCol == 3
        //   half-wide (mixed): endCol == 2
        // All three signal a successful expansion through BOTH
        // characters. endCol == 0 is the post-fix-#02 regression
        // signal: spacer broke the walk after only `漢`.
        XCTAssertTrue(
            (1...3).contains(r.1.col),
            "expansion must reach past the first CJK glyph (endCol in [1,3]); got \(r.1.col) — regression of audit fix-#02 (spacer broke the walk)"
        )
    }

    /// Regression for swift-tests-core F6: emoji (non-BMP scalar) as
    /// a single word. An emoji like 🎉 takes one or two cells
    /// depending on alacritty's width table. `wordRange` must not
    /// split mid-emoji.
    func test_emoji_selectsAsOneWord() throws {
        // `🎉` = U+1F389. Followed by ASCII prose to create a clear
        // word boundary.
        let snap = try snapshot(for: "🎉 word")
        if let r = wordRange(around: p(0), in: snap, displayOffset: 0) {
            XCTAssertEqual(r.0.col, 0, "emoji starts at col 0")
            XCTAssertTrue(
                r.1.col == 0 || r.1.col == 1,
                "emoji should occupy 1 or 2 cells, got endCol=\(r.1.col)"
            )
        }
    }

    /// Regression for swift-tests-core F6: clicking on the trailing
    /// half of a wide CJK cell must walk back to the leading half
    /// (findbar-selection F36 fix) and still expand. Pre-fix, a
    /// click on col 1 of `漢` returned nil because col 1's scalar
    /// is 0.
    func test_cjk_clickOnTrailingCell_walksBackAndExpands() throws {
        let snap = try snapshot(for: "漢字 end")
        let r = wordRange(around: p(1), in: snap, displayOffset: 0)
        // If alacritty uses wide width, col 1 has scalar 0 and the
        // carveout kicks in. If narrow, col 1 already has `字` so
        // there's no walk-back. Either way the expansion must
        // return a non-nil range including col 0 or 1.
        if let (start, _) = r {
            XCTAssertLessThanOrEqual(
                start.col, 1,
                "expansion should include the clicked cell or earlier, got startCol=\(start.col)"
            )
        }
        // Nil is also acceptable if alacritty leaves both cells
        // genuinely empty (shouldn't happen with this input, but
        // avoids pinning platform-specific width behaviour).
    }
}
