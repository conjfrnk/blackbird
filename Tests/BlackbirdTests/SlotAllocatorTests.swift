import XCTest
@testable import Blackbird

/// Pure value-type unit tests for `GlyphAtlas.SlotAllocator`, the
/// slot-bookkeeping logic extracted out of `GlyphAtlas`.
///
/// `SlotAllocator` is a plain `struct` with NO Metal / texture / CoreText
/// dependencies, so these tests construct it directly and run on any
/// machine — they MUST NOT be gated/skipped on headless CI. There is no
/// `MTLDevice`, no atlas texture, and no shared state here.
///
/// **Memory pre-flight** (per MEMORY `feedback_test_memory_safety`): every
/// test builds at most a handful of `SlotAllocator` values plus a few
/// small `[Int]` orphan lists. The largest loop runs 1000 cheap integer
/// increments (`recordSaturationHit`) with zero allocation per call.
/// Total footprint is a few kilobytes — far under any budget.
///
/// Tests are written blind against the published CONTRACT only; the
/// `SlotAllocator` implementation body was deliberately not read.
final class SlotAllocatorTests: XCTestCase {

    // MARK: - Helpers

    /// Builds an allocator with unambiguous row math for the alignment
    /// tests: 8 slots per row, 64-slot (8-row) capacity.
    private func makeAllocator(
        slotCols: Int = 8,
        capacityGlyphs: Int = 64
    ) -> GlyphAtlas.SlotAllocator {
        GlyphAtlas.SlotAllocator(slotCols: slotCols, capacityGlyphs: capacityGlyphs)
    }

    /// Advances `nextSlot` by `count` via `count` narrow plan→commit
    /// cycles. Each narrow insert advances `nextSlot` by exactly 1 and
    /// parks no orphans, so afterwards `nextSlot == start + count` and
    /// `orphanCount` is unchanged.
    private func advanceNextSlot(
        _ alloc: inout GlyphAtlas.SlotAllocator,
        by count: Int
    ) {
        for _ in 0..<count {
            let plan = alloc.planFreshInsert(wide: false, slotsNeeded: 1)
            alloc.commitFreshInsert(plan, slotsNeeded: 1)
        }
    }

    // MARK: - Initial state

    func test_initialState_isAllZero() {
        let alloc = makeAllocator()
        XCTAssertEqual(alloc.nextSlot, 0, "nextSlot must start at 0")
        XCTAssertEqual(alloc.generation, 0, "generation must start at 0")
        XCTAssertEqual(alloc.saturationHits, 0, "saturationHits must start at 0")
        XCTAssertEqual(alloc.orphanCount, 0, "orphanCount must start at 0")
    }

    // MARK: - 1. Fresh narrow insert in an empty allocator

    func test_planFreshInsert_narrowEmpty_landsAtSlotZero() {
        var alloc = makeAllocator()

        let plan = alloc.planFreshInsert(wide: false, slotsNeeded: 1)
        XCTAssertEqual(plan.slot, 0, "first narrow insert must land at slot 0")
        XCTAssertTrue(plan.pendingOrphans.isEmpty, "narrow insert parks no orphans")
        XCTAssertFalse(plan.needsFlush, "ample capacity → needsFlush false")

        // planFreshInsert is pure: nextSlot unchanged until commit.
        XCTAssertEqual(alloc.nextSlot, 0, "planFreshInsert must not mutate nextSlot")

        alloc.commitFreshInsert(plan, slotsNeeded: 1)
        XCTAssertEqual(alloc.nextSlot, 1, "after committing a 1-slot insert nextSlot == 1")
        XCTAssertEqual(alloc.orphanCount, 0, "no orphans parked by a fitting narrow insert")
    }

    // MARK: - 2. Sequential narrow inserts advance nextSlot by 1 each

