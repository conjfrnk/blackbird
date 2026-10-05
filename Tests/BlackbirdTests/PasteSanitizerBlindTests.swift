import XCTest
@testable import Blackbird

/// Characterization tests for `PasteSanitizer`'s byte transforms
/// (normalizePasteLineEndings, sanitizePasteControls, stripBidiOverrides,
/// convertLoneCRToLF, sanitizeBracketedPaste). These are security-critical
/// (paste injection / Trojan Source), and the contract is "Data in, Data out,
/// byte-for-byte identical to the documented rules" for every possible input,
/// including truncated multi-byte leads at the end, `Data` slices whose
/// `startIndex != 0`, and slices that end before the backing store does.
///
/// Two layers:
///  1. Hand-derived expected outputs for each documented rule/boundary.
///  2. A differential test against an independent, deliberately naive
///     `[UInt8]` reference oracle (below) on seeded random byte arrays.
///
/// Cost: every buffer is <= 128 KiB, the random corpus is ~2.4k cases of <= 4 KiB
/// (~16 MiB of byte-throughput total worst case, well under a second).
final class PasteSanitizerBlindTests: XCTestCase {

    // MARK: - Helpers

    private func d(_ bytes: [UInt8]) -> Data { Data(bytes) }

    /// Wrap `bytes` in a Data slice with a non-zero startIndex (and optionally
    /// extra backing bytes after the slice's end).
    private func slice(_ bytes: [UInt8], padBefore: Int = 3, padAfter: Int = 0) -> Data {
        var backing = [UInt8](repeating: 0x41, count: padBefore)
        backing += bytes
        backing += [UInt8](repeating: 0x42, count: padAfter)
        let whole = Data(backing)
        return whole[padBefore..<(padBefore + bytes.count)]
    }

    // MARK: - convertLoneCRToLF

    func testConvertLoneCR_emptyAndClean() {
        XCTAssertEqual(PasteSanitizer.convertLoneCRToLF(Data()), Data())
        XCTAssertEqual(PasteSanitizer.convertLoneCRToLF(d([0x61, 0x0A, 0x62])), d([0x61, 0x0A, 0x62]))
    }

    func testConvertLoneCR_replacesEveryCR() {
        XCTAssertEqual(PasteSanitizer.convertLoneCRToLF(d([0x0D])), d([0x0A]))
        XCTAssertEqual(PasteSanitizer.convertLoneCRToLF(d([0x61, 0x0D, 0x62, 0x0D])),
                       d([0x61, 0x0A, 0x62, 0x0A]))
        // CRLF is NOT collapsed here: each byte is mapped independently.
        XCTAssertEqual(PasteSanitizer.convertLoneCRToLF(d([0x0D, 0x0A])), d([0x0A, 0x0A]))
        XCTAssertEqual(PasteSanitizer.convertLoneCRToLF(d([0x0D, 0x0D, 0x0D])), d([0x0A, 0x0A, 0x0A]))
    }

    func testConvertLoneCR_leavesMultibyteUntouched() {
        let s = Array("┌─┐\r│x│\r".utf8)
        let expected = Array("┌─┐\n│x│\n".utf8)
        XCTAssertEqual(PasteSanitizer.convertLoneCRToLF(d(s)), d(expected))
    }

    func testConvertLoneCR_slice() {
        let input = slice([0x61, 0x0D, 0x62])
        XCTAssertEqual(PasteSanitizer.convertLoneCRToLF(input), d([0x61, 0x0A, 0x62]))
        let clean = slice([0x61, 0x62])
        XCTAssertEqual(PasteSanitizer.convertLoneCRToLF(clean), d([0x61, 0x62]))
    }

    // MARK: - normalizePasteLineEndings

    func testNormalize_emptyAndNoCR() {
        XCTAssertEqual(PasteSanitizer.normalizePasteLineEndings(Data()), Data())
        XCTAssertEqual(PasteSanitizer.normalizePasteLineEndings(d([0x61, 0x0A, 0x62])), d([0x61, 0x0A, 0x62]))
    }

    func testNormalize_crlfCollapsesLoneCRKept() {
        XCTAssertEqual(PasteSanitizer.normalizePasteLineEndings(d([0x0D, 0x0A])), d([0x0A]))
        XCTAssertEqual(PasteSanitizer.normalizePasteLineEndings(d([0x61, 0x0D, 0x0A, 0x62, 0x0D, 0x0A])),
                       d([0x61, 0x0A, 0x62, 0x0A]))
        // Lone CR left alone.
        XCTAssertEqual(PasteSanitizer.normalizePasteLineEndings(d([0x61, 0x0D, 0x62])), d([0x61, 0x0D, 0x62]))
    }

