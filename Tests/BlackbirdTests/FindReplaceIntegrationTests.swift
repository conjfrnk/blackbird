import XCTest
import AppKit
import Metal
import Combine
@testable import Blackbird
import BBCore

/// Integration-level tests for the replace path: verifies that
/// `replaceCurrentMatch` / `replaceAllMatches` emit the expected byte sequences
/// (DEL×N + replacement UTF-8) through the view's send path.
///
/// These tests use `#if DEBUG` hooks injected into `TerminalView`:
///   - `replaceSnapshotForTests`  — supplies cursor position without a PTY.
///   - `replaceFindMatchesForTests` — supplies pre-computed match list.
///   - `replaceByteCapture`       — captures emitted bytes instead of PTY write.
///
/// No TerminalSession is needed; no PTY is started. All allocations are tiny.
final class FindReplaceIntegrationTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        TestHostTermination.shared.register()
    }

    // MARK: - Helpers

    private func makeView() throws -> TerminalView {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        return TerminalView(
            frame: NSRect(x: 0, y: 0, width: 800, height: 480),
            device: device
        )
    }

    /// Build a minimal BBSnapshot via TerminalSession + /bin/cat, wait for the
    /// first snapshot, then return it. The snapshot is only needed for its
    /// `cursorRow` field; we start a real session to get a properly-typed value.
    ///
    /// Memory: a 80×24 BBTerm grid is < 1 MB. Time: < 3 s.
    private func liveSnapshot() throws -> BBSnapshot {
        let session = try TerminalSession.start(
            shell: "/bin/cat",
            arguments: [],
            size: .init(cols: 80, rows: 24)
        )
        defer { session.terminate() }
        let exp = expectation(description: "first snapshot")
        var snap: BBSnapshot?
        var c: AnyCancellable?
        c = session.$snapshot.compactMap { $0 }.sink { s in
            if snap == nil { snap = s; c?.cancel(); exp.fulfill() }
        }
        wait(for: [exp], timeout: 3.0)
        return try XCTUnwrap(snap)
    }

    // MARK: - Replace-current: DEL×N + replacement

    func test_replaceCurrent_emitsDelNPlusReplacement() throws {
        let view = try makeView()
        let snap = try liveSnapshot()

        // "foo" sits at cols 4..6 on the cursor's row.
        let cursorLine = Int32(snap.cursorRow)
        view.replaceSnapshotForTests     = snap
        view.replaceFindMatchesForTests  = [(line: cursorLine, startCol: 4, endCol: 6)]

        var captured = Data()
        view.replaceByteCapture = { captured.append($0) }

        // Inject the match index so replaceCurrentMatch picks the right entry.
        // findCurrentIndex is 0 by default which matches our single entry.
        view._invokeReplaceCurrentForTests(replacement: "baz")

        // Expect: DEL DEL DEL (3 × 0x7F) + "baz"
        let expected = Data([0x7F, 0x7F, 0x7F]) + Data("baz".utf8)
        XCTAssertEqual(captured, expected,
                       "Replace must emit DEL×matchLen then the replacement bytes")
    }

    func test_replaceCurrent_emptyReplacement_emitsOnlyDels() throws {
        let view = try makeView()
        let snap = try liveSnapshot()

        let cursorLine = Int32(snap.cursorRow)
        view.replaceSnapshotForTests    = snap
        view.replaceFindMatchesForTests = [(line: cursorLine, startCol: 0, endCol: 1)]

        var captured = Data()
        view.replaceByteCapture = { captured.append($0) }

        view._invokeReplaceCurrentForTests(replacement: "")

        XCTAssertEqual(captured, Data([0x7F, 0x7F]),
                       "Empty replacement still emits DEL bytes for the match span")
    }

    func test_replaceCurrent_replacementWithLF_isRefused() throws {
        // Audit L20. sanitizePasteControls intentionally preserves LF
        // (paste path treats it as Enter). For find-replace at a non-
        // bracketed-paste prompt the same posture is wrong — a `\n`
        // in the replacement string would execute the leading
        // fragment as a separate command. Refuse with a transient
        // message; emit zero bytes.
        let view = try makeView()
        let snap = try liveSnapshot()

        let cursorLine = Int32(snap.cursorRow)
        view.replaceSnapshotForTests    = snap
        view.replaceFindMatchesForTests = [(line: cursorLine, startCol: 0, endCol: 2)]

        var captured = Data()
        view.replaceByteCapture = { captured.append($0) }

        view._invokeReplaceCurrentForTests(replacement: "foo\nbar")

        XCTAssertTrue(
            captured.isEmpty,
            "replacement containing LF must be refused — got \(Array(captured)) bytes"
        )
    }

    func test_replaceCurrent_replacementWithCR_isRefused() throws {
        // Audit L20 (sibling). 0x0D survives `sanitizePasteControls`
        // and is treated as Enter by raw / ICRNL-off shells, same
        // command-injection class as LF. The find-replace gate
        // rejects both.
        let view = try makeView()
        let snap = try liveSnapshot()

        let cursorLine = Int32(snap.cursorRow)
        view.replaceSnapshotForTests    = snap
        view.replaceFindMatchesForTests = [(line: cursorLine, startCol: 0, endCol: 2)]

        var captured = Data()
        view.replaceByteCapture = { captured.append($0) }

        view._invokeReplaceCurrentForTests(replacement: "foo\rbar")

        XCTAssertTrue(
            captured.isEmpty,
            "replacement containing CR must be refused — got \(Array(captured)) bytes"
        )
    }

    func test_replaceCurrent_offInputLine_emitsNothing() throws {
        let view = try makeView()
        let snap = try liveSnapshot()

        // Put the match on a different buffer line than the cursor.
        let offLine = Int32(snap.cursorRow) + 1
        view.replaceSnapshotForTests    = snap
        view.replaceFindMatchesForTests = [(line: offLine, startCol: 0, endCol: 2)]

        var captured = Data()
        view.replaceByteCapture = { captured.append($0) }

        view._invokeReplaceCurrentForTests(replacement: "xyz")

        XCTAssertTrue(captured.isEmpty,
                      "Replace for off-input-line match must not emit any bytes")
    }

    // MARK: - Replace-all: right-to-left ordering

    func test_replaceAll_twoMatchesSameRow_rightToLeft() throws {
        let view = try makeView()
        let snap = try liveSnapshot()

        let cursorLine = Int32(snap.cursorRow)
        // Two "foo" matches: cols 0..2 and cols 10..12
        view.replaceSnapshotForTests    = snap
        view.replaceFindMatchesForTests = [
            (line: cursorLine, startCol: 0,  endCol: 2),
            (line: cursorLine, startCol: 10, endCol: 12),
        ]

        var allCaptures: [Data] = []
        view.replaceByteCapture = { allCaptures.append($0) }

        view._invokeReplaceAllForTests(replacement: "bar")

        // Right-to-left: cols 10..12 processed first, then 0..2.
        // Each replacement emits: DEL DEL DEL + "bar"
        let delBar = Data([0x7F, 0x7F, 0x7F]) + Data("bar".utf8)
        let expected = delBar + delBar   // twice, right-to-left
        let combined = allCaptures.reduce(Data(), +)
        XCTAssertEqual(combined, expected,
                       "Replace All must process matches right-to-left on the input line")
    }

    func test_replaceAll_mixedLines_onlyInputLineReplaced() throws {
        let view = try makeView()
        let snap = try liveSnapshot()

        let cursorLine = Int32(snap.cursorRow)
        let otherLine  = cursorLine - 1          // scrollback line

        // One match on the input line, one in scrollback.
        view.replaceSnapshotForTests    = snap
        view.replaceFindMatchesForTests = [
            (line: cursorLine, startCol: 5, endCol: 7),
            (line: otherLine,  startCol: 0, endCol: 2),
        ]

        var captured = Data()
        view.replaceByteCapture = { captured.append($0) }

        view._invokeReplaceAllForTests(replacement: "qux")

        // Only the input-line match should produce bytes.
        let expected = Data([0x7F, 0x7F, 0x7F]) + Data("qux".utf8)
        XCTAssertEqual(captured, expected,
                       "Replace All must skip off-input-line matches")
    }
}

