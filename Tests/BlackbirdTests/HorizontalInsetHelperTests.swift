import XCTest
import AppKit
import Metal
@testable import Blackbird

final class HorizontalInsetHelperTests: XCTestCase {

    private func makeView() throws -> TerminalView {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice(),
                                   "test host needs a Metal device")
        return TerminalView(
            frame: NSRect(x: 0, y: 0, width: 800, height: 480),
            device: device
        )
    }

    func test_horizontalContentInsetPoints_isEightPoints() {
        // Spec contract: 8pt left + 8pt right inset between grid and window edge.
        XCTAssertEqual(TerminalView.horizontalContentInsetPoints, 8)
    }

    func test_cellOriginPx_includesHorizontalInset() throws {
        let view = try makeView()
        let cw = view.metrics.cellWidth
        let origin = view.cellOriginPx(row: 0, col: 0)
        XCTAssertEqual(origin.x, TerminalView.horizontalContentInsetPoints,
                       accuracy: 0.001)
        let origin5 = view.cellOriginPx(row: 0, col: 5)
        XCTAssertEqual(origin5.x,
                       TerminalView.horizontalContentInsetPoints + 5 * cw,
                       accuracy: 0.001)
    }

    func test_cellAt_pointInsideLeftInset_clampsToCol0() throws {
        let view = try makeView()
        let cell = view.cellAt(point: CGPoint(x: 4, y: 100))
        XCTAssertEqual(cell.col, 0)
    }

    func test_cellAt_pointAtInsetBoundary_mapsToCol0() throws {
        let view = try makeView()
        let cell = view.cellAt(point: CGPoint(x: 8, y: 100))
        XCTAssertEqual(cell.col, 0)
    }

    func test_cellAt_pointTwoCellsIn_mapsToCol2() throws {
        let view = try makeView()
        let cw = view.metrics.cellWidth
        let x = TerminalView.horizontalContentInsetPoints + 2 * cw + 1
        let cell = view.cellAt(point: CGPoint(x: x, y: 100))
        XCTAssertEqual(cell.col, 2)
    }

    func test_cellAt_roundTripWithCellOriginPx() throws {
        let view = try makeView()
        let cw = view.metrics.cellWidth
        let origin = view.cellOriginPx(row: 3, col: 7)
        let centre = CGPoint(x: origin.x + cw / 2, y: origin.y + 1)
        let cell = view.cellAt(point: centre)
        XCTAssertEqual(cell.col, 7)
    }
}
