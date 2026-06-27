import XCTest
@testable import Blackbird
@testable import BBCore

/// FFI-boundary drift detector for the OSC 8 invisible-scalar blocklist.
///
/// `OSC8URLPolicy.containsPercentEncodedControlBytes` (private, exercised
/// here through the public `OSC8URLPolicy.isAllowed`) hand-maintains ~11
/// percent-encoded regexes that mirror, byte-for-byte, the Rust core's
/// canonical bidi / zero-width / invisible scalar set in
/// `core/src/scrub.rs::is_bidi_or_invisible_scalar`. The two live on
/// opposite sides of the cbindgen FFI boundary with no shared compile-time
/// source, so they can silently drift: a scalar added to the core set would
/// NOT automatically be caught by the Swift gate, re-opening the
/// invisible-character spoof the gate exists to close.
///
/// `bb_is_bidi_or_invisible_scalar` (added to `core/src/lib.rs`) exposes the
/// core's canonical predicate across the FFI as the single source of truth.
/// This test pins the Swift percent-encoded blocklist against it:
///
///   For EVERY scalar the core classifies as bidi/invisible, the
///   percent-encoded UTF-8 form of that scalar embedded in an otherwise
///   benign `https://example.com/<encoded>` URL MUST be rejected by
///   `OSC8URLPolicy.isAllowed`.
///
/// If the core set ever gains a scalar whose percent-encoded form the Swift
/// regexes miss, this test FAILS, naming the exact scalar — surfacing the
/// drift at CI time instead of in production. The fix for such a failure is
/// to bring the Swift regexes back into parity (a deliberate behavior
/// change), NOT to weaken this test.
///
/// Note: the Swift regexes deliberately OVER-block a few reserved-but-
/// invisible ranges (e.g. U+E0080..U+E00FF, U+E01F0..U+E01FF). That is a
/// superset relationship in the safe direction, so this test only pins the
/// "core ⊆ Swift-rejected" containment — it intentionally does not assert
/// the converse.
final class HyperlinkResolverParityTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        TestHostTermination.shared.register()
    }

    /// The canonical bidi / zero-width / invisible code-point ranges, mirrored
    /// from `core/src/scrub.rs::is_bidi_or_invisible_scalar`. Iterated as the
    /// positive set: every scalar here must be (a) classified true by the FFI
    /// predicate and (b) rejected by the Swift percent-encoded gate.
    private static let coreBidiInvisibleRanges: [ClosedRange<UInt32>] = [
        0x00AD...0x00AD,   // SOFT HYPHEN
        0x061C...0x061C,   // ARABIC LETTER MARK
        0x180E...0x180E,   // MONGOLIAN VOWEL SEPARATOR
        0x200B...0x200F,   // ZWSP / ZWNJ / ZWJ / LRM / RLM
        0x2028...0x202E,   // LS / PS / LRE / RLE / PDF / LRO / RLO
        0x2060...0x2060,   // WORD JOINER
        0x2066...0x2069,   // LRI / RLI / FSI / PDI
        0xFE00...0xFE0F,   // VARIATION SELECTOR-1..16
        0xFEFF...0xFEFF,   // BOM / ZWNBSP
        0xE0000...0xE007F, // TAG block
        0xE0100...0xE01EF, // VARIATION SELECTOR-17..256
    ]

    /// Percent-encode a scalar's UTF-8 bytes the same way Foundation preserves
    /// them in `URL.absoluteString` — every byte as `%XX` (uppercase hex).
    /// Returns nil only when `s` is not a valid Unicode scalar (surrogate /
    /// out of range), which the caller treats as "nothing to encode".
    private func percentEncodedUTF8(_ s: UInt32) -> String? {
        guard let scalar = UnicodeScalar(s) else { return nil }
        var out = ""
        for byte in Array(String(scalar).utf8) {
            out += "%" + String(format: "%02X", byte)
        }
        return out
    }

    private func u(_ s: UInt32) -> String { String(format: "U+%04X", s) }

    // MARK: - Positive parity: core-rejected ⇒ Swift-rejected

    /// Drift detector. For every scalar in the core's canonical set, assert
    /// the FFI predicate agrees AND the percent-encoded form is blocked by
    /// the Swift OSC 8 gate. A failure here is a genuine FFI-boundary gap.
    func testCoreBidiInvisibleScalars_areRejectedBySwiftPercentEncodedGate() {
        var checked = 0
        for range in Self.coreBidiInvisibleRanges {
            for s in range {
                // The FFI single-source-of-truth must classify every scalar
                // in these ranges as bidi/invisible — pins the Rust predicate
                // and that the FFI marshalling is correct.
                let isCore = bb_is_bidi_or_invisible_scalar(s)
                XCTAssertTrue(
                    isCore,
                    "\(u(s)): core FFI predicate must classify this as bidi/invisible"
                )
                guard isCore else { continue }

                guard let encoded = percentEncodedUTF8(s) else {
                    XCTFail("\(u(s)): could not form a Unicode scalar to percent-encode")
                    continue
                }
                let raw = "https://example.com/" + encoded
                guard let url = URL(string: raw) else {
                    // Every input here is pure-ASCII `%XX` in the path of an
                    // otherwise valid URL, so Foundation always parses it; a
                    // nil means the encoded form can't reach NSWorkspace at
                    // all, which is itself safe — but surface it loudly so a
                    // silently-unconstructable case never masks a real gap.
                    XCTFail("\(u(s)): URL(string:) unexpectedly rejected \(raw)")
                    continue
                }
                XCTAssertFalse(
                    OSC8URLPolicy.isAllowed(url),
                    """
                    FFI DRIFT: core classifies \(u(s)) as bidi/invisible but the \
                    Swift percent-encoded blocklist did NOT reject its encoded \
                    form \(raw). The HyperlinkResolver regexes have drifted from \
                    core/src/scrub.rs::is_bidi_or_invisible_scalar — bring them \
                    back into parity (do not weaken this test).
                    """
                )
                checked += 1
            }
        }
        // Guard against the loop silently iterating nothing (e.g. a future
        // edit that empties the range table) and passing vacuously.
        XCTAssertGreaterThan(
            checked, 400,
            "parity sweep must cover the full canonical scalar set"
        )
    }

    // MARK: - Negative controls

    /// Sanity: visible / ordinary scalars are NOT in the core's invisible
    /// set. Pins that the FFI predicate isn't an always-true stub, so the
    /// positive sweep above is meaningful. (`isAllowed` may reject these for
    /// unrelated reasons — IDN, etc. — when placed in a host, so we assert
    /// only the core-side classification here.)
    func testNonBidiScalars_areNotClassifiedByCore() {
        let negativeControls: [UInt32] = [
            0x0041,   // 'A'
            0x0031,   // '1'
            0x0020,   // SPACE
            0x002F,   // '/'
            0x00E9,   // 'é'  (visible accented latin)
            0x2713,   // '✓'  (visible check mark)
            0x4E00,   // '中' (CJK)
            0x1F600,  // '😀' (emoji, visible)
        ]
        for s in negativeControls {
            XCTAssertFalse(
                bb_is_bidi_or_invisible_scalar(s),
                "\(u(s)): a visible/ordinary scalar must NOT be classified bidi/invisible"
            )
        }
    }

    /// Companion to the negative controls: a few clearly-visible non-ASCII
    /// scalars whose percent-encoded form sits in the URL PATH (not the host,
    /// so the IDN gate stays out of it) must still be ALLOWED. This pins that
    /// the percent-encoded blocklist does not over-block legitimate visible
    /// glyphs — the same boundary the existing
    /// `testOsc8UrlAllowlistAcceptsLegitimatePercentEncoded` guards, restated
    /// here against the core predicate's "false" verdict.
    func testVisibleScalars_percentEncodedInPath_areAllowed() {
        for s: UInt32 in [0x00E9 /* é */, 0x2713 /* ✓ */, 0x4E00 /* 中 */] {
            XCTAssertFalse(
                bb_is_bidi_or_invisible_scalar(s),
                "\(u(s)): negative-control precondition — core must classify false"
            )
            guard let encoded = percentEncodedUTF8(s) else {
                XCTFail("\(u(s)): could not percent-encode")
                continue
            }
            let raw = "https://example.com/" + encoded
            guard let url = URL(string: raw) else {
                XCTFail("\(u(s)): URL(string:) rejected \(raw)")
                continue
            }
            XCTAssertTrue(
                OSC8URLPolicy.isAllowed(url),
                "\(u(s)): visible glyph percent-encoded in the path must remain allowed: \(raw)"
            )
        }
    }

    /// Boundary scalars just OUTSIDE the canonical ranges are correctly
    /// classified false by the FFI predicate — pins the range edges so an
    /// off-by-one in either the Rust `matches!` arms or the Swift mirror is
    /// caught. (These adjacent scalars are visible/assigned; the Swift gate's
    /// deliberate over-blocking of reserved ranges is documented in the type
    /// comment and intentionally not asserted here.)
    func testRangeBoundaries_justOutsideAreNotClassified() {
        let justOutside: [UInt32] = [
            0x00AC,   // ¬ (just below SOFT HYPHEN)
            0x00AE,   // ® (just above SOFT HYPHEN)
            0x200A,   // HAIR SPACE (just below ZWSP run)
            0x2010,   // HYPHEN (just above U+200F)
            0x2027,   // HYPHENATION POINT (just below U+2028)
            0x202F,   // NARROW NO-BREAK SPACE (just above U+202E)
            0x2065,   // unassigned (just below WORD JOINER+1 boundary)
            0x205F,   // MEDIUM MATHEMATICAL SPACE (just below U+2060)
            0xFDFF,   // (just below the BOM-adjacent FE00 run)
            0xFEFE,   // (just below the BOM)
            0xFF00,   // FULLWIDTH ... (just above the BOM)
        ]
        for s in justOutside {
            XCTAssertFalse(
                bb_is_bidi_or_invisible_scalar(s),
                "\(u(s)): scalar outside the canonical ranges must classify false"
            )
        }
    }
}
