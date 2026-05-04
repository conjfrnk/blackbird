import XCTest
import AppKit
import Metal
@testable import Blackbird

final class MouseInsetMappingTests: XCTestCase {

    private func makeView() throws -> TerminalView {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        return TerminalView(
            frame: NSRect(x: 0, y: 0, width: 800, height: 480),
            device: device
        )
    }

    func test_clickInsideLeftInset_mapsToCol0() throws {
        let view = try makeView()
        let bp = bufferPoint(
            forView: CGPoint(x: 4, y: 100), // x=4 < 8pt inset
            cellWidth: view.metrics.cellWidth,
            cellHeight: view.metrics.cellHeight,
            viewportHeight: 400,
            displayOffset: 0,
            cols: 80, rows: 24,
            historySize: 0,
            leftInsetPoints: TerminalView.horizontalContentInsetPoints
        )
        XCTAssertEqual(bp.col, 0)
    }

    func test_clickAtInsetBoundary_mapsToCol0() throws {
        let view = try makeView()
        let bp = bufferPoint(
            forView: CGPoint(x: 8, y: 100),
            cellWidth: view.metrics.cellWidth,
            cellHeight: view.metrics.cellHeight,
            viewportHeight: 400,
            displayOffset: 0,
            cols: 80, rows: 24,
            historySize: 0,
            leftInsetPoints: TerminalView.horizontalContentInsetPoints
        )
        XCTAssertEqual(bp.col, 0)
    }

    func test_clickTwoCellsRightOfInset_mapsToCol2() throws {
        let view = try makeView()
        let cw = view.metrics.cellWidth
        let x = TerminalView.horizontalContentInsetPoints + 2 * cw + 1
        let bp = bufferPoint(
            forView: CGPoint(x: x, y: 100),
            cellWidth: cw,
            cellHeight: view.metrics.cellHeight,
            viewportHeight: 400,
            displayOffset: 0,
            cols: 80, rows: 24,
            historySize: 0,
            leftInsetPoints: TerminalView.horizontalContentInsetPoints
        )
        XCTAssertEqual(bp.col, 2)
    }
}