    func testNormalize_trailingCRKept() {
        XCTAssertEqual(PasteSanitizer.normalizePasteLineEndings(d([0x61, 0x0D])), d([0x61, 0x0D]))
        XCTAssertEqual(PasteSanitizer.normalizePasteLineEndings(d([0x0D])), d([0x0D]))
    }

    func testNormalize_crCrLfOnlyCollapsesThePair() {
        // CR CR LF -> CR LF (single left-to-right pass, no re-scan).
        XCTAssertEqual(PasteSanitizer.normalizePasteLineEndings(d([0x0D, 0x0D, 0x0A])), d([0x0D, 0x0A]))
        // CR LF LF -> LF LF ; LF CR -> LF CR
        XCTAssertEqual(PasteSanitizer.normalizePasteLineEndings(d([0x0D, 0x0A, 0x0A])), d([0x0A, 0x0A]))
        XCTAssertEqual(PasteSanitizer.normalizePasteLineEndings(d([0x0A, 0x0D])), d([0x0A, 0x0D]))
        XCTAssertEqual(PasteSanitizer.normalizePasteLineEndings(d([0x0D, 0x0D])), d([0x0D, 0x0D]))
    }

    func testNormalize_slice() {
        XCTAssertEqual(PasteSanitizer.normalizePasteLineEndings(slice([0x61, 0x0D, 0x0A, 0x62])),
                       d([0x61, 0x0A, 0x62]))
        // Slice that ends on a CR whose backing store continues with LF: the
        // LF is outside the slice and must not be consumed or inspected.
        let whole = d([0x61, 0x0D, 0x0A, 0x62])
        XCTAssertEqual(PasteSanitizer.normalizePasteLineEndings(whole[0..<2]), d([0x61, 0x0D]))
    }

    // MARK: - sanitizePasteControls

    func testControls_emptyAndClean() {
        XCTAssertEqual(PasteSanitizer.sanitizePasteControls(Data()), Data())
        let clean = Array("hello world\tx\ny\rz ~ é ┌─┐ ✓ — ❤️".utf8)
        XCTAssertEqual(PasteSanitizer.sanitizePasteControls(d(clean)), d(clean))
    }

    func testControls_c0AndDelBecomeSpace() {
        for b in UInt8(0x00)...UInt8(0x1F) where b != 0x09 && b != 0x0A && b != 0x0D {
            XCTAssertEqual(PasteSanitizer.sanitizePasteControls(d([0x61, b, 0x62])),
                           d([0x61, 0x20, 0x62]), "C0 byte \(b)")
        }
        XCTAssertEqual(PasteSanitizer.sanitizePasteControls(d([0x61, 0x7F, 0x62])), d([0x61, 0x20, 0x62]))
        // Whitespace passes.
        XCTAssertEqual(PasteSanitizer.sanitizePasteControls(d([0x09, 0x0A, 0x0D])), d([0x09, 0x0A, 0x0D]))
        // 0x20 and 0x7E are untouched.
        XCTAssertEqual(PasteSanitizer.sanitizePasteControls(d([0x20, 0x7E])), d([0x20, 0x7E]))
    }

    func testControls_c1PairsBecomeSingleSpace() {
        for second in UInt8(0x80)...UInt8(0x9F) {
            XCTAssertEqual(PasteSanitizer.sanitizePasteControls(d([0x61, 0xC2, second, 0x62])),
                           d([0x61, 0x20, 0x62]), "C2 \(second)")
        }
        // Outside 0x80...0x9F: preserved verbatim (NBSP, inverted-excl, soft hyphen).
        for second in [UInt8(0x7F), 0xA0, 0xA1, 0xAD, 0xBF, 0x41] {
            let expected: [UInt8] = second == 0x7F ? [0xC2, 0x20] : [0xC2, second]
            XCTAssertEqual(PasteSanitizer.sanitizePasteControls(d([0xC2, second])), d(expected),
                           "C2 \(second)")
        }
    }

    func testControls_truncatedLeadAtEnd() {
        XCTAssertEqual(PasteSanitizer.sanitizePasteControls(d([0x61, 0xC2])), d([0x61, 0xC2]))
        XCTAssertEqual(PasteSanitizer.sanitizePasteControls(d([0xC2])), d([0xC2]))
        // C2 C2 80: first C2 is followed by C2 (not C1 range) -> kept; then C2 80 -> space.
        XCTAssertEqual(PasteSanitizer.sanitizePasteControls(d([0xC2, 0xC2, 0x80])), d([0xC2, 0x20]))
        // C2 followed by a C0 control: C2 kept, control -> space.
        XCTAssertEqual(PasteSanitizer.sanitizePasteControls(d([0xC2, 0x1B])), d([0xC2, 0x20]))
    }

    func testControls_loneContinuationAndHighBytesPreserved() {
        let bytes: [UInt8] = [0x80, 0x9B, 0x9D, 0xBF, 0xFF, 0xE2, 0x94]
        XCTAssertEqual(PasteSanitizer.sanitizePasteControls(d(bytes)), d(bytes))
    }

