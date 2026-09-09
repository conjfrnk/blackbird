import XCTest
@testable import Blackbird

/// Blind tests for `GlyphBitmapCache`'s per-font-set eviction: when the
/// cache is full and a key from a *new* font set arrives, the oldest
/// OTHER font set is dropped wholesale; a single font set that overflows
/// the cap on its own is refused (nothing else to evict).
///
/// Memory: each test holds at most 4096 + a few entries of a 1-byte
/// bitmap plus a ~64-byte key — well under 1 MiB. The cache is process-
/// wide static state, so it is reset in both setUp and tearDown.
final class GlyphBitmapCacheEvictionBlindTests: XCTestCase {

    private let capacity = 4096

    override class func setUp() {
        super.setUp()
        TestHostTermination.shared.register()
    }

    override func setUp() {
        super.setUp()
        GlyphBitmapCache._resetForTests()
    }

    override func tearDown() {
        GlyphBitmapCache._resetForTests()
        super.tearDown()
    }

    // MARK: - Fixtures

    private func key(_ set: String, _ scalar: UInt32) -> GlyphBitmapCache.Key {
        GlyphBitmapCache.Key(
            fontName: set, sizeQ: 1300, scaleQ: 200, scalar: scalar,
            bold: false, italic: false, wide: false, isColor: false,
            emojiPresentation: false
        )
    }

    private var pixel: GlyphBitmapCache.Bitmap {
        .init(bytes: [0], width: 1, height: 1, bytesPerRow: 1)
    }

    private func fill(_ set: String, count: Int) {
        for i in 0..<count {
            GlyphBitmapCache.put(key(set, UInt32(i)), pixel)
        }
    }

    private func presentCount(_ set: String, count: Int) -> Int {
        (0..<count).reduce(0) { GlyphBitmapCache.get(key(set, UInt32($1))) == nil ? $0 : $0 + 1 }
    }

    // MARK: - Tests

    func test_freshCacheHasNoEvictions() {
        XCTAssertEqual(GlyphBitmapCache.evictionCount, 0)
        XCTAssertNil(GlyphBitmapCache.get(key("A", 0)))
    }

    func test_singleSetFillsToCapacity_allRetrievable() {
        fill("A", count: capacity)
        XCTAssertEqual(presentCount("A", count: capacity), capacity,
                       "every key of a set that exactly fills the cache must be retrievable")
        XCTAssertEqual(GlyphBitmapCache.evictionCount, 0, "filling to capacity must not evict")
    }

    func test_newSetAtCapacity_evictsWholeOlderSet() {
        fill("A", count: capacity)
        GlyphBitmapCache.put(key("B", 0), pixel)

        XCTAssertNotNil(GlyphBitmapCache.get(key("B", 0)),
                        "the incoming key from a new font set must be admitted")
        XCTAssertEqual(GlyphBitmapCache.evictionCount, 1, "exactly one group eviction")
        XCTAssertEqual(presentCount("A", count: capacity), 0,
                       "EVERY key of the evicted set A must be gone")
    }

    func test_singleSetOverflow_isRefusedWithoutEviction() {
        fill("A", count: capacity)
        GlyphBitmapCache.put(key("B", 0), pixel)          // evicts A (count 1)
        fill("B", count: capacity)                         // B now has 4096 (0..<4096; key 0 refreshed)
        XCTAssertEqual(presentCount("B", count: capacity), capacity)
        XCTAssertEqual(GlyphBitmapCache.evictionCount, 1)

        // 4097th key in the same (only) set: nothing else to evict → refused.
        GlyphBitmapCache.put(key("B", UInt32(capacity)), pixel)
        XCTAssertNil(GlyphBitmapCache.get(key("B", UInt32(capacity))),
                     "a set that overflows the cap on its own must be refused")
        XCTAssertEqual(GlyphBitmapCache.evictionCount, 1,
                       "refusal must not count as an eviction")
        XCTAssertEqual(presentCount("B", count: capacity), capacity,
                       "refusal must not drop any existing B key")
    }

