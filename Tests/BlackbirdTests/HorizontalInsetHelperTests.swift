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

    func test_layout_passesLeftInsetToRenderer() throws {
        let view = try makeView()
        view.layoutSubtreeIfNeeded()
        XCTAssertEqual(
            view.renderer.leftInsetPointsForTesting(),
            Float(TerminalView.horizontalContentInsetPoints),
            accuracy: 0.001,
            "TerminalView.layout() must propagate horizontalContentInsetPoints to renderer.setLeftInsetPoints"
        )
    }

    // MARK: - cellAt input hardening (silent-failure-hunter HIGH 1)

    func test_cellAt_nanX_clampsColToZero_doesNotTrap() throws {
        let view = try makeView()
        let cell = view.cellAt(point: CGPoint(x: CGFloat.nan, y: 100))
        // NaN x → safeX = 0 → col 0. row is independent and follows y.
        XCTAssertEqual(cell.col, 0)
    }

    func test_cellAt_infinityX_returnsOriginSentinel() throws {
        let view = try makeView()
        let cell = view.cellAt(point: CGPoint(x: CGFloat.infinity, y: 100))
        // .infinity is non-finite → safeX clamps to 0 → col 0 after the
        // inset subtraction and max(0, …) clamp.
        XCTAssertEqual(cell.col, 0)
    }

    func test_cellAt_negativeInfinityY_returnsOriginSentinel() throws {
        let view = try makeView()
        let cell = view.cellAt(point: CGPoint(x: 100, y: -CGFloat.infinity))
        XCTAssertEqual(cell.row, 0)
    }

    func test_cellAt_absurdlyHugeFiniteX_doesNotTrap() throws {
        let view = try makeView()
        // 1e20 is finite but Int(1e20 / cellWidth) is unrepresentable.
        // The sanePx clamp must absorb this before the divide.
        let cell = view.cellAt(point: CGPoint(x: 1e20, y: 100))
        XCTAssertGreaterThanOrEqual(cell.col, 0)
        XCTAssertLessThanOrEqual(cell.col, 100_000)
    }
}