    func testControls_escSequenceNeutralised() {
        // ESC [ 2 0 1 ~  -> ' ' [ 2 0 1 ~
        XCTAssertEqual(PasteSanitizer.sanitizePasteControls(d([0x1B, 0x5B, 0x32, 0x30, 0x31, 0x7E])),
                       d([0x20, 0x5B, 0x32, 0x30, 0x31, 0x7E]))
    }

    func testControls_slice() {
        XCTAssertEqual(PasteSanitizer.sanitizePasteControls(slice([0x61, 0x03, 0xC2, 0x9B, 0x62])),
                       d([0x61, 0x20, 0x20, 0x62]))
        // Slice ends at a C2 lead; the backing store's following byte (0x80)
        // is outside the slice and must not combine with it.
        let whole = d([0x61, 0xC2, 0x80])
        XCTAssertEqual(PasteSanitizer.sanitizePasteControls(whole[0..<2]), d([0x61, 0xC2]))
    }

    // MARK: - stripBidiOverrides

    func testBidi_emptyAndClean() {
        XCTAssertEqual(PasteSanitizer.stripBidiOverrides(Data()), Data())
        let clean = Array("plain ascii\n┌──┐ • → — ✓ é Ω".utf8)
        XCTAssertEqual(PasteSanitizer.stripBidiOverrides(d(clean)), d(clean))
    }

    func testBidi_strippedCodepoints() {
        let stripped: [[UInt8]] = [
            [0xC2, 0xAD],                     // U+00AD
            [0xD8, 0x9C],                     // U+061C
            [0xE1, 0xA0, 0x8E],               // U+180E
            [0xE2, 0x80, 0x8B], [0xE2, 0x80, 0x8C], [0xE2, 0x80, 0x8D],
            [0xE2, 0x80, 0x8E], [0xE2, 0x80, 0x8F],
            [0xE2, 0x80, 0xA8], [0xE2, 0x80, 0xA9],
            [0xE2, 0x80, 0xAA], [0xE2, 0x80, 0xAB], [0xE2, 0x80, 0xAC],
            [0xE2, 0x80, 0xAD], [0xE2, 0x80, 0xAE],
            [0xE2, 0x81, 0xA0],
            [0xE2, 0x81, 0xA6], [0xE2, 0x81, 0xA7], [0xE2, 0x81, 0xA8], [0xE2, 0x81, 0xA9],
            [0xEF, 0xBB, 0xBF],
            [0xF3, 0xA0, 0x80, 0x80], [0xF3, 0xA0, 0x80, 0xBF],
            [0xF3, 0xA0, 0x81, 0x80], [0xF3, 0xA0, 0x81, 0xBF],
        ]
        for seq in stripped {
            XCTAssertEqual(PasteSanitizer.stripBidiOverrides(d([0x61] + seq + [0x62])),
                           d([0x61, 0x62]), "should strip \(seq)")
            XCTAssertEqual(PasteSanitizer.stripBidiOverrides(d(seq)), Data(), "lone \(seq)")
            // Back-to-back and at the very end.
            XCTAssertEqual(PasteSanitizer.stripBidiOverrides(d(seq + seq + [0x63])), d([0x63]))
        }
    }

    func testBidi_nearMissesPreserved() {
        let preserved: [[UInt8]] = [
            [0xC2, 0xAC], [0xC2, 0xAE], [0xC2, 0xA0],        // neighbours of SHY
            [0xD8, 0x9B], [0xD8, 0x9D],                      // neighbours of ALM
            [0xE1, 0xA0, 0x8D], [0xE1, 0xA0, 0x8F], [0xE1, 0xA1, 0x8E],
            [0xE2, 0x80, 0x8A], [0xE2, 0x80, 0x90],          // hair space, hyphen
            [0xE2, 0x80, 0xA7], [0xE2, 0x80, 0xAF],
            [0xE2, 0x81, 0x9F], [0xE2, 0x81, 0xA1], [0xE2, 0x81, 0xA5], [0xE2, 0x81, 0xAA],
            [0xE2, 0x82, 0xA0], [0xE2, 0x94, 0x80], [0xE2, 0x94, 0x82], // box drawing
            [0xE2, 0x9C, 0x93],                              // check mark
            [0xEF, 0xBB, 0xBE], [0xEF, 0xBB, 0xC0], [0xEF, 0xBA, 0xBF],
            [0xEF, 0xB8, 0x8F], [0xEF, 0xB8, 0x80],          // VS16 / VS1 preserved
            [0xF3, 0xA0, 0x84, 0x80], [0xF3, 0xA0, 0x87, 0xAF], // VS17 / VS256 preserved
            [0xF3, 0xA0, 0x82, 0x80],                        // between tag block and VS17
            [0xF3, 0xA1, 0x80, 0x80],
            [0xF3, 0xA0, 0x80, 0x41],                        // S3-005: non-continuation b3
            [0xF3, 0xA0, 0x81, 0x7F],
            [0xF3, 0xA0, 0x80, 0xC0],
            [0xF0, 0x9F, 0x98, 0x80],                        // emoji
        ]
        for seq in preserved {
            XCTAssertEqual(PasteSanitizer.stripBidiOverrides(d(seq)), d(seq), "should preserve \(seq)")
            XCTAssertEqual(PasteSanitizer.stripBidiOverrides(d([0x61] + seq + [0x62])),
                           d([0x61] + seq + [0x62]), "should preserve embedded \(seq)")
        }
    }