    func test_sequentialNarrowInserts_advanceByOneEach() {
        var alloc = makeAllocator()

        for expectedStart in 0..<5 {
            let plan = alloc.planFreshInsert(wide: false, slotsNeeded: 1)
            XCTAssertEqual(plan.slot, expectedStart,
                           "narrow insert #\(expectedStart) must land at nextSlot")
            XCTAssertTrue(plan.pendingOrphans.isEmpty,
                          "narrow inserts never park orphans")
            alloc.commitFreshInsert(plan, slotsNeeded: 1)
            XCTAssertEqual(alloc.nextSlot, expectedStart + 1,
                           "nextSlot advances by exactly 1 per narrow insert")
        }
        XCTAssertEqual(alloc.orphanCount, 0, "no orphans accumulated across narrow inserts")
    }

    // MARK: - 3. Wide insert that FITS at the start of a row

    func test_planFreshInsert_wideFitsAtRowStart_noSkip() {
        var alloc = makeAllocator() // slotCols 8

        let plan = alloc.planFreshInsert(wide: true, slotsNeeded: 2)
        XCTAssertEqual(plan.slot, 0, "wide glyph fits at row start → slot == nextSlot")
        XCTAssertTrue(plan.pendingOrphans.isEmpty, "no row skip → no orphans")
        XCTAssertFalse(plan.needsFlush, "ample capacity → needsFlush false")

        alloc.commitFreshInsert(plan, slotsNeeded: 2)
        XCTAssertEqual(alloc.nextSlot, 2, "wide commit advances nextSlot by slotsNeeded")
        XCTAssertEqual(alloc.orphanCount, 0, "fitting wide insert parks no orphans")
    }

    func test_planFreshInsert_wideFitsMidRow_noSkip() {
        var alloc = makeAllocator() // slotCols 8
        advanceNextSlot(&alloc, by: 4) // nextSlot == 4, column 4

        // column 4 + 2 == 6 <= 8 → fits in current row, no skip.
        let plan = alloc.planFreshInsert(wide: true, slotsNeeded: 2)
        XCTAssertEqual(plan.slot, 4, "wide glyph that fits mid-row → slot == nextSlot")
        XCTAssertTrue(plan.pendingOrphans.isEmpty, "fits in row → no orphans")
        XCTAssertFalse(plan.needsFlush)
    }

    // MARK: - 4. Wide insert at the LAST column of a row → skip to next row

    func test_planFreshInsert_wideAtLastColumn_skipsToNextRow() {
        var alloc = makeAllocator() // slotCols 8, capacity 64
        advanceNextSlot(&alloc, by: 7) // nextSlot == 7, column 7 (last column)

        // column 7 + 2 == 9 > 8 → cannot fit; skip to next row start (8).
        let plan = alloc.planFreshInsert(wide: true, slotsNeeded: 2)
        XCTAssertEqual(plan.slot, 8, "wide insert skips to the next row's first slot")
        XCTAssertEqual(plan.pendingOrphans, [7],
                       "the skipped single-slot gap (slot 7) becomes a pending orphan")
        XCTAssertFalse(plan.needsFlush, "8 + 2 == 10 <= 64 → no flush")

        // planFreshInsert is pure: nothing parked or advanced yet.
        XCTAssertEqual(alloc.orphanCount, 0, "planFreshInsert must not park orphans")
        XCTAssertEqual(alloc.nextSlot, 7, "planFreshInsert must not advance nextSlot")

        alloc.commitFreshInsert(plan, slotsNeeded: 2)
        XCTAssertEqual(alloc.orphanCount, 1, "committing the plan parks the skipped slot")
        XCTAssertEqual(alloc.nextSlot, 10, "nextSlot == plan.slot (8) + slotsNeeded (2)")
    }

    func test_planFreshInsert_wideSkip_parksAllGapSlots() {
        var alloc = makeAllocator() // slotCols 8
        advanceNextSlot(&alloc, by: 5) // nextSlot == 5, column 5

        // column 5 + 4 == 9 > 8 → skip to slot 8; gaps 5,6,7 become orphans.
        let plan = alloc.planFreshInsert(wide: true, slotsNeeded: 4)
        XCTAssertEqual(plan.slot, 8, "skips to next row start")
        XCTAssertEqual(plan.pendingOrphans, [5, 6, 7],
                       "every skipped single-slot gap up to the row boundary is parked")

        alloc.commitFreshInsert(plan, slotsNeeded: 4)
        XCTAssertEqual(alloc.orphanCount, 3, "all three gap slots parked on commit")
        XCTAssertEqual(alloc.nextSlot, 12, "nextSlot == 8 + 4")
    }