    func test_existingKeyRefreshAtCapacity_neverEvicts() {
        fill("A", count: capacity)
        // Re-putting an existing key when full is a refresh, not a new insert.
        GlyphBitmapCache.put(key("A", 7), .init(bytes: [255], width: 1, height: 1, bytesPerRow: 1))
        XCTAssertEqual(GlyphBitmapCache.get(key("A", 7))?.bytes, [255], "refresh must replace the bitmap")
        XCTAssertEqual(GlyphBitmapCache.evictionCount, 0)
        XCTAssertEqual(presentCount("A", count: capacity), capacity)
    }

    func test_oldestOtherGroupIsEvicted_notTheIncomingGroup() {
        // Build B (older) then C (newer), together at capacity.
        let half = capacity / 2
        fill("B", count: half)
        fill("C", count: half)
        XCTAssertEqual(presentCount("B", count: half), half)
        XCTAssertEqual(presentCount("C", count: half), half)
        XCTAssertEqual(GlyphBitmapCache.evictionCount, 0)

        // A NEW B key: B is the incoming group, so the oldest OTHER group
        // (C) is the victim — even though B is older than C.
        GlyphBitmapCache.put(key("B", UInt32(half)), pixel)
        XCTAssertNotNil(GlyphBitmapCache.get(key("B", UInt32(half))), "new B key must be admitted")
        XCTAssertEqual(GlyphBitmapCache.evictionCount, 1)
        XCTAssertEqual(presentCount("C", count: half), 0, "C (the only other group) must be evicted")
        XCTAssertEqual(presentCount("B", count: half), half, "B must survive intact")
    }

    func test_threeGroups_oldestOtherIsEvictedFirst() {
        // A oldest, B middle, C newest; incoming C → evict A, keep B.
        let third = capacity / 3                 // 1365 × 3 = 4095
        fill("A", count: third)
        fill("B", count: third)
        fill("C", count: third)
        // Top up to exactly capacity with one more C key.
        GlyphBitmapCache.put(key("C", UInt32(third)), pixel)
        XCTAssertEqual(GlyphBitmapCache.evictionCount, 0, "fixture: 4096 entries, no eviction yet")

        GlyphBitmapCache.put(key("C", UInt32(third + 1)), pixel)
        XCTAssertNotNil(GlyphBitmapCache.get(key("C", UInt32(third + 1))))
        XCTAssertEqual(GlyphBitmapCache.evictionCount, 1)
        XCTAssertEqual(presentCount("A", count: third), 0, "oldest other group A evicted")
        XCTAssertEqual(presentCount("B", count: third), third, "B (newer than A) survives")
        XCTAssertEqual(presentCount("C", count: third + 2), third + 2, "C intact + new key")
    }

    func test_evictedGroupCanBeRepopulated() {
        fill("A", count: capacity)
        GlyphBitmapCache.put(key("B", 0), pixel)          // A evicted
        XCTAssertNil(GlyphBitmapCache.get(key("A", 3)))
        // A can come back as a fresh (now newest) group.
        GlyphBitmapCache.put(key("A", 3), pixel)
        XCTAssertNotNil(GlyphBitmapCache.get(key("A", 3)))
        XCTAssertNotNil(GlyphBitmapCache.get(key("B", 0)), "no eviction needed below capacity")
        XCTAssertEqual(GlyphBitmapCache.evictionCount, 1)
    }

    func test_resetClearsEntriesAndCounter() {
        fill("A", count: capacity)
        GlyphBitmapCache.put(key("B", 0), pixel)
        XCTAssertEqual(GlyphBitmapCache.evictionCount, 1)
        GlyphBitmapCache._resetForTests()
        XCTAssertEqual(GlyphBitmapCache.evictionCount, 0)
        XCTAssertNil(GlyphBitmapCache.get(key("B", 0)))
    }
}
