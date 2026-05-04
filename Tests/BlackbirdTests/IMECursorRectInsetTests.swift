import XCTest
import AppKit
import Metal
@testable import Blackbird

final class IMECursorRectInsetTests: XCTestCase {

    private func makeView() throws -> TerminalView {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        return TerminalView(
            frame: NSRect(x: 0, y: 0, width: 800, height: 480),
            device: device
        )
    }

    func test_cursorCellRect_includesHorizontalInset_atCol0() throws {
        let view = try makeView()
        view.cursorOverrideForTests = (row: 0, col: 0)
        let rect = view.cursorCellRectInView()
        XCTAssertEqual(rect.minX, TerminalView.horizontalContentInsetPoints,
                       accuracy: 0.001)
    }

    func test_cursorCellRect_includesHorizontalInset_atCol5() throws {
        let view = try makeView()
        view.cursorOverrideForTests = (row: 0, col: 5)
        let cw = view.metrics.cellWidth
        let rect = view.cursorCellRectInView()
        XCTAssertEqual(rect.minX,
                       TerminalView.horizontalContentInsetPoints + 5 * cw,
                       accuracy: 0.001)
    }

    func test_cursorCellRect_widthIsOneCell() throws {
        let view = try makeView()
        view.cursorOverrideForTests = (row: 0, col: 0)
        let rect = view.cursorCellRectInView()
        XCTAssertEqual(rect.width, view.metrics.cellWidth, accuracy: 0.001)
    }
}