    func testBidi_truncatedLeadsAtEndArePreserved() {
        let truncated: [[UInt8]] = [
            [0xC2], [0xD8], [0xE1], [0xE1, 0xA0], [0xE2], [0xE2, 0x80], [0xE2, 0x81],
            [0xEF], [0xEF, 0xBB], [0xF3], [0xF3, 0xA0], [0xF3, 0xA0, 0x80],
        ]
        for seq in truncated {
            XCTAssertEqual(PasteSanitizer.stripBidiOverrides(d(seq)), d(seq), "truncated \(seq)")
            XCTAssertEqual(PasteSanitizer.stripBidiOverrides(d([0x61, 0x62] + seq)),
                           d([0x61, 0x62] + seq), "truncated tail \(seq)")
        }
    }

    func testBidi_f3NonContinuationDoesNotOverConsume() {
        // F3 A0 80 41 -> all four bytes preserved (the 'A' must survive).
        XCTAssertEqual(PasteSanitizer.stripBidiOverrides(d([0xF3, 0xA0, 0x80, 0x41, 0x42])),
                       d([0xF3, 0xA0, 0x80, 0x41, 0x42]))
    }

    func testBidi_overlappingLeads() {
        // C2 followed by C2 AD: first C2 preserved, second pair stripped.
        XCTAssertEqual(PasteSanitizer.stripBidiOverrides(d([0xC2, 0xC2, 0xAD])), d([0xC2]))
        // E2 E2 80 8B -> first E2 preserved.
        XCTAssertEqual(PasteSanitizer.stripBidiOverrides(d([0xE2, 0xE2, 0x80, 0x8B])), d([0xE2]))
        // F3 F3 A0 80 80 -> first F3 preserved, tag stripped.
        XCTAssertEqual(PasteSanitizer.stripBidiOverrides(d([0xF3, 0xF3, 0xA0, 0x80, 0x80])), d([0xF3]))
        // Stripping must not splice neighbours into a new match: E2 80 + (U+00AD) + 8B.
        XCTAssertEqual(PasteSanitizer.stripBidiOverrides(d([0xE2, 0x80, 0xC2, 0xAD, 0x8B])),
                       d([0xE2, 0x80, 0x8B]))
    }

    func testBidi_transcriptStyleTextKeepsBoxDrawingAndStripsHidden() {
        let text = "┌─ ok ─┐\n│ \u{2022} item\u{200B} → done\u{202E} │\n└──────┘ \u{FEFF}"
        let expected = "┌─ ok ─┐\n│ \u{2022} item → done │\n└──────┘ "
        XCTAssertEqual(PasteSanitizer.stripBidiOverrides(Data(text.utf8)), Data(expected.utf8))
    }

    func testBidi_slices() {
        XCTAssertEqual(PasteSanitizer.stripBidiOverrides(slice([0x61, 0xE2, 0x80, 0x8B, 0x62])),
                       d([0x61, 0x62]))
        // Slice ends mid-sequence; the backing store would complete a match.
        let whole = d([0x61, 0xE2, 0x80, 0x8B])
        XCTAssertEqual(PasteSanitizer.stripBidiOverrides(whole[0..<3]), d([0x61, 0xE2, 0x80]))
        let whole4 = d([0x61, 0xF3, 0xA0, 0x80, 0x80])
        XCTAssertEqual(PasteSanitizer.stripBidiOverrides(whole4[0..<4]), d([0x61, 0xF3, 0xA0, 0x80]))
        // Slice starts after a lead byte: the continuation bytes alone are not a match.
        let whole2 = d([0xE2, 0x80, 0x8B, 0x62])
        XCTAssertEqual(PasteSanitizer.stripBidiOverrides(whole2[1...]), d([0x80, 0x8B, 0x62]))
        // Padding on both sides.
        XCTAssertEqual(PasteSanitizer.stripBidiOverrides(slice([0xC2, 0xAD], padBefore: 5, padAfter: 5)), Data())
    }

    // MARK: - sanitizeBracketedPaste

    private let term: [UInt8] = [0x1B, 0x5B, 0x32, 0x30, 0x31, 0x7E]