// MARK: - Test-only TerminalView hooks

#if DEBUG
extension TerminalView {
    /// Calls replaceCurrentMatch(with:) directly — bypasses the delegate chain
    /// so tests don't need a real FindBar wired up.
    func _invokeReplaceCurrentForTests(replacement: String) {
        replaceCurrentMatch(with: replacement)
    }

    /// Calls replaceAllMatches(with:) directly.
    func _invokeReplaceAllForTests(replacement: String) {
        replaceAllMatches(with: replacement)
    }
}
#endif

// MARK: - Bug #16: stale findMatches against the live snapshot

/// Regression coverage for Bug #16 (findbar-selection F11): when output
/// arrives between `performSearch` and ⌘G, `findMatches` holds (line, col)
/// tuples that were computed against the OLD snapshot. Cycling those
/// stale coordinates jumps the highlight to a row that no longer holds
/// the match — the user sees the selection land on an unrelated line, or
/// scroll into off-screen scrollback.
///
/// The fix stamps `findMatchesSeq` with the snapshot's `sequenceID` at
/// scan time, then `advanceFind` checks whether the current snapshot has
/// moved on before cycling. If it has, `performSearch` is rerun
/// synchronously against the live grid.
///
/// These tests pin the seq-stamp + stale-detection contract directly,
/// without spinning up a full session — the behaviour is deterministic
/// and has no async hops to wait on.
final class FindStaleMatchInvalidationTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        TestHostTermination.shared.register()
    }

    /// pre-flight: 1 TerminalView (lightweight; just an MTKView wrapper)
    /// + 2 BBTerm instances at 20×4 (< 5 KB each, no scrollback growth).
    /// No PTY, no session subscription. Wall < 100 ms.
    private func makeView() throws -> TerminalView {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        return TerminalView(
            frame: NSRect(x: 0, y: 0, width: 800, height: 480),
            device: device
        )
    }

    /// Distinct snapshots from a single BBTerm bump `sequenceID` on every
    /// `snapshot()` call (allocator is monotonic). That gives us two
    /// snapshots whose grids agree but whose identities differ — exactly
    /// the shape of "output arrived, snapshot swapped" without needing
    /// to drive PTY traffic.
    private func twoFreshSnapshots() throws -> (BBSnapshot, BBSnapshot) {
        let term = try XCTUnwrap(BBTerm(size: .init(cols: 20, rows: 4)))
        term.input("alpha")
        let s1 = try XCTUnwrap(term.snapshot())
        // Mutate the grid so s2 is meaningfully newer (and re-snapshot
        // bumps the seq counter).
        term.input("\r\nbeta")
        let s2 = try XCTUnwrap(term.snapshot())
        XCTAssertNotEqual(
            s1.sequenceID, s2.sequenceID,
            "test setup: BBTerm.snapshot() must allocate a fresh sequenceID"
        )
        return (s1, s2)
    }

    /// `performSearch` must clear `findMatchesSeq` whenever it discards
    /// the prior match list. If a stale seq survived a clear, the next
    /// `advanceFind` would compare against the OLD stamp and could either
    /// false-skip a rescan (seq accidentally still matches a future
    /// snapshot) or false-trigger one (extra work). Both directions are
    /// regressions, so we pin the clear-path explicitly.
    func test_performSearch_resetsFindMatchesSeq_onClear() throws {
        let view = try makeView()
        let (s1, _) = try twoFreshSnapshots()
        view.currentSnapshot = s1
        // Pre-populate state as if a previous search had run.
        view.findMatches = [(line: 0, startCol: 0, endCol: 4)]
        view.findMatchesSeq = 99
        view.findQuery = "alpha"
        // Empty query → performSearch enters its bail-out branch which
        // clears findMatches; the seq must clear in lockstep so
        // refreshFindMatchesIfStale doesn't gate the next rescan on a
        // stale (and now meaningless) stamp.
        view.performSearch(query: "")
        XCTAssertNil(
            view.findMatchesSeq,
            "performSearch must clear findMatchesSeq when it clears "
            + "findMatches so the two stay coupled. Bug #16."
        )
    }

    /// The core invariant: when `currentSnapshot.sequenceID` differs from
    /// `findMatchesSeq`, `advanceFind` must re-run `performSearch`. We
    /// detect the rerun by the side-effect: with no session wired, the
    /// rerun path nils-out findMatchesSeq and clears findMatches (the
    /// guard-let session/snapshot branch). If advanceFind had skipped the
    /// rerun, both pieces of state would survive untouched.
    func test_advanceFind_rerunsSearch_whenSnapshotSeqChanged() throws {
        let view = try makeView()
        let (s1, s2) = try twoFreshSnapshots()

        // Simulate: performSearch was run against s1 and found one match.
        view.currentSnapshot = s1
        view.findQuery = "alpha"
        view.findMatches = [(line: 0, startCol: 0, endCol: 4)]
        view.findMatchesSeq = s1.sequenceID
        view.findCurrentIndex = 0

        // Output arrives → snapshot swaps. (The didSet's
        // scheduleFindRefresh is debounced via DispatchQueue.main.async,
        // so it has NOT fired yet on this same runloop turn.)
        view.currentSnapshot = s2

        // ⌘G fires while findMatches still holds the stale s1-tuples.
        view.advanceFind(direction: .forward)

        // The stale-cache path took over and called performSearch. With
        // no session wired, performSearch hits its session/snapshot guard
        // and nils findMatchesSeq + clears findMatches. Either side-effect
        // is sufficient evidence the rerun happened.
        XCTAssertNil(
            view.findMatchesSeq,
            "advanceFind must rerun performSearch when currentSnapshot's "
            + "sequenceID differs from findMatchesSeq; the rerun cleared "
            + "the seq stamp via the session-less guard. Bug #16."
        )
        XCTAssertTrue(
            view.findMatches.isEmpty,
            "Stale findMatches from the prior snapshot must be discarded "
            + "before advanceFind cycles, so the highlight can't land on "
            + "a row that no longer holds the match. Bug #16."
        )
    }

    /// Counter-test: when the snapshot hasn't changed, advanceFind MUST
    /// keep cycling the existing matches — the staleness check must not
    /// false-positive on every press. Without this guard, each ⌘G would
    /// rerun the full scan and reset findCurrentIndex, breaking the cycle.
    func test_advanceFind_preservesMatches_whenSnapshotSeqUnchanged() throws {
        let view = try makeView()
        let (s1, _) = try twoFreshSnapshots()

        view.currentSnapshot = s1
        view.findQuery = "alpha"
        view.findMatches = [
            (line: 0, startCol: 0, endCol: 4),
            (line: 1, startCol: 5, endCol: 9),
        ]
        view.findMatchesSeq = s1.sequenceID
        view.findCurrentIndex = 0

        // No snapshot swap. ⌘G should advance to index 1.
        view.advanceFind(direction: .forward)

        XCTAssertEqual(
            view.findCurrentIndex, 1,
            "advanceFind must cycle to the next match when matches are "
            + "still valid against the live snapshot — the stale-check "
            + "cannot fire on a snapshot that hasn't moved on."
        )
        XCTAssertEqual(
            view.findMatches.count, 2,
            "Existing matches must survive a same-seq advanceFind"
        )
        XCTAssertEqual(
            view.findMatchesSeq, s1.sequenceID,
            "findMatchesSeq must remain stamped to the live snapshot"
        )
    }
}

