import XCTest
import AppKit
import Metal
@testable import Blackbird
import BBCore

/// Blind behaviour tests for `FindController.captureRows(...)`, the
/// haystack builder the find bar scans. Written from the spec:
///
///  - Rows come back in ascending `line` order (scrollback lines are
///    negative, viewport lines `0..<rows` relative to `displayOffset`).
///  - Every NON-empty buffer line appears exactly once, with `hay` equal
///    to its text minus trailing spaces; empty rows are omitted.
///  - Viewport rows carry a non-nil `utf16ToCol` map; scrollback rows
///    carry `nil`.
///  - One entry per PHYSICAL row: a soft-wrapped 50-char line in a
///    40-col grid yields two entries; a wide-character line yields one.
///  - A 5000-line scrollback range returns 5000 entries (crosses the
///    internal chunking boundary).
///
/// Fixture: a headless `TerminalView` bound to a headless
/// `TerminalSession` (real BBTerm, no PTY, no shell) resized to 40×6 with
/// the default 100 K-line scrollback. Feeds are synchronous
/// (`feedBytesForTests`), snapshots are taken directly — no runloop
/// pumping. Largest test: 5005 lines × 40 cells ≈ 200 K cells, a few MB.
final class FindCaptureRowsBlindTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        TestHostTermination.shared.register()
    }

    // MARK: - Fixture

    /// `TerminalView.session` is weak, so the strong `session` here is
    /// load-bearing for the test's lifetime.
    private struct Rig {
        let view: TerminalView
        let session: TerminalSession
    }

    private let cols: UInt16 = 40
    private let rows: UInt16 = 6

    private func makeRig(file: StaticString = #filePath, line: UInt = #line) throws -> Rig {
        let view = try XCTUnwrap(TerminalView.makeHeadlessForTests(), "Metal device required", file: file, line: line)
        let session = TerminalSession.makeHeadlessForTests()
        session.resize(to: .init(cols: cols, rows: rows))
        view.session = session
        return Rig(view: view, session: session)
    }

    /// Feed synchronously, then take a fresh snapshot and make it the
    /// view's current one. Returns the snapshot.
    @discardableResult
    private func feedAndSnapshot(_ rig: Rig, _ text: String,
                                 file: StaticString = #filePath, line: UInt = #line) throws -> BBSnapshot {
        rig.session.feedBytesForTests(Data(text.utf8))
        let snap = try XCTUnwrap(rig.session.takeSnapshotForTests(), "snapshot must be available", file: file, line: line)
        rig.view.currentSnapshot = snap
        return snap
    }

    private func captureAll(_ rig: Rig, _ snap: BBSnapshot) -> [(line: Int32, hay: String, utf16ToCol: [Int]?)] {
        rig.view.findController.captureRows(
            topLine: -Int32(snap.historySize),
            bottomLine: Int32(snap.rows - 1),
            cols: snap.cols,
            session: rig.session,
            snap: snap
        )
    }

    private func assertAscendingUniqueLines(
        _ captured: [(line: Int32, hay: String, utf16ToCol: [Int]?)],
        file: StaticString = #filePath, line: UInt = #line
    ) {
        let lines = captured.map(\.line)
        for i in 1..<max(1, lines.count) where lines[i] <= lines[i - 1] {
            XCTFail("rows must be in strictly ascending line order; \(lines[i - 1]) then \(lines[i]) at index \(i)",
                    file: file, line: line)
        }
        XCTAssertEqual(Set(lines).count, lines.count, "no buffer line may appear twice", file: file, line: line)
    }

    // MARK: - Fixture sanity

    func test_fixture_gridIs40x6WithHistory() throws {
        let rig = try makeRig()
        let snap = try feedAndSnapshot(rig, "")
        XCTAssertEqual(snap.cols, Int(cols), "headless session must accept the 40-col resize")
        XCTAssertEqual(snap.rows, Int(rows), "headless session must accept the 6-row resize")
    }

    // MARK: - 30 numbered lines: order, uniqueness, trimming, map presence

    /// 30 lines on a 6-row grid: the first 25 scroll into history, lines
    /// 025–029 sit on viewport rows 0–4, row 5 is the empty cursor row.
    func test_thirtyNumberedLines_capturedOnceEachInOrderWithCorrectMaps() throws {
        let rig = try makeRig()
        var text = ""
        for i in 0..<30 { text += String(format: "line %03d\r\n", i) }
        let snap = try feedAndSnapshot(rig, text)

        XCTAssertGreaterThanOrEqual(snap.historySize, 20, "most of the 30 lines must have scrolled into history")
        XCTAssertEqual(snap.displayOffset, 0, "fixture is not scrolled")

        let captured = captureAll(rig, snap)

        assertAscendingUniqueLines(captured)

        let expected = (0..<30).map { String(format: "line %03d", $0) }
        XCTAssertEqual(
            captured.map(\.hay), expected,
            "every non-empty buffer line must appear exactly once, trimmed, in buffer order; "
            + "the empty cursor row must be omitted"
        )
        XCTAssertFalse(captured.contains { $0.hay.isEmpty }, "no captured hay may be empty")
        XCTAssertFalse(
            captured.contains { $0.hay.allSatisfy { $0 == " " } },
            "a blank buffer row (the empty cursor row) must be omitted, not returned as a run of spaces"
        )
        XCTAssertFalse(captured.contains { $0.hay.hasSuffix(" ") }, "hay must not carry trailing spaces")

        let viewportRange = 0..<Int32(snap.rows)
        for row in captured {
            let isViewport = viewportRange.contains(row.line + Int32(snap.displayOffset))
            if isViewport {
                XCTAssertNotNil(
                    row.utf16ToCol,
                    "viewport row line \(row.line) ('\(row.hay)') must carry a utf16ToCol map"
                )
                if let map = row.utf16ToCol {
                    XCTAssertGreaterThanOrEqual(
                        map.count, row.hay.utf16.count,
                        "viewport map must cover every UTF-16 unit of '\(row.hay)'"
                    )
                }
            } else {
                XCTAssertNil(
                    row.utf16ToCol,
                    "scrollback row line \(row.line) ('\(row.hay)') must have a nil utf16ToCol"
                )
            }
        }
        // Both classes must actually be present, or the branch above is vacuous.
        XCTAssertTrue(captured.contains { $0.utf16ToCol == nil }, "fixture must include scrollback rows")
        XCTAssertTrue(captured.contains { $0.utf16ToCol != nil }, "fixture must include viewport rows")
        XCTAssertEqual(captured.first?.line, -Int32(snap.historySize), "first entry must be the oldest history line")
        XCTAssertEqual(captured.last?.line, 4, "last non-empty line is viewport row 4 (row 5 is the empty cursor row)")
    }

    // MARK: - Wide character in scrollback

    func test_wideCharacterScrollbackLine_isOneRowWithFullText() throws {
        let rig = try makeRig()
        // Push the wide line well into history with 8 trailing lines.
        var text = "日本 x\r\n"
        for i in 0..<8 { text += "after \(i)\r\n" }
        let snap = try feedAndSnapshot(rig, text)
        XCTAssertGreaterThan(snap.historySize, 0, "wide line must have scrolled into history")

        let captured = captureAll(rig, snap)
        assertAscendingUniqueLines(captured)

        let wideRows = captured.filter { $0.hay.contains("日本") }
        XCTAssertEqual(wideRows.count, 1, "the wide-character line must come back exactly once")
        XCTAssertEqual(wideRows.first?.hay, "日本 x", "wide-character scrollback text must be reconstructed verbatim, trimmed")
        XCTAssertEqual(wideRows.first?.line, -Int32(snap.historySize), "the wide line is the oldest history line")
        XCTAssertNil(wideRows.first?.utf16ToCol, "scrollback rows carry no utf16ToCol map")
        XCTAssertEqual(captured.count, 9, "wide line + 8 follow-up lines, nothing else (cursor row is empty)")
    }

    // MARK: - Soft wrap: one entry per physical row

    func test_softWrappedScrollbackLine_returnsTwoPhysicalRows() throws {
        let rig = try makeRig()
        let head = String(repeating: "A", count: 40)
        let tail = String(repeating: "B", count: 10)
        var text = head + tail + "\r\n"          // 50 chars into 40 cols → 2 physical rows
        for i in 0..<8 { text += "tail \(i)\r\n" }
        let snap = try feedAndSnapshot(rig, text)

        let captured = captureAll(rig, snap)
        assertAscendingUniqueLines(captured)

        let hays = captured.map(\.hay)
        XCTAssertEqual(hays.prefix(2).map { $0 }, [head, tail],
                       "a 50-char line in a 40-col grid must come back as two entries: the 40-A row then the 10-B row")
        XCTAssertFalse(hays.contains(head + tail), "wrapped physical rows must not be joined into one entry")
        if captured.count >= 2 {
            XCTAssertEqual(captured[1].line, captured[0].line + 1, "the two physical rows are consecutive buffer lines")
            XCTAssertNil(captured[0].utf16ToCol)
            XCTAssertNil(captured[1].utf16ToCol)
        }
        XCTAssertEqual(captured.count, 10, "2 wrapped rows + 8 follow-up lines")
    }

    // MARK: - 5000-line scrollback range (chunk boundary)

    /// 5005 short lines → 5000 in history, 5 on the viewport. Requesting
    /// exactly the history range must return 5000 entries, contiguous,
    /// with no gap or duplicate around the 4096 chunk boundary.
    ///
    /// Cost: 5005 × ~7 bytes fed once; 5005 rows × 40 cells ≈ 200 K cells.
    func test_fiveThousandHistoryLines_returnFiveThousandEntries() throws {
        let rig = try makeRig()
        let total = 5005
        var text = ""
        text.reserveCapacity(total * 8)
        for i in 0..<total { text += String(format: "r%04d\r\n", i) }
        let snap = try feedAndSnapshot(rig, text)
        XCTAssertGreaterThanOrEqual(snap.historySize, 5000, "fixture must hold ≥ 5000 history lines")

        let captured = rig.view.findController.captureRows(
            topLine: -5000,
            bottomLine: -1,
            cols: snap.cols,
            session: rig.session,
            snap: snap
        )

        XCTAssertEqual(captured.count, 5000, "a 5000-line history range must yield 5000 non-empty entries")
        assertAscendingUniqueLines(captured)
        XCTAssertFalse(captured.contains { $0.hay.isEmpty }, "no entry may be empty")
        XCTAssertTrue(captured.allSatisfy { $0.utf16ToCol == nil }, "history entries carry no utf16ToCol map")

        // History line -5000 is the oldest retained: r(historySize-5000)
        // when historySize == 5000 exactly, i.e. r0000 … r4999.
        let oldestIndex = snap.historySize - 5000
        for (i, row) in captured.enumerated() {
            let expected = String(format: "r%04d", oldestIndex + i)
            if row.hay != expected {
                XCTFail("entry \(i) (line \(row.line)) is '\(row.hay)', expected '\(expected)' — gap or duplicate in the capture")
                break
            }
        }
        XCTAssertEqual(captured.first?.line, -5000)
        XCTAssertEqual(captured.last?.line, -1)
        // Chunk boundary neighbourhood must be contiguous.
        if captured.count == 5000 {
            XCTAssertEqual(captured[4096].line, captured[4095].line + 1, "no gap across the 4096 chunk boundary")
        }
    }

    // MARK: - Degenerate range

    func test_invertedRange_returnsNothing() throws {
        let rig = try makeRig()
        let snap = try feedAndSnapshot(rig, "hello\r\n")
        let captured = rig.view.findController.captureRows(
            topLine: 3, bottomLine: 1, cols: snap.cols, session: rig.session, snap: snap
        )
        XCTAssertTrue(captured.isEmpty, "bottomLine < topLine must yield no rows")
    }
}