    func testBracketed_emptyShortAndClean() {
        XCTAssertEqual(PasteSanitizer.sanitizeBracketedPaste(Data()), Data())
        XCTAssertEqual(PasteSanitizer.sanitizeBracketedPaste(d([0x1B, 0x5B])), d([0x1B, 0x5B]))
        XCTAssertEqual(PasteSanitizer.sanitizeBracketedPaste(d([0x61, 0x62, 0x63, 0x64, 0x65, 0x66, 0x67])),
                       d([0x61, 0x62, 0x63, 0x64, 0x65, 0x66, 0x67]))
    }

    func testBracketed_terminatorRemovedExactly() {
        XCTAssertEqual(PasteSanitizer.sanitizeBracketedPaste(d(term)), Data())
        XCTAssertEqual(PasteSanitizer.sanitizeBracketedPaste(d([0x61] + term + [0x62])), d([0x61, 0x62]))
        XCTAssertEqual(PasteSanitizer.sanitizeBracketedPaste(d(term + term)), Data())
        XCTAssertEqual(PasteSanitizer.sanitizeBracketedPaste(d(term + [0x61])), d([0x61]))
        XCTAssertEqual(PasteSanitizer.sanitizeBracketedPaste(d([0x61] + term)), d([0x61]))
    }

    func testBracketed_openMarkerAndNearMissesPreserved() {
        let open: [UInt8] = [0x1B, 0x5B, 0x32, 0x30, 0x30, 0x7E]   // ESC[200~
        XCTAssertEqual(PasteSanitizer.sanitizeBracketedPaste(d(open)), d(open))
        let nearMiss: [UInt8] = [0x1B, 0x5B, 0x32, 0x30, 0x31, 0x41] // ESC[201A
        XCTAssertEqual(PasteSanitizer.sanitizeBracketedPaste(d(nearMiss)), d(nearMiss))
        let partialAtEnd: [UInt8] = [0x61, 0x62, 0x1B, 0x5B, 0x32, 0x30, 0x31] // ESC[201 (no ~)
        XCTAssertEqual(PasteSanitizer.sanitizeBracketedPaste(d(partialAtEnd)), d(partialAtEnd))
        let noEsc: [UInt8] = [0x5B, 0x32, 0x30, 0x31, 0x7E, 0x61]    // [201~ without ESC
        XCTAssertEqual(PasteSanitizer.sanitizeBracketedPaste(d(noEsc)), d(noEsc))
    }

    func testBracketed_escBeforeTerminatorSurvivesAndNoSplice() {
        // ESC ESC[201~ -> a lone ESC remains.
        XCTAssertEqual(PasteSanitizer.sanitizeBracketedPaste(d([0x1B] + term)), d([0x1B]))
        // Removal must not be re-scanned: ESC[2 + ESC[201~ + 01~ -> ESC[2 01~ (no new terminator).
        let input: [UInt8] = [0x1B, 0x5B, 0x32] + term + [0x30, 0x31, 0x7E]
        XCTAssertEqual(PasteSanitizer.sanitizeBracketedPaste(d(input)),
                       d([0x1B, 0x5B, 0x32, 0x30, 0x31, 0x7E]))
    }

    func testBracketed_slices() {
        XCTAssertEqual(PasteSanitizer.sanitizeBracketedPaste(slice([0x61] + term + [0x62])), d([0x61, 0x62]))
        // Slice cuts the terminator off before its final byte.
        let whole = d([0x61] + term)
        XCTAssertEqual(PasteSanitizer.sanitizeBracketedPaste(whole[0..<(whole.count - 1)]),
                       d([0x61, 0x1B, 0x5B, 0x32, 0x30, 0x31]))
        // Slice that starts mid-terminator.
        XCTAssertEqual(PasteSanitizer.sanitizeBracketedPaste(whole[2...]), d([0x5B, 0x32, 0x30, 0x31, 0x7E]))
    }

    // MARK: - Pipeline order (normalize -> controls -> bidi [-> bracketed | loneCR])

    private func pipeline(_ x: Data, bracketed: Bool) -> Data {
        let a = PasteSanitizer.normalizePasteLineEndings(x)
        let b = PasteSanitizer.sanitizePasteControls(a)
        let c = PasteSanitizer.stripBidiOverrides(b)
        return bracketed ? PasteSanitizer.sanitizeBracketedPaste(c) : PasteSanitizer.convertLoneCRToLF(c)
    }

    func testPipeline_documentedEndToEnd() {
        // CRLF -> LF; ESC -> space; ZWSP stripped; lone CR -> LF when not bracketed.
        let input = d([0x61, 0x0D, 0x0A, 0x1B, 0x5B, 0x32, 0x30, 0x31, 0x7E,
                       0xE2, 0x80, 0x8B, 0x62, 0x0D, 0x63])
        XCTAssertEqual(pipeline(input, bracketed: true),
                       d([0x61, 0x0A, 0x20, 0x5B, 0x32, 0x30, 0x31, 0x7E, 0x62, 0x0D, 0x63]))
        XCTAssertEqual(pipeline(input, bracketed: false),
                       d([0x61, 0x0A, 0x20, 0x5B, 0x32, 0x30, 0x31, 0x7E, 0x62, 0x0A, 0x63]))
    }