    // MARK: - 5. A later narrow insert reclaims the parked orphan (LIFO)

    func test_reclaimNarrowSlot_recoversParkedWideSkipGap() {
        var alloc = makeAllocator()
        advanceNextSlot(&alloc, by: 7) // nextSlot == 7
        let plan = alloc.planFreshInsert(wide: true, slotsNeeded: 2)
        alloc.commitFreshInsert(plan, slotsNeeded: 2)
        XCTAssertEqual(alloc.orphanCount, 1, "precondition: one orphan parked (slot 7)")

        let reclaimed = alloc.reclaimNarrowSlot()
        XCTAssertEqual(reclaimed, 7, "reclaim returns the previously parked orphan slot")
        XCTAssertEqual(alloc.orphanCount, 0, "reclaim decrements orphanCount")

        XCTAssertNil(alloc.reclaimNarrowSlot(), "no orphans left → reclaim returns nil")
    }

    func test_reclaimNarrowSlot_emptyReturnsNil() {
        var alloc = makeAllocator()
        XCTAssertNil(alloc.reclaimNarrowSlot(), "fresh allocator has no parked orphans")
        XCTAssertEqual(alloc.orphanCount, 0)
    }

    // MARK: - 6. returnNarrowSlot / reclaimNarrowSlot round-trip (LIFO)

    func test_returnThenReclaim_roundTripsLIFO() {
        var alloc = makeAllocator()

        alloc.returnNarrowSlot(3)
        XCTAssertEqual(alloc.orphanCount, 1, "returnNarrowSlot parks a slot")
        alloc.returnNarrowSlot(5)
        XCTAssertEqual(alloc.orphanCount, 2)

        // LIFO: the most recently parked slot (5) pops first.
        XCTAssertEqual(alloc.reclaimNarrowSlot(), 5, "LIFO: last parked pops first")
        XCTAssertEqual(alloc.orphanCount, 1)
        XCTAssertEqual(alloc.reclaimNarrowSlot(), 3, "then the earlier parked slot pops")
        XCTAssertEqual(alloc.orphanCount, 0)
        XCTAssertNil(alloc.reclaimNarrowSlot(), "list drained → nil")
    }

    func test_returnThenReclaim_singleRoundTrip() {
        var alloc = makeAllocator()
        alloc.returnNarrowSlot(42)
        XCTAssertEqual(alloc.reclaimNarrowSlot(), 42,
                       "a single returned slot reclaims back as the same value")
        XCTAssertEqual(alloc.orphanCount, 0)
    }

    // MARK: - 7. needsFlush at capacity boundary

    func test_needsFlush_trueWhenInsertExceedsCapacity() {
        // Tiny capacity so the boundary is easy to reach: 4 slots total.
        var alloc = makeAllocator(slotCols: 8, capacityGlyphs: 4)
        advanceNextSlot(&alloc, by: 3) // nextSlot == 3

        // 3 + 1 == 4 == capacity → NOT over → no flush.
        let fits = alloc.planFreshInsert(wide: false, slotsNeeded: 1)
        XCTAssertFalse(fits.needsFlush, "slot + slotsNeeded == capacity is not over capacity")

        // 3 + 2 == 5 > 4 → over capacity → needs flush.
        let overflows = alloc.planFreshInsert(wide: false, slotsNeeded: 2)
        XCTAssertTrue(overflows.needsFlush, "slot + slotsNeeded > capacity → needsFlush true")
    }

    // MARK: - 8. recordSaturationHit

    func test_recordSaturationHit_logPredicateAtBoundaries() {
        var alloc = makeAllocator(slotCols: 2, capacityGlyphs: 2)

        for i in 1...1000 {
            let result = alloc.recordSaturationHit()
            XCTAssertEqual(result.hits, i, "hits increments by 1 each call")
            XCTAssertEqual(alloc.saturationHits, i, "saturationHits tracks the count")

            let expectedLog = (i == 1 || i % 1000 == 0)
            XCTAssertEqual(result.shouldLog, expectedLog,
                           "shouldLog true only at the 1st hit and every 1000th (i=\(i))")
            // No orphans were parked, so orphansBefore stays 0 throughout.
            XCTAssertEqual(result.orphansBefore, 0,
                           "orphansBefore samples orphanCount (0 here) at call time")
        }
    }

