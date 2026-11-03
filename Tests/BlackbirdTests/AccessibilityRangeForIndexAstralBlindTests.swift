import XCTest
@testable import Blackbird

/// Blind regression tests (bug mpe-4): `accessibilityRange(for:)` must treat
/// an astral-plane character (emoji, CJK Extension-B ideograph) as ONE
/// character that spans TWO UTF-16 code units.
///
/// VoiceOver walks a `.textArea` by character: for each UTF-16 index it asks
/// `accessibilityRange(for: index)` ("the glyph containing this index"), then
/// feeds that range to `accessibilityString(for:)` and speaks the result.
/// NSTextView's contract for that attribute is the composed character
/// sequence containing the index, so for the value `"ok 👍 done"`
/// (UTF-16: `o k ␠ D83D DC4D ␠ d o n e`, 10 units) BOTH index 3 (high
/// surrogate) and index 4 (low surrogate) must answer `{3, 2}` -> "👍".
///
/// A 1-unit answer splits the surrogate pair: `accessibilityString(for:)`
/// then decodes a lone surrogate to U+FFFD, so VO speaks a replacement
/// character (or nothing) for every emoji, and the low-surrogate answer
/// doesn't even start on a character boundary.
///
/// Memory pre-flight: every test below uses a handful of rows, each a few
/// dozen UTF-16 units (< 1 KB total). Wall time per test < 20 ms. No
/// window, no PTY, no Metal.
final class AccessibilityRangeForIndexAstralBlindTests: XCTestCase {

    private let thumbsUp = "\u{1F44D}"      // U+1F44D, UTF-16 D83D DC4D
    private let cjkExtB = "\u{20000}"        // U+20000, UTF-16 D840 DC00
    private let replacement = "\u{FFFD}"

    // MARK: - Helpers

    private func makeView(rows: [String]) throws -> (view: TerminalView, value: String) {
        let view = try XCTUnwrap(TerminalView.makeHeadlessForTests())
        view.installSnapshotForTests(rows: rows)
        let value: String = (view.accessibilityValue() as? String) ?? ""
        return (view, value)
    }

    private func isHighSurrogate(_ unit: UInt16) -> Bool { unit >= 0xD800 && unit <= 0xDBFF }
    private func isLowSurrogate(_ unit: UInt16) -> Bool { unit >= 0xDC00 && unit <= 0xDFFF }

    // MARK: - Emoji on a single row

    func test_rangeForIndex_emojiHighSurrogate_coversBothUnits() throws {
        // Memory: <1 KB. Wall: ~5 ms.
        let (view, value) = try makeView(rows: ["ok \(thumbsUp) done"])

        // Preconditions (non-vacuity): the value really is 10 UTF-16 units
        // with a surrogate pair at 3...4.
        let units: [UInt16] = Array(value.utf16)
        XCTAssertEqual(units.count, 10, "precondition: 'ok 👍 done' is 10 UTF-16 units; value=\(value.debugDescription)")
        XCTAssertTrue(units.count > 4 && isHighSurrogate(units[3]) && isLowSurrogate(units[4]),
                      "precondition: units 3,4 must be a surrogate pair; units=\(units.map { String($0, radix: 16) })")

        let range = view.accessibilityRange(for: 3)
        XCTAssertEqual(range, NSRange(location: 3, length: 2),
                       "index 3 is the emoji's high surrogate; the character range must cover both units, got \(NSStringFromRange(range))")
        XCTAssertEqual(view.accessibilityString(for: range), thumbsUp,
                       "string for range \(NSStringFromRange(range)) must be the whole emoji, not a replacement-character half")
    }

    func test_rangeForIndex_emojiLowSurrogate_returnsRangeFromCharacterBoundary() throws {
        // Memory: <1 KB. Wall: ~5 ms.
        let (view, _) = try makeView(rows: ["ok \(thumbsUp) done"])

        let range = view.accessibilityRange(for: 4)
        XCTAssertEqual(range, NSRange(location: 3, length: 2),
                       "index 4 is the emoji's low surrogate; the range of the character containing it is {3,2} (starts at the boundary), got \(NSStringFromRange(range))")
        let spoken: String? = view.accessibilityString(for: range)
        XCTAssertEqual(spoken, thumbsUp,
                       "string for range \(NSStringFromRange(range)) must be the whole emoji, got \(String(describing: spoken?.debugDescription))")
        XCTAssertNotEqual(spoken, replacement,
                          "VoiceOver must not be handed U+FFFD for a visible emoji")
    }

    // MARK: - CJK Extension-B ideograph

    func test_rangeForIndex_cjkExtensionB_bothHalvesMapToWholeIdeograph() throws {
        // Memory: <1 KB. Wall: ~5 ms.
        let (view, value) = try makeView(rows: ["a\(cjkExtB)b"])
        XCTAssertEqual(value.utf16.count, 4,
                       "precondition: 'a𠀀b' is 4 UTF-16 units; value=\(value.debugDescription)")

        let atHigh = view.accessibilityRange(for: 1)
        let atLow = view.accessibilityRange(for: 2)
        XCTAssertEqual(atHigh, NSRange(location: 1, length: 2),
                       "index 1 (high surrogate of U+20000) must cover both units, got \(NSStringFromRange(atHigh))")
        XCTAssertEqual(atLow, NSRange(location: 1, length: 2),
                       "index 2 (low surrogate of U+20000) must report the whole character {1,2}, got \(NSStringFromRange(atLow))")
        XCTAssertEqual(view.accessibilityString(for: atHigh), cjkExtB)
        XCTAssertEqual(view.accessibilityString(for: atLow), cjkExtB)

        // The BMP neighbour after the ideograph is still a 1-unit character
        // at its own (shifted) index.
        let after = view.accessibilityRange(for: 3)
        XCTAssertEqual(after, NSRange(location: 3, length: 1),
                       "'b' follows the ideograph at index 3 and is a single unit, got \(NSStringFromRange(after))")
        XCTAssertEqual(view.accessibilityString(for: after), "b")
    }