    func testPipeline_c1ReplacementDoesNotFormBidiMatch() {
        // E2 80 C2 9B 8B: controls turn C2 9B into a space, so no E2 80 8B forms.
        let out = pipeline(d([0xE2, 0x80, 0xC2, 0x9B, 0x8B]), bracketed: true)
        XCTAssertEqual(out, d([0xE2, 0x80, 0x20, 0x8B]))
    }

    // MARK: - Large buffers

    func testLargeCleanAsciiIsReturnedUnchanged() {
        // 128 KiB; mix of LF/TAB, no CR, no C0, no high bytes.
        var bytes = [UInt8]()
        bytes.reserveCapacity(128 * 1024)
        while bytes.count < 128 * 1024 {
            bytes += Array("the quick brown fox\tjumps\n".utf8)
        }
        let input = d(bytes)
        XCTAssertEqual(PasteSanitizer.normalizePasteLineEndings(input), input)
        XCTAssertEqual(PasteSanitizer.sanitizePasteControls(input), input)
        XCTAssertEqual(PasteSanitizer.stripBidiOverrides(input), input)
        XCTAssertEqual(PasteSanitizer.sanitizeBracketedPaste(input), input)
        XCTAssertEqual(PasteSanitizer.convertLoneCRToLF(input), input)
    }

    func testLargeTranscriptTextMatchesOracle() {
        // E2-heavy "Claude Code transcript" text with sparse hidden/control bytes.
        var rng = BlindSplitMix(seed: 0x7A57E5)
        let units: [[UInt8]] = [
            Array("│ ".utf8), Array("──".utf8), Array("• ".utf8), Array("→ ".utf8),
            Array("hello ".utf8), [0x0A], [0x0D, 0x0A], [0x09],
            [0xE2, 0x80, 0x8B], [0xC2, 0xAD], [0x1B], [0xC2, 0x9B], [0xEF, 0xBB, 0xBF],
            [0xF3, 0xA0, 0x80, 0x80], [0xE2, 0x80],
        ]
        var bytes = [UInt8]()
        bytes.reserveCapacity(132 * 1024)
        while bytes.count < 128 * 1024 {
            // 90% benign units (first 7), 10% adversarial.
            let r = Int(rng.next() % 100)
            let idx = r < 90 ? Int(rng.next() % 8) : 8 + Int(rng.next() % UInt64(units.count - 8))
            bytes += units[idx]
        }
        let input = d(bytes)
        XCTAssertEqual(PasteSanitizer.normalizePasteLineEndings(input), d(RefPaste.normalize(bytes)))
        XCTAssertEqual(PasteSanitizer.sanitizePasteControls(input), d(RefPaste.controls(bytes)))
        XCTAssertEqual(PasteSanitizer.stripBidiOverrides(input), d(RefPaste.bidi(bytes)))
        XCTAssertEqual(PasteSanitizer.sanitizeBracketedPaste(input), d(RefPaste.bracketed(bytes)))
        XCTAssertEqual(PasteSanitizer.convertLoneCRToLF(input), d(RefPaste.loneCR(bytes)))
        XCTAssertEqual(pipeline(input, bracketed: true), d(RefPaste.pipeline(bytes, bracketed: true)))
        XCTAssertEqual(pipeline(input, bracketed: false), d(RefPaste.pipeline(bytes, bracketed: false)))
    }

    // MARK: - Differential vs. reference oracle (seeded random)

    /// Edge-heavy alphabet: every byte that any rule branches on, plus fillers.
    private static let alphabet: [UInt8] = [
        0x41, 0x20, 0x09, 0x0A, 0x0D, 0x00, 0x03, 0x1A, 0x1B, 0x5B, 0x32, 0x30, 0x31, 0x7E, 0x7F,
        0x80, 0x81, 0x8B, 0x8C, 0x8D, 0x8E, 0x8F, 0x90, 0x9B, 0x9C, 0x9D, 0x9F,
        0xA0, 0xA6, 0xA8, 0xA9, 0xAA, 0xAD, 0xAE, 0xB8, 0xBB, 0xBF, 0xC0,
        0xC2, 0xD8, 0xE1, 0xE2, 0xEF, 0xF3, 0xF0, 0xFF, 0x94,
    ]

