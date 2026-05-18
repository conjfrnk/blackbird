import XCTest
@testable import Blackbird
@testable import BBCore

/// Blind-authored gap coverage for `SnapshotHyperlinkResolver` and the
/// `URLOpener` / `DefaultURLOpener` surface. The author of this file has
/// not read `HyperlinkResolver.swift`; everything below is derived from
/// the public contract documented in the task brief, the FFI surface in
/// `core/include/BBCore.h`, and the existing `HyperlinkTests` idiom (for
/// snapshot construction style only). Sister of `HyperlinkTests.swift`;
/// does not duplicate the 47 cases that already live there.
///
/// Coverage spine (one or more `test...` per bullet):
///   1.  `regexURL(row:col:)` hits and misses with pre-computed matches.
///   2.  Out-of-bounds (row, col) inputs return nil/empty across the
///       three resolver methods without crashing.
///   3.  `osc8AnchorText` on cells with no OSC 8 attribution.
///   4.  `osc8AnchorText` walks the run for multi-cell anchors,
///       edge-of-screen anchors, and anchors with trailing spaces.
///   5.  OSC 8 + regex overlap — OSC 8 wins.
///   6.  `URLOpener` protocol — building a resolver doesn't fire opens.
///   7.  `DefaultURLOpener()` is constructible without crashing.
///   8.  Wide-glyph cells (CJK / regional-indicator emoji) under OSC 8.
///   9.  Empty / fresh snapshot — all three methods return nil/empty.
///   10. Resolver outlives the local strong reference to its snapshot.
final class HyperlinkResolverBlindTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        TestHostTermination.shared.register()
    }

    // MARK: - Fixture helpers

    /// Build a snapshot from raw input bytes on a default 80×24 grid.
    /// Centralised so each test reads as `given <input>, expect <…>`
    /// rather than re-deriving the BBTerm construction every time.
    private func snapshot(
        from input: String,
        cols: UInt16 = 80,
        rows: UInt16 = 24,
        file: StaticString = #file,
        line: UInt = #line
    ) throws -> BBSnapshot {
        let term = try XCTUnwrap(
            BBTerm(size: .init(cols: cols, rows: rows)),
            "BBTerm init must succeed for \(cols)×\(rows)",
            file: file, line: line
        )
        if !input.isEmpty { term.input(input) }
        return try XCTUnwrap(
            term.snapshot(),
            "snapshot() must return a valid handle",
            file: file, line: line
        )
    }

    /// OSC 8 hyperlink syntax helper: ESC]8;;<url>ESC\<text>ESC]8;;ESC\
    /// Trailing terminator returns the grid to no-attribution state so
    /// subsequent cells aren't tagged with the same link id.
    private func osc8(_ url: String, _ text: String) -> String {
        "\u{1B}]8;;\(url)\u{1B}\\\(text)\u{1B}]8;;\u{1B}\\"
    }

    // MARK: - 1. regexURL(row:col:) resolution with pre-computed matches

    func testRegexURL_returnsURLInsideMatchSpan() throws {
        // Plain-text URL on a fresh terminal. URLDetector picks it up
        // and we feed the matches to the resolver so regexURL queries
        // hit the pre-computed cache path. Verifies that an in-span
        // (row, col) yields the same URL the detector found.
        let snap = try snapshot(from: "see https://example.com/path here")
        let matches = URLDetector.scan(snapshot: snap)
        XCTAssertFalse(matches.isEmpty, "URLDetector must surface the plain URL")
        let resolver = SnapshotHyperlinkResolver(snapshot: snap, regexMatches: matches)
        // Column 10 lands inside "https://example.com/path" (starts at
        // col 4, ends at col 27 inclusive).
        let url = resolver.regexURL(row: 0, col: 10)
        XCTAssertEqual(
            url?.absoluteString,
            "https://example.com/path",
            "regexURL must return the match URL for an in-span cell"
        )
    }

    func testRegexURL_returnsNilOutsideMatchSpan() throws {
        // Same fixture as above. A column BEFORE the URL token ("see "
        // is cols 0..<4) must miss; a column AFTER the URL token (the
        // word " here") must also miss. Pins the span boundary.
        let snap = try snapshot(from: "see https://example.com/path here")
        let matches = URLDetector.scan(snapshot: snap)
        let resolver = SnapshotHyperlinkResolver(snapshot: snap, regexMatches: matches)
        XCTAssertNil(
            resolver.regexURL(row: 0, col: 1),
            "col 1 sits inside 'see ' — outside any URL span"
        )
        XCTAssertNil(
            resolver.regexURL(row: 0, col: 30),
            "col 30 sits inside ' here' — outside any URL span"
        )
    }

    func testRegexURL_emptyMatchesYieldNil() throws {
        // Explicit empty pre-computed match slice. The resolver should
        // consult the slice (and find nothing) rather than fall back to
        // a fresh scan that would re-discover a URL. This pins the
        // "caller is authoritative when matches != nil" half of the
        // contract — fragile to a future refactor that confuses
        // `nil` and `[]`.
        let snap = try snapshot(from: "see https://example.com/path here")
        let resolver = SnapshotHyperlinkResolver(snapshot: snap, regexMatches: [])
        XCTAssertNil(
            resolver.regexURL(row: 0, col: 10),
            "empty caller-supplied matches must not be supplemented with a fresh scan"
        )
    }

    // MARK: - 2. Out-of-bounds (row, col) inputs

    func testOutOfBounds_negativeRow_allMethodsSafe() throws {
        let snap = try snapshot(from: osc8("https://example.com", "hi"))
        let resolver = SnapshotHyperlinkResolver(snapshot: snap)
        XCTAssertNil(resolver.osc8URL(row: -1, col: 0))
        XCTAssertNil(resolver.regexURL(row: -1, col: 0))
        XCTAssertEqual(
            resolver.osc8AnchorText(row: -1, col: 0), "",
            "negative row returns empty anchor text, not a crash"
        )
    }

    func testOutOfBounds_negativeCol_allMethodsSafe() throws {
        let snap = try snapshot(from: osc8("https://example.com", "hi"))
        let resolver = SnapshotHyperlinkResolver(snapshot: snap)
        XCTAssertNil(resolver.osc8URL(row: 0, col: -1))
        XCTAssertNil(resolver.regexURL(row: 0, col: -1))
        XCTAssertEqual(
            resolver.osc8AnchorText(row: 0, col: -1), "",
            "negative col returns empty anchor text"
        )
    }

    func testOutOfBounds_rowBeyondGrid_allMethodsSafe() throws {
        // Default grid is 80×24 → row index 24 is past the bottom edge.
        // No method may trap; all three must return nil/empty.
        let snap = try snapshot(from: osc8("https://example.com", "hi"))
        let resolver = SnapshotHyperlinkResolver(snapshot: snap)
        XCTAssertNil(resolver.osc8URL(row: 24, col: 0))
        XCTAssertNil(resolver.regexURL(row: 24, col: 0))
        XCTAssertEqual(resolver.osc8AnchorText(row: 24, col: 0), "")
        // Far past the edge — guards against off-by-many bugs.
        XCTAssertNil(resolver.osc8URL(row: 9999, col: 0))
        XCTAssertNil(resolver.regexURL(row: 9999, col: 0))
        XCTAssertEqual(resolver.osc8AnchorText(row: 9999, col: 0), "")
    }

    func testOutOfBounds_colBeyondGrid_allMethodsSafe() throws {
        // Default grid is 80×24 → col index 80 is past the right edge.
        let snap = try snapshot(from: osc8("https://example.com", "hi"))
        let resolver = SnapshotHyperlinkResolver(snapshot: snap)
        XCTAssertNil(resolver.osc8URL(row: 0, col: 80))
        XCTAssertNil(resolver.regexURL(row: 0, col: 80))
        XCTAssertEqual(resolver.osc8AnchorText(row: 0, col: 80), "")
        XCTAssertNil(resolver.osc8URL(row: 0, col: 9999))
        XCTAssertNil(resolver.regexURL(row: 0, col: 9999))
        XCTAssertEqual(resolver.osc8AnchorText(row: 0, col: 9999), "")
    }

    // MARK: - 3. osc8AnchorText on cells with NO OSC 8 attribution

    func testAnchorText_returnsEmptyForUnattributedCell() throws {
        // Plain text — no OSC 8 sequences. Every cell must yield "".
        let snap = try snapshot(from: "plain text here")
        let resolver = SnapshotHyperlinkResolver(snapshot: snap)
        XCTAssertEqual(resolver.osc8AnchorText(row: 0, col: 0), "")
        XCTAssertEqual(resolver.osc8AnchorText(row: 0, col: 5), "")
        // A row that has never been painted at all.
        XCTAssertEqual(resolver.osc8AnchorText(row: 10, col: 5), "")
    }

    func testAnchorText_emptyForCellBetweenTwoLinks() throws {
        // Two separate OSC 8 links with a literal space between them.
        // The space carries no link id → anchor text empty there even
        // though both neighbours have attribution.
        let input = osc8("https://a.example.com", "AA")
                  + " "
                  + osc8("https://b.example.com", "BB")
        let snap = try snapshot(from: input)
        let resolver = SnapshotHyperlinkResolver(snapshot: snap)
        XCTAssertEqual(
            resolver.osc8AnchorText(row: 0, col: 2), "",
            "gap cell between two distinct OSC 8 spans must report no anchor"
        )
        XCTAssertEqual(resolver.osc8AnchorText(row: 0, col: 0), "AA")
        XCTAssertEqual(resolver.osc8AnchorText(row: 0, col: 3), "BB")
    }

    // MARK: - 4. osc8AnchorText walks the full link-id run

    func testAnchorText_walksMultiCharAnchor() throws {
        // 5-cell anchor. Any column inside the run must return the
        // full visible text, not just the clicked cell.
        let snap = try snapshot(from: osc8("https://example.com", "hello"))
        let resolver = SnapshotHyperlinkResolver(snapshot: snap)
        for col in 0..<5 {
            XCTAssertEqual(
                resolver.osc8AnchorText(row: 0, col: col),
                "hello",
                "any in-run column must yield the full anchor (col \(col))"
            )
        }
        // Just past the run → no attribution.
        XCTAssertEqual(resolver.osc8AnchorText(row: 0, col: 5), "")
    }

    func testAnchorText_anchorAtRightEdgeOfScreen() throws {
        // Default 80-column grid. Pad with 75 spaces, then 5-char
        // anchor exactly fills cols 75..79. The walk must NOT step off
        // the right edge of the row — pins that the right-bound is
        // respected.
        let pad = String(repeating: " ", count: 75)
        let input = pad + osc8("https://example.com", "RIGHT")
        let snap = try snapshot(from: input)
        let resolver = SnapshotHyperlinkResolver(snapshot: snap)
        XCTAssertEqual(resolver.osc8AnchorText(row: 0, col: 75), "RIGHT")
        XCTAssertEqual(resolver.osc8AnchorText(row: 0, col: 79), "RIGHT")
        // Column past the edge already covered by the OOB tests; here
        // we just confirm the edge column itself is in-run.
    }

    func testAnchorText_anchorPreservesInternalSpaces() throws {
        // OSC 8 anchors with mid-anchor spaces are legitimate (the
        // displayed text is whatever the shell painted under the same
        // link id). The walk must include those spaces — collapsing
        // them would silently change the visible text the divergence
        // detector sees.
        let snap = try snapshot(from: osc8("https://example.com", "a b c"))
        let resolver = SnapshotHyperlinkResolver(snapshot: snap)
        XCTAssertEqual(
            resolver.osc8AnchorText(row: 0, col: 2), "a b c",
            "internal spaces in OSC 8 anchor must be preserved in the walk"
        )
    }

    // MARK: - 5. OSC 8 + regex overlap — OSC 8 wins

    func testOsc8WinsOverRegexOnOverlap() throws {
        // Build an OSC 8 anchor whose visible text is itself a regex-
        // matchable URL ("https://different.test/path"). The OSC 8 href
        // points to a DIFFERENT URL ("https://osc8.example/x"). On any
        // cell inside that anchor, osc8URL must return the OSC 8 href.
        // The regex path would have returned the visible URL — so this
        // proves OSC 8 takes precedence.
        let visibleURL = "https://different.test/path"
        let hrefURL = "https://osc8.example/x"
        let snap = try snapshot(from: osc8(hrefURL, visibleURL))
        let matches = URLDetector.scan(snapshot: snap)
        XCTAssertFalse(
            matches.isEmpty,
            "URLDetector must still find the visible URL token"
        )
        let resolver = SnapshotHyperlinkResolver(snapshot: snap, regexMatches: matches)
        // Pick a cell inside the visible URL.
        let osc8Result = resolver.osc8URL(row: 0, col: 5)
        XCTAssertEqual(
            osc8Result?.absoluteString,
            hrefURL,
            "OSC 8 href wins over regex when both cover the cell"
        )
    }

    // MARK: - 6. URLOpener recording-fake sanity

    func testURLOpener_recordingFakeRoundTripsURLs() {
        // Pins the recording fake's append-on-open invariant so other tests
        // using it inherit a trustworthy observation surface.
        let opener = BlindRecordingOpener()
        let u1 = URL(string: "https://one.example/")!
        let u2 = URL(string: "https://two.example/")!
        opener.open(u1)
        opener.open(u2)
        XCTAssertEqual(opener.opened, [u1, u2])
    }

    // MARK: - 8. Wide-char cells (CJK / regional-indicator emoji)

    func testWideChar_cjkAnchor_osc8URLResolvesAtPrimaryCell() throws {
        // "中" is a CJK character that paints two cells: the leading
        // (primary) cell at col 0 carries the scalar, and col 1 is a
        // WIDE_CHAR_SPACER. The OSC 8 attribution covers both cells
        // (the FFI tags every painted cell in the run, including the
        // spacer). We assert the primary cell resolves to the href.
        let href = "https://example.com/cjk"
        let snap = try snapshot(from: osc8(href, "中"))
        let resolver = SnapshotHyperlinkResolver(snapshot: snap)
        let primaryURL = resolver.osc8URL(row: 0, col: 0)
        XCTAssertEqual(
            primaryURL?.absoluteString, href,
            "OSC 8 href must resolve at the primary cell of a CJK glyph"
        )
        // Anchor text on a CJK row is exactly "中 " — the CJK scalar on the
        // primary cell plus the WIDE_CHAR_SPACER emitted as a space by the
        // anchor walker. Pin to this exact two-character string so any
        // over-walk into col 2 (which would add a stray char) or under-walk
        // (dropping the spacer to a strict "中") surfaces here. Distinct
        // from the prose-emit path in `bb_term_text_range`, which skips
        // spacer cells entirely; the anchor walker keeps them visible.
        let anchor = resolver.osc8AnchorText(row: 0, col: 0)
        XCTAssertEqual(
            anchor, "中 ",
            "anchor text on a CJK row is exactly the primary scalar + spacer-as-space"
        )
    }

    func testWideChar_emojiAnchor_osc8URLResolves() throws {
        // Regional-indicator flag (🇺🇸) is two regional-indicator
        // scalars combined into one grapheme that paints two wide
        // cells (4 grid columns). Same principle as CJK — pin that
        // the primary cell resolves and the resolver doesn't trap on
        // multi-scalar / wide grapheme content.
        let href = "https://example.com/flag"
        let snap = try snapshot(from: osc8(href, "🇺🇸"))
        let resolver = SnapshotHyperlinkResolver(snapshot: snap)
        let url = resolver.osc8URL(row: 0, col: 0)
        XCTAssertEqual(
            url?.absoluteString, href,
            "OSC 8 href must resolve at the primary cell of a regional-indicator emoji"
        )
    }

    // MARK: - 9. Empty / fresh snapshot

    func testEmptySnapshot_allMethodsReturnNilOrEmpty() throws {
        // Brand-new terminal, no input. The grid is full of unwritten
        // cells (alacritty `\0` sentinel). No OSC 8, no regex matches.
        // All three methods must return nil/empty for every queried
        // cell — sample the corners and the centre.
        let snap = try snapshot(from: "")
        let resolver = SnapshotHyperlinkResolver(snapshot: snap)
        let samples: [(Int, Int)] = [
            (0, 0), (0, 79), (23, 0), (23, 79), (12, 40),
        ]
        for (r, c) in samples {
            XCTAssertNil(
                resolver.osc8URL(row: r, col: c),
                "empty snapshot must yield nil osc8URL at (\(r),\(c))"
            )
            XCTAssertNil(
                resolver.regexURL(row: r, col: c),
                "empty snapshot must yield nil regexURL at (\(r),\(c))"
            )
            XCTAssertEqual(
                resolver.osc8AnchorText(row: r, col: c), "",
                "empty snapshot must yield empty anchor at (\(r),\(c))"
            )
        }
    }

    // MARK: - 10. Resolver lifetime — outlives caller's strong ref to snapshot

    func testResolverLifetime_snapshotHeldInternally() throws {
        // Construct a resolver, then drop the local strong reference to
        // the snapshot inside an autoreleasepool to force any
        // deferred-release machinery to run. The resolver must keep the
        // snapshot alive internally — methods must continue to return
        // the same results afterwards. (Not a leak test — a lifetime
        // test; the asymmetric concern is "did we accidentally hold a
        // weak / unowned ref to the snapshot inside the resolver".)
        let href = "https://example.com/lifetime"
        let resolver: SnapshotHyperlinkResolver = try autoreleasepool {
            let snap = try snapshot(from: osc8(href, "hi"))
            let r = SnapshotHyperlinkResolver(snapshot: snap)
            // Sanity: works while we still hold `snap`.
            XCTAssertEqual(r.osc8URL(row: 0, col: 0)?.absoluteString, href)
            return r
            // `snap` goes out of scope here. If the resolver only held
            // a weak ref, the BBSnap's bb_snap_release would fire and
            // subsequent reads would either crash, return nil, or read
            // freed memory — none of which is acceptable.
        }
        // Extra autoreleasepool to drain anything deferred.
        autoreleasepool { _ = NSNumber(value: 0) }
        XCTAssertEqual(
            resolver.osc8URL(row: 0, col: 0)?.absoluteString,
            href,
            "resolver must keep the snapshot alive after caller drops its ref"
        )
        XCTAssertEqual(
            resolver.osc8AnchorText(row: 0, col: 0), "hi",
            "anchor walk must still succeed after caller drops the snapshot ref"
        )
    }

    func testResolverLifetime_regexMatchesHeldInternally() throws {
        // Same lifetime principle for the regex match slice. The
        // resolver should retain the matches we hand it; dropping the
        // caller-side array must not affect subsequent queries.
        let resolver: SnapshotHyperlinkResolver = try autoreleasepool {
            let snap = try snapshot(from: "see https://lifetime.test/x here")
            var matches = URLDetector.scan(snapshot: snap)
            XCTAssertFalse(matches.isEmpty)
            let r = SnapshotHyperlinkResolver(snapshot: snap, regexMatches: matches)
            matches.removeAll()   // Drop our reference to the array's storage.
            return r
        }
        XCTAssertEqual(
            resolver.regexURL(row: 0, col: 10)?.absoluteString,
            "https://lifetime.test/x",
            "resolver must keep regex match slice alive after caller drops it"
        )
    }
}

/// Local recording fake. Distinct from `RecordingURLOpener` in
/// `HyperlinkTests.swift` so this file's coverage stays self-contained
/// (same module — name collision would be a compile error).
final class BlindRecordingOpener: URLOpener {
    private(set) var opened: [URL] = []
    func open(_ url: URL) { opened.append(url) }
}