// MARK: - High-4 / High-5 / High-6: wide-grapheme column math

/// `BBSnapshot.rowTextWithUTF16ToColMap` translates regex / String
/// ranges back to grid columns through a parallel UTF-16 → col map.
/// `nonSpacerCellCount` returns the shell-input character count for a
/// match span — the DEL count `sendReplacement` needs to erase via
/// readline. Both replace `String.distance` / `r.location`-as-column
/// math that overshot by N per wide-cell glyph on the row.
///
/// Fixtures use `BBTerm` directly (no PTY, no session) so each test is
/// well under the per-test memory budget (~5 KB grid + transient String).
final class FindWideGraphemeColumnMapTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        TestHostTermination.shared.register()
    }

    /// Build a snapshot where row 0 contains `text` starting at col 0.
    /// `cols` matches the visible content exactly so trailing-space
    /// padding doesn't bloat the test fixtures (alacritty initialises
    /// cells with ' ' and never reverts to '\0', so cols past the typed
    /// content are reported as spaces by the row walker — we keep cols
    /// tight to keep assertions readable).
    private func snapshotWithRow0(_ text: String, cols: Int) throws -> BBSnapshot {
        let term = try XCTUnwrap(BBTerm(size: .init(cols: UInt16(cols), rows: 4)))
        term.input("\u{1B}[1;1H")
        term.input(text)
        return try XCTUnwrap(term.snapshot())
    }

    // MARK: rowTextWithUTF16ToColMap

    func test_rowTextWithUTF16ToColMap_widCJK() throws {
        // Row contents: "中abc" — 中 (BMP, 1 UTF-16 unit) at cols 0–1
        // (wide), then a/b/c each 1 UTF-16 unit at cols 2/3/4. cols=5
        // exactly so no trailing space padding.
        let snap = try snapshotWithRow0("中abc", cols: 5)
        let mapped = try XCTUnwrap(snap.rowTextWithUTF16ToColMap(row: 0))
        XCTAssertEqual(mapped.text, "中abc")
        // utf16ToCol[i] = starting col of UTF-16 unit i.
        // [0] → 中 starts at col 0
        // [1] → a starts at col 2 (中 owns cols 0–1)
        // [2] → b at col 3
        // [3] → c at col 4
        // [4] → sentinel: col 5 (immediately after c's only cell)
        XCTAssertEqual(mapped.utf16ToCol, [0, 2, 3, 4, 5])
    }

    func test_rowTextWithUTF16ToColMap_emoji() throws {
        // 😀 = U+1F600, 2 UTF-16 units (high+low surrogates), 1 char,
        // 2 cells. Then "test" at cols 2/3/4/5.
        let snap = try snapshotWithRow0("😀test", cols: 6)
        let mapped = try XCTUnwrap(snap.rowTextWithUTF16ToColMap(row: 0))
        XCTAssertEqual(mapped.text, "😀test")
        // 😀 contributes TWO UTF-16 units, both starting at col 0.
        // Then t/e/s/t at cols 2/3/4/5. Sentinel = 6.
        XCTAssertEqual(mapped.utf16ToCol, [0, 0, 2, 3, 4, 5, 6])
    }

    func test_rowTextWithUTF16ToColMap_plainASCII() throws {
        let snap = try snapshotWithRow0("hello", cols: 5)
        let mapped = try XCTUnwrap(snap.rowTextWithUTF16ToColMap(row: 0))
        XCTAssertEqual(mapped.text, "hello")
        XCTAssertEqual(mapped.utf16ToCol, [0, 1, 2, 3, 4, 5])
    }

    func test_rowTextWithUTF16ToColMap_widCJKEmbeddedAscii() throws {
        // Mixed sequence: 中 + abc + 中 + xyz. Each 中 is 2 cells.
        // Cols: 0-1 (中), 2-4 (abc), 5-6 (中), 7-9 (xyz). Total cols=10.
        let snap = try snapshotWithRow0("中abc中xyz", cols: 10)
        let mapped = try XCTUnwrap(snap.rowTextWithUTF16ToColMap(row: 0))
        XCTAssertEqual(mapped.text, "中abc中xyz")
        // 8 chars (中=1, abc=3, 中=1, xyz=3), 8 UTF-16 units (中 is BMP).
        // [0] 中 → col 0
        // [1] a → col 2  (after first 中's 2 cells)
        // [2] b → col 3
        // [3] c → col 4
        // [4] 中 → col 5
        // [5] x → col 7  (after second 中's 2 cells)
        // [6] y → col 8
        // [7] z → col 9
        // [8] sentinel → col 10
        XCTAssertEqual(mapped.utf16ToCol, [0, 2, 3, 4, 5, 7, 8, 9, 10])
    }

    func test_rowTextWithUTF16ToColMap_outOfRangeRowReturnsNil() throws {
        let snap = try snapshotWithRow0("hi", cols: 2)
        XCTAssertNil(snap.rowTextWithUTF16ToColMap(row: -1))
        XCTAssertNil(snap.rowTextWithUTF16ToColMap(row: snap.rows))
        XCTAssertNil(snap.rowTextWithUTF16ToColMap(row: 99_999))
    }

    // MARK: nonSpacerCellCount

    func test_nonSpacerCellCount_widCJKMatch() throws {
        // Row "中abc"; full-row match (cols 0–4) is 4 shell-chars.
        let snap = try snapshotWithRow0("中abc", cols: 5)
        XCTAssertEqual(snap.nonSpacerCellCount(row: 0, startCol: 0, endCol: 4), 4)
        // 中-only match (cols 0–1) is 1 shell-char.
        XCTAssertEqual(snap.nonSpacerCellCount(row: 0, startCol: 0, endCol: 1), 1)
        // abc-only match (cols 2–4) is 3 shell-chars.
        XCTAssertEqual(snap.nonSpacerCellCount(row: 0, startCol: 2, endCol: 4), 3)
    }

    func test_nonSpacerCellCount_emojiMatch() throws {
        // Row "😀test"; full-row match (cols 0–5) is 5 shell-chars
        // (😀 + t + e + s + t).
        let snap = try snapshotWithRow0("😀test", cols: 6)
        XCTAssertEqual(snap.nonSpacerCellCount(row: 0, startCol: 0, endCol: 5), 5)
        XCTAssertEqual(snap.nonSpacerCellCount(row: 0, startCol: 0, endCol: 1), 1)  // 😀
    }

    func test_nonSpacerCellCount_outOfRangeReturnsNil() throws {
        let snap = try snapshotWithRow0("hi", cols: 2)
        XCTAssertNil(snap.nonSpacerCellCount(row: -1, startCol: 0, endCol: 0))
        XCTAssertNil(snap.nonSpacerCellCount(row: 0, startCol: -1, endCol: 0))
        XCTAssertNil(snap.nonSpacerCellCount(row: 0, startCol: 0, endCol: snap.cols))
        XCTAssertNil(snap.nonSpacerCellCount(row: 0, startCol: 5, endCol: 2))
    }

    // MARK: replace integration — H6

    func test_replaceCurrent_widCJKEmitsCorrectDelCount() throws {
        // Row "中abc"; match the entire span (cols 0–4). Pre-fix the
        // DEL count was endCol-startCol+1 = 5, which would erase one
        // shell char too many (eating a space before the match).
        // Post-fix the count is 4 (one DEL per shell-input character).
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let view = TerminalView(
            frame: NSRect(x: 0, y: 0, width: 800, height: 480),
            device: device
        )
        let snap = try snapshotWithRow0("中abc", cols: 5)
        let cursorLine = Int32(snap.cursorRow)
        // After "\u{1B}[1;1H" + "中abc" the cursor is on row 0 (where
        // we wrote), so the on-cursor-line guard passes.
        XCTAssertEqual(cursorLine, 0,
                       "test fixture: cursor must land on the row carrying the wide chars")
        view.replaceSnapshotForTests    = snap
        view.replaceFindMatchesForTests = [(line: cursorLine, startCol: 0, endCol: 4)]
        var captured = Data()
        view.replaceByteCapture = { captured.append($0) }
        view._invokeReplaceCurrentForTests(replacement: "x")
        // Expect: 4 × 0x7F (one per shell-char in 中abc) + "x".
        XCTAssertEqual(captured, Data([0x7F, 0x7F, 0x7F, 0x7F]) + Data("x".utf8))
    }

    func test_replaceCurrent_widCJKOnlyEmitsOneDel() throws {
        // Match just the 中 cell (cols 0–1). One shell-char, one DEL.
        // Pre-fix the count was 2 (col span), eating an extra char.
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let view = TerminalView(
            frame: NSRect(x: 0, y: 0, width: 800, height: 480),
            device: device
        )
        let snap = try snapshotWithRow0("中abc", cols: 5)
        let cursorLine = Int32(snap.cursorRow)
        view.replaceSnapshotForTests    = snap
        view.replaceFindMatchesForTests = [(line: cursorLine, startCol: 0, endCol: 1)]
        var captured = Data()
        view.replaceByteCapture = { captured.append($0) }
        view._invokeReplaceCurrentForTests(replacement: "Y")
        XCTAssertEqual(captured, Data([0x7F]) + Data("Y".utf8))
    }

    // MARK: - M10: Replace text routes through paste sanitizer

    /// NSTextField inside the Find bar accepts pasted bytes via its
    /// own field-editor paste handler — completely separate from
    /// `TerminalView.paste` and thus from the paste sanitizer. A user
    /// who pastes a Trojan-Source RLO into the Replace field would
    /// otherwise smuggle the bidi byte straight into the live shell.
    /// Pin the policy: replacement bytes are scrubbed through the
    /// same `sanitizePasteControls` + `stripBidiOverrides` pipeline.
    /// Audit M10.
    func test_replaceCurrent_scrubsBidiOverrideFromReplacementText() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let view = TerminalView(
            frame: NSRect(x: 0, y: 0, width: 800, height: 480),
            device: device
        )
        let snap = try snapshotWithRow0("ab", cols: 2)
        let cursorLine = Int32(snap.cursorRow)
        view.replaceSnapshotForTests    = snap
        view.replaceFindMatchesForTests = [(line: cursorLine, startCol: 0, endCol: 1)]
        var captured = Data()
        view.replaceByteCapture = { captured.append($0) }
        // Replacement contains an embedded RLO (U+202E) — the canonical
        // homograph attack codepoint. Must be stripped before reaching
        // the PTY.
        view._invokeReplaceCurrentForTests(replacement: "x\u{202E}y")
        // Expect: 2 DELs (matched "ab") + scrubbed "xy" (no RLO).
        XCTAssertEqual(captured, Data([0x7F, 0x7F]) + Data("xy".utf8))
        XCTAssertFalse(
            captured.contains(0xAE),
            "RLO byte (0xAE inside the E2 80 AE sequence) must not survive scrub"
        )
    }

    func test_replaceCurrent_scrubsC0FromReplacementText() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let view = TerminalView(
            frame: NSRect(x: 0, y: 0, width: 800, height: 480),
            device: device
        )
        let snap = try snapshotWithRow0("ab", cols: 2)
        let cursorLine = Int32(snap.cursorRow)
        view.replaceSnapshotForTests    = snap
        view.replaceFindMatchesForTests = [(line: cursorLine, startCol: 0, endCol: 1)]
        var captured = Data()
        view.replaceByteCapture = { captured.append($0) }
        // Replacement contains ESC + a Bell — both should be replaced
        // with space by sanitizePasteControls.
        view._invokeReplaceCurrentForTests(replacement: "x\u{1B}\u{07}y")
        XCTAssertEqual(captured, Data([0x7F, 0x7F]) + Data("x  y".utf8))
    }
}
