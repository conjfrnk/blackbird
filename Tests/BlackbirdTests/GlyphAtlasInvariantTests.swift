import XCTest
import Metal
import AppKit
@testable import Blackbird

/// Edge-case and known-limitation pins for `GlyphAtlas`. Complements
/// the broader behavioural coverage in `GlyphAtlasTests.swift` with
/// the corner cases the v0.1.9 sweep flagged as gaps:
///
///   - `TST-S4-001` (high): capacity = 1 — the next-slot wrap
///     arithmetic at the smallest valid atlas size.
///   - `TST-S4-005` (medium): wide insert at the last two slots of
///     the atlas — the alignment skip must either succeed or refuse
///     gracefully.
///   - `F-S4-005` (medium): grapheme-cluster routing (ZWJ family
///     emoji, regional-indicator flags). The atlas is keyed on a
///     single Unicode scalar; clusters render piecewise. This is a
///     known limitation acknowledged in the F-S4 audit; pin the
///     behaviour so a future fix doesn't silently change it without
///     updating KNOWN_ISSUES.md or removing the limitation note.
///
/// **Memory pre-flight** (per MEMORY `feedback_test_memory_safety`):
/// every test in this file constructs at most one GlyphAtlas at
/// capacity ≤ 128 with default 13pt font. At 1× scale each cell is
/// ~8×18 px; the resulting texture is ≤ ~50 KiB; the color companion
/// at 4 bytes/px is ≤ ~200 KiB. Two textures × one atlas × one test
/// ≈ 250 KiB. Well under the 256 MB budget enforced by
/// `requireTestFitsInBudget` in `MemoryBudget.swift`.
///
/// **GPU pre-flight:** every test is gated on `requireMetalDevice()`
/// per the existing GlyphAtlasTests idiom. Headless CI runners that
/// genuinely lack a GPU (rare on macOS) can set `BLACKBIRD_NO_METAL=1`
/// to XCTSkip; otherwise missing Metal is a test failure.
final class GlyphAtlasInvariantTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        TestHostTermination.shared.register()
    }

    // MARK: - Capacity edge cases (TST-S4-001 + TST-S4-005)

    /// Capacity = 1 is the minimum valid atlas. A single slot must
    /// accept exactly one narrow insert; the second insert triggers
    /// saturation flush + re-insert (per F3 fix pinned in the
    /// existing `test_saturation_flushesAndReinserts`). This pins
    /// the single-slot edge that the existing capacity-4 saturation
    /// test does not exercise: the flush-then-reinsert path on a
    /// 1-slot atlas must not divide-by-zero on `slot % slotCols` or
    /// `slot / slotCols` when slotCols == 1 (the edge case alacritty's
    /// CompletedGrid analogue traps for sqrt(1) = 1 row × 1 col).
    func test_capacityOne_acceptsOneInsert_thenFlushOnOverflow() throws {
        let device = try requireMetalDevice()
        let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        let metrics = CellMetrics(font: font)
        // Capacity 1 is the smallest non-degenerate size. The atlas
        // may legitimately reject capacities below some implementation
        // threshold (a future minor change could enforce a minimum of
        // 4 slots, for example). If init returns nil, skip with a
        // clear note rather than XCTFail — the existing
        // `test_initRejectsZeroCapacity` already pins the only firm
        // rejection contract.
        guard let atlas = GlyphAtlas(
            device: device, metrics: metrics, capacityGlyphs: 1, scale: 1
        ) else {
            throw XCTSkip(
                "capacity = 1 rejected by GlyphAtlas — implementation enforces "
                + "a minimum slot count above 1. Update this test if the minimum changes."
            )
        }

        // First insert: must succeed and produce valid UVs in [0, 1].
        let firstScalar = try XCTUnwrap(UnicodeScalar("A"))
        let first = try XCTUnwrap(
            atlas.lookupOrInsert(scalar: firstScalar),
            "first insert into a 1-slot atlas must succeed (the slot is empty)"
        )
        XCTAssertGreaterThanOrEqual(first.uvOrigin.x, 0)
        XCTAssertLessThanOrEqual(first.uvOrigin.x + first.uvSize.x, 1)
        XCTAssertGreaterThanOrEqual(first.uvOrigin.y, 0)
        XCTAssertLessThanOrEqual(first.uvOrigin.y + first.uvSize.y, 1)

        // Second insert: capacity is exhausted → flush byKey, reset
        // nextSlot, re-attempt. Must succeed on a 1-slot atlas, just
        // as the capacity-4 flush works in test_saturation_flushesAndReinserts.
        // A regression to `nextSlot >= capacityGlyphs && capacity == 1
        // → return nil` (giving up) would silently drop every miss
        // after the first.
        let secondScalar = try XCTUnwrap(UnicodeScalar("B"))
        let second = try XCTUnwrap(
            atlas.lookupOrInsert(scalar: secondScalar),
            "second insert on a saturated 1-slot atlas must trigger flush + re-admit"
        )
        XCTAssertGreaterThanOrEqual(second.uvOrigin.x, 0)
        XCTAssertGreaterThanOrEqual(second.uvOrigin.y, 0)

        // Third lookup of the originally-inserted scalar: post-flush
        // it was evicted, so this is now a fresh insert. Must succeed.
        let third = try XCTUnwrap(
            atlas.lookupOrInsert(scalar: firstScalar),
            "post-flush re-insert of an evicted scalar must succeed"
        )
        XCTAssertGreaterThanOrEqual(third.uvOrigin.x, 0)
    }

    /// Capacity = 2 with a wide insert: a wide glyph needs two
    /// adjacent slots in the same row. With sqrt(2) ≈ 1.4, the atlas
    /// rounds to 1 slot per row, so a wide glyph cannot fit two
    /// adjacent slots in the same row. The atlas has three valid
    /// responses: refuse the insert (return nil), wrap the wide
    /// onto a row that does fit, or trigger saturation flush. Pin
    /// the *non-crash* invariant — whichever response the atlas
    /// chooses, it MUST NOT trap or return UVs that overflow
    /// the texture. Behaviour-pin the contract weakly because the
    /// audit (TST-S4-005) flagged this as undertested but didn't
    /// fix-prescribe a specific path.
    func test_capacityTwo_wideInsert_doesNotCrashOrProduceInvalidUVs() throws {
        let device = try requireMetalDevice()
        let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        let metrics = CellMetrics(font: font)
        // Same edge as capacity 1 — implementation may enforce a
        // higher minimum. Skip rather than fail if construction is
        // rejected; the contract test for rejection is in
        // GlyphAtlasTests.test_initRejectsZeroCapacity.
        guard let atlas = GlyphAtlas(
            device: device, metrics: metrics, capacityGlyphs: 2, scale: 1
        ) else {
            throw XCTSkip(
                "capacity = 2 rejected by GlyphAtlas — implementation enforces "
                + "a minimum above 2."
            )
        }

        // Wide CJK character. The atlas may accept (in which case
        // both slots are used), refuse (returning nil), or recover
        // via flush. Any of those is OK — we only forbid
        // out-of-range UVs (which would scramble glyphs at sample time).
        let cjkScalar = try XCTUnwrap(UnicodeScalar(0x65E5))
        let entry = atlas.lookupOrInsert(scalar: cjkScalar, wide: true)
        if let entry {
            XCTAssertGreaterThanOrEqual(entry.uvOrigin.x, 0)
            XCTAssertLessThanOrEqual(entry.uvOrigin.x + entry.uvSize.x, 1.001,
                                     "wide UV must not extend past the texture's right edge")
            XCTAssertGreaterThanOrEqual(entry.uvOrigin.y, 0)
            XCTAssertLessThanOrEqual(entry.uvOrigin.y + entry.uvSize.y, 1.001)
        }
        // If the atlas refused (entry == nil), that's also a valid
        // contract: the renderer treats a missing glyph as
        // "draw nothing" and the cell stays bg-only. We don't fail.
    }

    /// Wide-glyph alignment edge at the END of the atlas. Capacity 4
    /// → slotCols = 2, slotRows = 2. Insert two narrow glyphs (slots
    /// 0, 1 = row 0). Now nextSlot = 2 (start of row 1, col 0). A
    /// wide insert here CAN fit (row 1 has 2 columns, two adjacent
    /// slots available). After it, nextSlot = 4 == capacity. A
    /// SECOND wide insert MUST trigger saturation (no room for
    /// another wide). Pin this so a refactor to the `nextSlot + 2
    /// > capacity` pre-check doesn't silently allow a
    /// half-out-of-bounds wide insert.
    ///
    /// Memory pre-flight: capacity 4, mono+color textures ≈ 4 *
    /// (8*18) ≈ 600 bytes mono, ≈ 2.3 KiB color. Negligible.
    func test_wideAtEndOfAtlas_lastTwoSlots_succeeds_thenSaturates() throws {
        let device = try requireMetalDevice()
        let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        let metrics = CellMetrics(font: font)
        let atlas = try XCTUnwrap(
            GlyphAtlas(device: device, metrics: metrics, capacityGlyphs: 4, scale: 1),
            "capacity = 4 must produce a 2x2 atlas"
        )

        // Fill row 0 with two narrows.
        _ = try XCTUnwrap(
            atlas.lookupOrInsert(scalar: UnicodeScalar("A")),
            "first narrow must occupy slot 0"
        )
        _ = try XCTUnwrap(
            atlas.lookupOrInsert(scalar: UnicodeScalar("B")),
            "second narrow must occupy slot 1"
        )

        // Wide glyph at slot 2 (col 0 of row 1) + slot 3 (col 1 of row 1).
        // This MUST succeed because slots 2 and 3 are adjacent in the
        // same row.
        let wideScalar = try XCTUnwrap(UnicodeScalar(0x65E5))
        let wide = try XCTUnwrap(
            atlas.lookupOrInsert(scalar: wideScalar, wide: true),
            "wide insert into the last two adjacent slots of a 4-slot atlas must succeed"
        )
        XCTAssertTrue(wide.isWide, "wide insert must report isWide == true")

        // The atlas is now full (nextSlot == capacity == 4). The next
        // insert (narrow OR wide) must trigger flush + reinsert,
        // matching the F3 fix pinned in test_saturation_flushesAndReinserts.
        // We don't require which scalar lands where — only that the
        // path doesn't return nil.
        let overflowScalar = try XCTUnwrap(UnicodeScalar("C"))
        XCTAssertNotNil(
            atlas.lookupOrInsert(scalar: overflowScalar),
            "post-fill insert must trigger flush + re-admit, not return nil"
        )
    }

    // MARK: - F-S4-005: grapheme cluster routing limitations
    //
    // The atlas keys on `(UnicodeScalar, bold, italic)`. ZWJ-joined
    // emoji and regional-indicator flag pairs are grapheme clusters
    // of multiple scalars; the renderer feeds them to the atlas one
    // scalar at a time. The audit (F-S4-005) acknowledges this as a
    // known limitation deferred to KNOWN_ISSUES.md.
    //
    // These tests pin the CURRENT (limited) behaviour so a future
    // fix that lands grapheme-cluster keying must update this file.
    // The existing `test_combiningMark_isolatedScalarRendersAlone`
    // in GlyphAtlasTests pins the U+0301 case; here we extend the
    // pin to ZWJ and regional-indicator scalars.

    /// ZWJ (U+200D) is the joiner scalar in family/profession emoji
    /// (👨‍👩‍👧, 👨‍💻, etc.). Fed to the atlas in isolation, it
    /// must produce a valid entry — not crash, not return nil — even
    /// though in a real grapheme cluster it has no visible
    /// rasterisation of its own. Pin this so a fix that ever made
    /// `isolated ZWJ → reject` (returning nil) doesn't silently
    /// break partial-cluster rendering.
    ///
    /// Limitation pinned: this insert returns a SEPARATE entry from
    /// the leading family-member scalar (e.g. 👨 U+1F468), so the
    /// renderer paints them as independent cells rather than a
    /// composed family glyph.
    func test_zwj_isolatedScalarKeyedSeparately() throws {
        let device = try requireMetalDevice()
        let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        let metrics = CellMetrics(font: font)
        let atlas = try XCTUnwrap(
            GlyphAtlas(device: device, metrics: metrics, capacityGlyphs: 64)
        )

        let zwj = try XCTUnwrap(UnicodeScalar(0x200D))
        let manScalar = try XCTUnwrap(UnicodeScalar(0x1F468))  // 👨

        let zwjEntry = try XCTUnwrap(
            atlas.lookupOrInsert(scalar: zwj),
            "ZWJ inserted in isolation must produce a valid entry — even if invisible"
        )
        let manEntry = try XCTUnwrap(
            atlas.lookupOrInsert(scalar: manScalar, wide: true),
            "leading family-emoji scalar must produce a valid entry"
        )

        // Limitation pin: separate slots → grapheme cluster renders
        // piecewise. If a future commit lands cluster-keyed atlases,
        // these will be the SAME entry and this assertion needs
        // updating in lockstep with KNOWN_ISSUES.md.
        XCTAssertNotEqual(
            zwjEntry.uvOrigin, manEntry.uvOrigin,
            "ZWJ and 👨 must occupy distinct slots while atlas keys on single scalar — "
            + "if this fails, the limitation has been fixed and KNOWN_ISSUES.md needs updating"
        )
    }

    /// Regional indicator letters (U+1F1E6..U+1F1FF) compose into
    /// flag emoji as pairs (🇺🇸 = U+1F1FA + U+1F1F8). The atlas
    /// rasterises each in isolation; in isolation, a regional
    /// indicator letter renders via the system font's fallback —
    /// often the bare Latin letter (`U`, `S`) instead of the flag
    /// component. The audit (F-S4-005) explicitly flags this as
    /// "flag emoji render as gray US letterforms".
    ///
    /// Pin the limitation: feeding a regional-indicator letter
    /// alone produces a valid entry (atlas insert succeeds, no
    /// crash), but it's NOT keyed together with the partner letter.
    /// A consumer that fed `0x1F1FA, 0x1F1F8` as separate cells
    /// would see two separate atlas entries, not a flag glyph.
    ///
    /// Why test this rather than just rely on the F-S4-005 doc note:
    /// a refactor that lands grapheme keying would silently change
    /// this behaviour without tripping any of the existing tests
    /// (which all pass single-scalar inputs through the atlas).
    /// This pin forces the author to explicitly accept the change.
    func test_regionalIndicator_keyedSeparatelyFromPartner() throws {
        let device = try requireMetalDevice()
        let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        let metrics = CellMetrics(font: font)
        let atlas = try XCTUnwrap(
            GlyphAtlas(device: device, metrics: metrics, capacityGlyphs: 64)
        )

        let usFirst = try XCTUnwrap(UnicodeScalar(0x1F1FA))   // 🇺 (U)
        let usSecond = try XCTUnwrap(UnicodeScalar(0x1F1F8))  // 🇸 (S)

        let firstEntry = try XCTUnwrap(
            atlas.lookupOrInsert(scalar: usFirst, wide: true),
            "regional indicator letter must insert without crash even in isolation"
        )
        let secondEntry = try XCTUnwrap(
            atlas.lookupOrInsert(scalar: usSecond, wide: true),
            "second regional indicator letter must also insert"
        )

        // The two letters MUST occupy distinct atlas slots. If a
        // future grapheme-aware atlas ever folds them into a single
        // composed-flag entry, this assertion fires and the author
        // must update KNOWN_ISSUES.md to remove the limitation note.
        XCTAssertNotEqual(
            firstEntry.uvOrigin, secondEntry.uvOrigin,
            "regional-indicator letters must currently key separately — "
            + "fix-pin: if this fails, flag emoji are now atlas-keyed as clusters "
            + "and KNOWN_ISSUES.md must be updated"
        )
    }

    /// Variation Selector-16 (U+FE0F) requests emoji presentation
    /// for the preceding scalar (e.g. 0x2764 + 0xFE0F → ❤️). In
    /// isolation, U+FE0F has no visible glyph but the atlas must
    /// still admit it without crashing — the renderer feeds it as
    /// a separate scalar in current code. Pin the no-crash + valid
    /// UV invariants.
    func test_vs16_isolatedScalarRendersWithoutCrash() throws {
        let device = try requireMetalDevice()
        let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        let metrics = CellMetrics(font: font)
        let atlas = try XCTUnwrap(
            GlyphAtlas(device: device, metrics: metrics, capacityGlyphs: 64)
        )
        let vs16 = try XCTUnwrap(UnicodeScalar(0xFE0F))
        let entry = try XCTUnwrap(
            atlas.lookupOrInsert(scalar: vs16),
            "VS16 in isolation must insert without crash"
        )
        XCTAssertGreaterThanOrEqual(entry.uvOrigin.x, 0)
        XCTAssertLessThanOrEqual(entry.uvOrigin.x + entry.uvSize.x, 1.001)
        XCTAssertGreaterThanOrEqual(entry.uvOrigin.y, 0)
        XCTAssertLessThanOrEqual(entry.uvOrigin.y + entry.uvSize.y, 1.001)
    }

    // MARK: - Atlas-key idempotence
    //
    // `lookupOrInsert` is the only public mutation path. Calling it
    // twice for the same scalar must return the same entry (UVs
    // unchanged, isWide unchanged). The existing
    // `test_prewarm_isIdempotent` covers the prewarm-then-lookup
    // path; here we pin the simple lookup-then-lookup invariant
    // directly.

    /// Idempotent lookup: the second call returns the same UV
    /// origin/size as the first. A regression that re-inserted on
    /// every call (e.g. a hash-table bug that produced collisions
    /// across calls) would shift the entry's slot and break the
    /// shader's atlas sampling between frames.
    func test_lookupOrInsert_isIdempotent_forSameScalar() throws {
        let device = try requireMetalDevice()
        let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        let metrics = CellMetrics(font: font)
        let atlas = try XCTUnwrap(
            GlyphAtlas(device: device, metrics: metrics, capacityGlyphs: 128)
        )
        let scalar = try XCTUnwrap(UnicodeScalar("Z"))
        let first = try XCTUnwrap(atlas.lookupOrInsert(scalar: scalar))
        let second = try XCTUnwrap(atlas.lookupOrInsert(scalar: scalar))
        XCTAssertEqual(first.uvOrigin, second.uvOrigin,
                       "repeated lookup of the same scalar must return identical UV origin")
        XCTAssertEqual(first.uvSize, second.uvSize,
                       "repeated lookup must return identical UV size")
        XCTAssertEqual(first.isWide, second.isWide,
                       "repeated lookup must return identical isWide flag")
    }

    /// `lookupOrInsert` must not crash or return invalid UVs when
    /// the same scalar is looked up under both `wide` flags. Whether
    /// the atlas keys on `scalar.value` alone (cache HIT on the
    /// second call) or on `(scalar, wide)` (separate slots) is an
    /// implementation choice — both are valid contracts. We pin only
    /// the no-crash + valid-UV invariants because attempting to
    /// pin one specific behaviour would constrain implementation
    /// choice without a clear correctness signal.
    func test_lookupOrInsert_widthFlagToggle_alwaysProducesValidEntry() throws {
        let device = try requireMetalDevice()
        let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        let metrics = CellMetrics(font: font)
        let atlas = try XCTUnwrap(
            GlyphAtlas(device: device, metrics: metrics, capacityGlyphs: 128)
        )
        let scalar = try XCTUnwrap(UnicodeScalar("X"))
        let narrow = try XCTUnwrap(
            atlas.lookupOrInsert(scalar: scalar, wide: false),
            "first lookup (narrow) must succeed"
        )
        XCTAssertFalse(narrow.isWide,
                       "narrow lookup of an ASCII letter must produce isWide == false")
        XCTAssertGreaterThanOrEqual(narrow.uvOrigin.x, 0)
        XCTAssertLessThanOrEqual(narrow.uvOrigin.x + narrow.uvSize.x, 1.001)

        // Second lookup with wide=true. Whatever the atlas's key
        // policy, the result must be a valid entry with in-range UVs.
        let widened = try XCTUnwrap(
            atlas.lookupOrInsert(scalar: scalar, wide: true),
            "second lookup (wide flag) must succeed without crashing"
        )
        XCTAssertGreaterThanOrEqual(widened.uvOrigin.x, 0)
        XCTAssertLessThanOrEqual(widened.uvOrigin.x + widened.uvSize.x, 1.001)
        XCTAssertGreaterThanOrEqual(widened.uvOrigin.y, 0)
        XCTAssertLessThanOrEqual(widened.uvOrigin.y + widened.uvSize.y, 1.001)
    }
}