    // MARK: - Emoji on a later row (offset arithmetic)

    func test_rangeForIndex_emojiOnSecondRow_usesValueOffsets() throws {
        // Memory: <1 KB. Wall: ~5 ms.
        // value = "ok 👍 done\nx😀y": row 0 = 10 units, '\n' at 10, 'x' at 11,
        // 😀 (U+1F600) at 12...13, 'y' at 14.
        let grin = "\u{1F600}"
        let (view, value) = try makeView(rows: ["ok \(thumbsUp) done", "x\(grin)y"])
        XCTAssertEqual(value.utf16.count, 15,
                       "precondition: value is 15 UTF-16 units; value=\(value.debugDescription)")

        XCTAssertEqual(view.accessibilityRange(for: 12), NSRange(location: 12, length: 2),
                       "high surrogate of 😀 on row 1")
        XCTAssertEqual(view.accessibilityRange(for: 13), NSRange(location: 12, length: 2),
                       "low surrogate of 😀 on row 1 must map back to the boundary at 12")
        XCTAssertEqual(view.accessibilityString(for: view.accessibilityRange(for: 13)), grin)
        // Row 0's emoji is unaffected by the second row.
        XCTAssertEqual(view.accessibilityRange(for: 4), NSRange(location: 3, length: 2),
                       "row 0 emoji low surrogate")
        // Neighbours of the row-1 emoji stay single-unit.
        XCTAssertEqual(view.accessibilityRange(for: 11), NSRange(location: 11, length: 1), "'x' before 😀")
        XCTAssertEqual(view.accessibilityRange(for: 14), NSRange(location: 14, length: 1), "'y' after 😀")
    }

    // MARK: - Whole-value walk (what VoiceOver actually does)

    func test_rangeForIndex_walkingEveryIndex_neverSplitsOrCorruptsCharacters() throws {
        // Memory: <1 KB. Wall: ~10 ms (<= 20 indices x 2 calls).
        // Walk every UTF-16 index like VO's character navigation. For each:
        //  - the returned range contains the index,
        //  - the range starts on a character boundary (not at a low
        //    surrogate) and ends on one (not between a pair),
        //  - the string for it never contains U+FFFD,
        //  - the distinct ranges, in order, tile the whole value so their
        //    strings concatenate back to the value.
        let rows: [String] = ["ok \(thumbsUp) done", "\(cjkExtB)x"]
        let (view, value) = try makeView(rows: rows)
        let units: [UInt16] = Array(value.utf16)
        XCTAssertEqual(units.count, 14,
                       "precondition: 10 + '\\n' + 2 + 1 = 14 UTF-16 units; value=\(value.debugDescription)")
        XCTAssertEqual(view.accessibilityNumberOfCharacters(), units.count)

        var tiled = ""
        var nextExpectedStart = 0
        for index in 0..<units.count {
            let range = view.accessibilityRange(for: index)
            XCTAssertNotEqual(range.location, NSNotFound,
                              "index \(index) is inside the value and must have a range")
            guard range.location != NSNotFound, range.location >= 0,
                  range.location + range.length <= units.count else {
                XCTFail("range \(NSStringFromRange(range)) for index \(index) lies outside the \(units.count)-unit value")
                continue
            }

            XCTAssertTrue(range.location <= index && index < range.location + range.length,
                          "range \(NSStringFromRange(range)) for index \(index) must contain the index")
            XCTAssertFalse(isLowSurrogate(units[range.location]),
                           "range \(NSStringFromRange(range)) for index \(index) starts on a low surrogate (mid-character)")
            let end = range.location + range.length
            if end < units.count {
                XCTAssertFalse(isLowSurrogate(units[end]),
                               "range \(NSStringFromRange(range)) for index \(index) ends between a surrogate pair")
            }

            let spoken: String = view.accessibilityString(for: range) ?? "<nil>"
            XCTAssertFalse(spoken.contains(replacement),
                           "string for index \(index) range \(NSStringFromRange(range)) contains U+FFFD: \(spoken.debugDescription)")

            if range.location == nextExpectedStart {
                tiled += spoken
                nextExpectedStart = end
            }
        }
        XCTAssertEqual(tiled, value,
                       "per-character ranges must tile the whole value exactly; reassembled \(tiled.debugDescription) vs value \(value.debugDescription)")
    }

    // MARK: - Guard against over-correction

    func test_rangeForIndex_bmpCharactersAroundEmoji_stayOneUnit() throws {
        // Memory: <1 KB. Wall: ~5 ms.
        // A fix that widened every answer (or answered the emoji range for
        // its neighbours) would break ordinary navigation.
        let (view, _) = try makeView(rows: ["ok \(thumbsUp) done"])
        XCTAssertEqual(view.accessibilityRange(for: 0), NSRange(location: 0, length: 1))
        XCTAssertEqual(view.accessibilityRange(for: 2), NSRange(location: 2, length: 1),
                       "space before the emoji")
        XCTAssertEqual(view.accessibilityRange(for: 5), NSRange(location: 5, length: 1),
                       "space after the emoji")
        XCTAssertEqual(view.accessibilityRange(for: 9), NSRange(location: 9, length: 1),
                       "last character of the value")
        XCTAssertEqual(view.accessibilityString(for: view.accessibilityRange(for: 5)), " ")
    }
}