    /// Whole sequences the rules recognise (so random streams hit real matches).
    private static let sequences: [[UInt8]] = [
        [0xC2, 0xAD], [0xC2, 0x80], [0xC2, 0x9F], [0xC2, 0xA0], [0xD8, 0x9C],
        [0xE1, 0xA0, 0x8E], [0xE2, 0x80, 0x8B], [0xE2, 0x80, 0x8F], [0xE2, 0x80, 0xA8],
        [0xE2, 0x80, 0xAE], [0xE2, 0x81, 0xA0], [0xE2, 0x81, 0xA6], [0xE2, 0x81, 0xA9],
        [0xE2, 0x94, 0x80], [0xEF, 0xBB, 0xBF], [0xEF, 0xB8, 0x8F],
        [0xF3, 0xA0, 0x80, 0x80], [0xF3, 0xA0, 0x81, 0xBF], [0xF3, 0xA0, 0x80, 0x41],
        [0xF3, 0xA0, 0x84, 0x80],
        [0x1B, 0x5B, 0x32, 0x30, 0x31, 0x7E], [0x1B, 0x5B, 0x32, 0x30, 0x30, 0x7E],
        [0x0D, 0x0A], [0x0D, 0x0D, 0x0A],
    ]

    private func randomBytes(_ rng: inout BlindSplitMix, maxLen: Int) -> [UInt8] {
        let n = Int(rng.next() % UInt64(maxLen + 1))
        var out = [UInt8]()
        out.reserveCapacity(n + 4)
        while out.count < n {
            if rng.next() % 4 == 0 {
                out += Self.sequences[Int(rng.next() % UInt64(Self.sequences.count))]
            } else {
                out.append(Self.alphabet[Int(rng.next() % UInt64(Self.alphabet.count))])
            }
        }
        // Frequently chop a random number of bytes off the end so multi-byte
        // sequences are truncated at the buffer boundary.
        if !out.isEmpty && rng.next() % 3 == 0 {
            out.removeLast(Int(rng.next() % UInt64(min(out.count, 5))) )
        }
        return out
    }

    func testDifferentialAgainstReferenceOracle() {
        var rng = BlindSplitMix(seed: 0xB1ACB1D)
        for caseIndex in 0..<2400 {
            let maxLen = caseIndex < 2000 ? 24 : 4096
            let bytes = randomBytes(&rng, maxLen: maxLen)

            // Variant A: fresh zero-based Data. Variant B: slice with non-zero
            // startIndex and with trailing backing bytes beyond the slice end
            // (which must never be read as part of the payload).
            let padBefore = Int(rng.next() % 4)
            let padAfter = Int(rng.next() % 4)
            let variants: [Data] = [d(bytes), slice(bytes, padBefore: padBefore + 1, padAfter: padAfter)]

            for (vi, input) in variants.enumerated() {
                let tag = "case \(caseIndex) variant \(vi) bytes=\(bytes)"
                XCTAssertEqual(PasteSanitizer.normalizePasteLineEndings(input),
                               d(RefPaste.normalize(bytes)), "normalize \(tag)")
                XCTAssertEqual(PasteSanitizer.sanitizePasteControls(input),
                               d(RefPaste.controls(bytes)), "controls \(tag)")
                XCTAssertEqual(PasteSanitizer.stripBidiOverrides(input),
                               d(RefPaste.bidi(bytes)), "bidi \(tag)")
                XCTAssertEqual(PasteSanitizer.sanitizeBracketedPaste(input),
                               d(RefPaste.bracketed(bytes)), "bracketed \(tag)")
                XCTAssertEqual(PasteSanitizer.convertLoneCRToLF(input),
                               d(RefPaste.loneCR(bytes)), "loneCR \(tag)")
                XCTAssertEqual(pipeline(input, bracketed: true),
                               d(RefPaste.pipeline(bytes, bracketed: true)), "pipeline-b \(tag)")
                XCTAssertEqual(pipeline(input, bracketed: false),
                               d(RefPaste.pipeline(bytes, bracketed: false)), "pipeline-p \(tag)")
            }
        }
    }

