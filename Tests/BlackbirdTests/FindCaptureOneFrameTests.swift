import XCTest
import AppKit
import Metal
@testable import Blackbird
import BBCore

/// `FindController.captureRows` reads scrollback from the live core and
/// viewport rows from the displayed snapshot. The core is routinely ahead of
/// that snapshot, so the two halves must be read as ONE frame: the scrollback
/// shifted onto the snapshot's lines by what the core has scrolled since.
/// Not written blind (the read path was changed in the same commit).
///
/// Fixture: headless 40x6 `TerminalView` + `TerminalSession` (no PTY, no
/// shell), 35 short lines fed; the "core ahead" state is made by feeding the
/// core directly on its queue so no snapshot is published.
final class FindCaptureOneFrameTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        TestHostTermination.shared.register()
    }

    private struct Rig {
        let view: TerminalView
        let session: TerminalSession
        let displayed: BBSnapshot
    }

    private func label(_ n: Int) -> String { String(format: "line %03d", n) }

    private func expectedLabels(_ range: Range<Int>) -> [String] {
        range.map { (n: Int) -> String in label(n) }
    }

    private func makeRig(file: StaticString = #filePath, line: UInt = #line) throws -> Rig {
        let view = try XCTUnwrap(TerminalView.makeHeadlessForTests(), "Metal device required",
                                 file: file, line: line)
        let session = TerminalSession.makeHeadlessForTests()
        session.resize(to: .init(cols: 40, rows: 6))
        view.session = session
        var text = ""
        for i in 0..<30 { text += label(i) + "\r\n" }
        session.feedBytesForTests(Data(text.utf8))
        let displayed = try XCTUnwrap(session.takeSnapshotForTests(), "snapshot", file: file, line: line)
        view.currentSnapshot = displayed
        return Rig(view: view, session: session, displayed: displayed)
    }

    private func feedCoreOnly(_ rig: Rig, lines: Range<Int>) {
        var text = ""
        for i in lines { text += label(i) + "\r\n" }
        rig.session.coreQueue.sync { () -> Void in rig.session.bbterm.input(text) }
    }

    private func capture(_ rig: Rig) -> [(line: Int32, hay: String, utf16ToCol: [Int]?)] {
        rig.view.findController.captureRows(
            topLine: -Int32(rig.displayed.historySize),
            bottomLine: Int32(rig.displayed.rows - 1),
            cols: rig.displayed.cols,
            session: rig.session,
            snap: rig.displayed
        )
    }

    /// Control: core and snapshot agree.
    func test_inSync_scrollbackAndViewportAreOneContinuousRun() throws {
        let rig = try makeRig()
        XCTAssertEqual(capture(rig).map(\.hay), expectedLabels(0..<30))
    }

    /// The core has scrolled 4 lines past the displayed frame: every captured
    /// line must still describe the displayed frame, scrollback included.
    func test_coreScrolledPastDisplayedFrame_scrollbackMatchesTheDisplayedFrame() throws {
        let rig = try makeRig()
        feedCoreOnly(rig, lines: 30..<34)
        let live = try XCTUnwrap(rig.session.coreQueue.sync { () -> BBTerm.GridState? in
            rig.session.bbterm.gridState
        })
        XCTAssertGreaterThan(live.linesScrolled, rig.displayed.linesScrolled,
                             "precondition: the core is ahead of the displayed frame")

        let captured = capture(rig)
        XCTAssertEqual(captured.map(\.hay), expectedLabels(0..<30),
                       "scrollback must be the displayed frame's lines, not the lines the core scrolled into place")
        XCTAssertEqual(captured.map(\.line), captured.map(\.line).sorted(), "ascending lines")
    }

    /// A frame the core has reflowed away from has no scrollback to read; its
    /// viewport rows still come from the snapshot.
    func test_coreResizedSinceDisplayedFrame_dropsScrollbackKeepsViewport() throws {
        let rig = try makeRig()
        rig.session.coreQueue.sync { () -> Void in
            _ = rig.session.bbterm.resize(to: .init(cols: 30, rows: 6))
        }

        let captured = capture(rig)
        XCTAssertEqual(captured.map(\.hay), expectedLabels(25..<30),
                       "only the displayed viewport rows (lines 025-029) survive")
        XCTAssertTrue(captured.allSatisfy { $0.line >= 0 && $0.utf16ToCol != nil })
    }
}