    func test_recordSaturationHit_orphansBeforeSamplesOrphanCount() {
        var alloc = makeAllocator()
        alloc.returnNarrowSlot(1)
        alloc.returnNarrowSlot(2)
        XCTAssertEqual(alloc.orphanCount, 2, "precondition: two orphans parked")

        let result = alloc.recordSaturationHit()
        XCTAssertEqual(result.hits, 1, "first saturation hit")
        XCTAssertTrue(result.shouldLog, "first hit always logs")
        XCTAssertEqual(result.orphansBefore, 2,
                       "orphansBefore reflects orphanCount sampled at the call")
        // recordSaturationHit does not flush, so orphans remain parked.
        XCTAssertEqual(alloc.orphanCount, 2, "recordSaturationHit must not clear orphans")
    }

    // MARK: - 9. flushReset

    func test_flushReset_clearsStateAndBumpsGeneration() {
        var alloc = makeAllocator()
        advanceNextSlot(&alloc, by: 5) // nextSlot == 5
        alloc.returnNarrowSlot(2)      // orphanCount == 1
        XCTAssertEqual(alloc.nextSlot, 5)
        XCTAssertEqual(alloc.orphanCount, 1)
        XCTAssertEqual(alloc.generation, 0, "precondition: no flushes yet")

        let plan = alloc.flushReset()
        XCTAssertEqual(plan.slot, 0, "flushReset returns a plan landing at slot 0")
        XCTAssertTrue(plan.pendingOrphans.isEmpty, "flushReset plan has no pending orphans")
        XCTAssertFalse(plan.needsFlush, "flushReset plan does not itself need a flush")

        XCTAssertEqual(alloc.nextSlot, 0, "flushReset rewinds nextSlot to 0")
        XCTAssertEqual(alloc.orphanCount, 0, "flushReset clears all parked orphans")
        XCTAssertEqual(alloc.generation, 1, "flushReset bumps generation by 1")
        XCTAssertNil(alloc.reclaimNarrowSlot(), "no orphans survive a flush")
    }

    func test_flushReset_twiceBumpsGenerationToTwo() {
        var alloc = makeAllocator()

        advanceNextSlot(&alloc, by: 3)
        alloc.returnNarrowSlot(0)
        _ = alloc.flushReset()
        XCTAssertEqual(alloc.generation, 1, "first flush → generation 1")

        advanceNextSlot(&alloc, by: 2)
        alloc.returnNarrowSlot(1)
        _ = alloc.flushReset()
        XCTAssertEqual(alloc.generation, 2, "second flush → generation 2")
        XCTAssertEqual(alloc.nextSlot, 0, "still rewound after the second flush")
        XCTAssertEqual(alloc.orphanCount, 0, "still cleared after the second flush")
    }

    // MARK: - 10. cannotFit

    func test_cannotFit_singleColumnAtlas() {
        let alloc = makeAllocator(slotCols: 1, capacityGlyphs: 8)
        XCTAssertTrue(alloc.cannotFit(slotsNeeded: 2),
                      "a 2-slot glyph cannot fit a 1-column atlas")
        XCTAssertFalse(alloc.cannotFit(slotsNeeded: 1),
                       "a 1-slot glyph fits a 1-column atlas")
    }

    func test_cannotFit_eightColumnAtlas() {
        let alloc = makeAllocator(slotCols: 8, capacityGlyphs: 64)
        XCTAssertFalse(alloc.cannotFit(slotsNeeded: 1), "1 <= 8 → fits")
        XCTAssertFalse(alloc.cannotFit(slotsNeeded: 2), "2 <= 8 → fits")
        XCTAssertFalse(alloc.cannotFit(slotsNeeded: 8), "8 <= 8 → fits exactly")
        XCTAssertTrue(alloc.cannotFit(slotsNeeded: 9), "9 > 8 → cannot fit")
    }
}
