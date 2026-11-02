import XCTest
import AppKit
import Metal
@testable import Blackbird
import BBCore

/// Find-bar match columns for rows that contain TABs.
///
/// Scrollback haystacks come from `session.textRange` and `FindController`
/// reads a string offset as the grid column (`startCol = offset`), so the
/// haystack must hold one character per grid cell: a tab's blank fill has to
/// survive, even though copy paths collapse `\t` + fill to the lone `\t`.
/// Viewport rows go through the snapshot's exact UTF-16 -> column map and are
/// the oracle: the same text must report the same columns whether the row is
/// on screen or has scrolled into history.
///
/// Grid cells for `a<TAB>foo`: `a`@0, tab@1 (fill 2-7), `foo`@8-10.
/// `b<TAB>c<TAB>foo`: `b`@0, tab@1, `c`@8, tab@9, `foo`@16-18.
///
/// Fixture: headless `TerminalView` + `TerminalSession` (no PTY, no shell),
/// 60x8 grid, 14 short lines fed synchronously. A few KB.
final class FindTabScrollbackColumnTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        TestHostTermination.shared.register()
    }

    private struct Rig {
        let view: TerminalView
        let session: TerminalSession
    }

    private typealias Row = (line: Int32, hay: String, utf16ToCol: [Int]?)

    private func makeRig(file: StaticString = #filePath, line: UInt = #line) throws -> Rig {
        let view = try XCTUnwrap(TerminalView.makeHeadlessForTests(), "Metal device required", file: file, line: line)
        let session = TerminalSession.makeHeadlessForTests()
        session.resize(to: .init(cols: 60, rows: 8))
        view.session = session
        view.findController.installFindBar()
        return Rig(view: view, session: session)
    }

    @discardableResult
    private func feed(_ rig: Rig, _ text: String,
                      file: StaticString = #filePath, line: UInt = #line) throws -> BBSnapshot {
        rig.session.feedBytesForTests(Data(text.utf8))
        let snap = try XCTUnwrap(rig.session.takeSnapshotForTests(), "snapshot must be available", file: file, line: line)
        rig.view.currentSnapshot = snap
        return snap
    }

    private func captureNow(_ rig: Rig) throws -> [Row] {
        let snap = try XCTUnwrap(rig.view.currentSnapshot)
        return rig.view.findController.captureRows(
            topLine: -Int32(clamping: snap.historySize),
            bottomLine: Int32(clamping: snap.rows - 1),
            cols: snap.cols,
            session: rig.session,
            snap: snap
        )
    }

    private let filler = String(repeating: "filler\r\n", count: 12)

    /// A tab row that has scrolled into history keeps one haystack char per
    /// cell, so `foo` is found at its real columns 8-10.
    func test_scrollbackRowWithOneTab_matchUsesGridColumns() throws {
        let rig = try makeRig()
        let snap = try feed(rig, "a\tfoo\r\n" + filler)
        XCTAssertGreaterThanOrEqual(snap.historySize, 6, "fixture: the tab row must be in scrollback")

        let rows = try captureNow(rig)
        let tabRow = try XCTUnwrap(rows.first { $0.hay.hasPrefix("a\t") }, "tab row must be captured")
        XCTAssertLessThan(tabRow.line, 0, "fixture: the tab row must be a scrollback row")
        XCTAssertNil(tabRow.utf16ToCol, "scrollback rows carry no column map")
        XCTAssertEqual(tabRow.hay, "a\t      foo", "the tab's six blank fill cells must stay in the haystack")

        rig.view.findController.performSearch(query: "foo")
        let matches = rig.view.findController.findMatches
        XCTAssertEqual(matches.count, 1, "exactly one row contains foo")
        let m = try XCTUnwrap(matches.first)
        XCTAssertEqual(m.line, tabRow.line)
        XCTAssertEqual(m.startCol, 8, "foo starts at grid column 8, not at string offset 2")
        XCTAssertEqual(m.endCol, 10)
    }

    /// Two tabs before the match: the error used to grow with every tab.
    /// The scrollback row and the identical on-screen row must agree.
    func test_scrollbackAndViewportTabRows_reportTheSameColumns() throws {
        let rig = try makeRig()
        try feed(rig, "b\tc\tfoo\r\n" + filler + "b\tc\tfoo")
        let snap = try XCTUnwrap(rig.view.currentSnapshot)
        XCTAssertGreaterThanOrEqual(snap.historySize, 6, "fixture: the first tab row must be in scrollback")

        rig.view.findController.performSearch(query: "foo")
        let matches = rig.view.findController.findMatches
        XCTAssertEqual(matches.count, 2, "one hit in scrollback, one in the viewport")
        XCTAssertLessThan(matches[0].line, 0, "first hit is the scrollback row")
        XCTAssertGreaterThanOrEqual(matches[1].line, 0, "second hit is the viewport row")
        for m in matches {
            XCTAssertEqual(m.startCol, 16, "foo starts at grid column 16 on line \(m.line)")
            XCTAssertEqual(m.endCol, 18, "foo ends at grid column 18 on line \(m.line)")
        }
    }
}