    /// Exhaustive over all 2-byte and 3-byte-with-lead combinations drawn from
    /// the lead/continuation bytes the rules care about (cheap: 16^3 = 4096).
    func testExhaustiveSmallCombinationsMatchOracle() {
        let bytes: [UInt8] = [0xC2, 0xD8, 0xE1, 0xE2, 0xEF, 0xF3, 0x80, 0x81, 0x8B, 0xA0,
                              0xA8, 0xAD, 0xBB, 0xBF, 0x1B, 0x0D]
        for a in bytes {
            for b in bytes {
                for c in bytes {
                    let arr = [a, b, c]
                    let input = d(arr)
                    XCTAssertEqual(PasteSanitizer.stripBidiOverrides(input), d(RefPaste.bidi(arr)), "bidi \(arr)")
                    XCTAssertEqual(PasteSanitizer.sanitizePasteControls(input), d(RefPaste.controls(arr)), "ctl \(arr)")
                    XCTAssertEqual(PasteSanitizer.normalizePasteLineEndings(input), d(RefPaste.normalize(arr)), "norm \(arr)")
                }
            }
        }
        // 4-byte tag-block shapes: F3 A0 {80,81,82} {00,41,7F,80,BF,C0}
        for b2 in [UInt8(0x7F), 0x80, 0x81, 0x82, 0x84] {
            for b3 in [UInt8(0x00), 0x41, 0x7F, 0x80, 0xBF, 0xC0, 0xF3] {
                let arr: [UInt8] = [0xF3, 0xA0, b2, b3]
                XCTAssertEqual(PasteSanitizer.stripBidiOverrides(d(arr)), d(RefPaste.bidi(arr)), "tag \(arr)")
                XCTAssertEqual(PasteSanitizer.stripBidiOverrides(d(arr + [0x41])),
                               d(RefPaste.bidi(arr + [0x41])), "tag+A \(arr)")
            }
        }
    }
}

// MARK: - Reference oracle (independent, naive [UInt8] implementation)

/// Straightforward re-statement of the documented byte rules over `[UInt8]`.
/// Intentionally written with explicit bounds checks (`i + n <= count`) and no
/// shared code with `PasteSanitizer`.
private enum RefPaste {
    static func loneCR(_ x: [UInt8]) -> [UInt8] {
        x.map { $0 == 0x0D ? 0x0A : $0 }
    }

    static func normalize(_ x: [UInt8]) -> [UInt8] {
        var out = [UInt8]()
        var i = 0
        while i < x.count {
            if x[i] == 0x0D, i + 1 < x.count, x[i + 1] == 0x0A {
                out.append(0x0A)
                i += 2
            } else {
                out.append(x[i])
                i += 1
            }
        }
        return out
    }

    static func controls(_ x: [UInt8]) -> [UInt8] {
        var out = [UInt8]()
        var i = 0
        while i < x.count {
            let b = x[i]
            if b == 0x09 || b == 0x0A || b == 0x0D {
                out.append(b); i += 1
            } else if b < 0x20 || b == 0x7F {
                out.append(0x20); i += 1
            } else if b == 0xC2, i + 1 < x.count, x[i + 1] >= 0x80, x[i + 1] <= 0x9F {
                out.append(0x20); i += 2
            } else {
                out.append(b); i += 1
            }
        }
        return out
    }

    static func bidi(_ x: [UInt8]) -> [UInt8] {
        var out = [UInt8]()
        var i = 0
        while i < x.count {
            let b0 = x[i]
            func at(_ k: Int) -> UInt8? { i + k < x.count ? x[i + k] : nil }
            var skip = 0
            if let b1 = at(1) {
                if (b0 == 0xC2 && b1 == 0xAD) || (b0 == 0xD8 && b1 == 0x9C) { skip = 2 }
            }
            if skip == 0, let b1 = at(1), let b2 = at(2) {
                if b0 == 0xE1 && b1 == 0xA0 && b2 == 0x8E { skip = 3 }
                else if b0 == 0xE2 && b1 == 0x80 && (0x8B...0x8F).contains(b2) { skip = 3 }
                else if b0 == 0xE2 && b1 == 0x80 && (0xA8...0xAE).contains(b2) { skip = 3 }
                else if b0 == 0xE2 && b1 == 0x81 && (b2 == 0xA0 || (0xA6...0xA9).contains(b2)) { skip = 3 }
                else if b0 == 0xEF && b1 == 0xBB && b2 == 0xBF { skip = 3 }
            }
            if skip == 0, b0 == 0xF3, let b1 = at(1), let b2 = at(2), let b3 = at(3) {
                if b1 == 0xA0 && (b2 == 0x80 || b2 == 0x81) && (0x80...0xBF).contains(b3) { skip = 4 }
            }
            if skip > 0 {
                i += skip
            } else {
                out.append(b0)
                i += 1
            }
        }
        return out
    }

    static func bracketed(_ x: [UInt8]) -> [UInt8] {
        let t: [UInt8] = [0x1B, 0x5B, 0x32, 0x30, 0x31, 0x7E]
        var out = [UInt8]()
        var i = 0
        while i < x.count {
            if i + t.count <= x.count, x[i] == t[0], x[i + 1] == t[1], x[i + 2] == t[2],
               x[i + 3] == t[3], x[i + 4] == t[4], x[i + 5] == t[5] {
                i += t.count
            } else {
                out.append(x[i])
                i += 1
            }
        }
        return out
    }

    static func pipeline(_ x: [UInt8], bracketed useBracketed: Bool) -> [UInt8] {
        let c = bidi(controls(normalize(x)))
        return useBracketed ? bracketed(c) : loneCR(c)
    }
}

/// Deterministic PRNG (SplitMix64) — the suite must be reproducible.
private struct BlindSplitMix: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
