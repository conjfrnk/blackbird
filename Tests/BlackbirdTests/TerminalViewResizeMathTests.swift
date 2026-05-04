import XCTest
import AppKit
import Metal
@testable import Blackbird

final class TerminalViewResizeMathTests: XCTestCase {

    private func makeView() throws -> TerminalView {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        return TerminalView(
            frame: NSRect(x: 0, y: 0, width: 800, height: 480),
            device: device
        )
    }

    func test_propagateResize_subtractsHorizontalInset() throws {
        let view = try makeView()
        let cw = view.metrics.cellWidth
        let inset = TerminalView.horizontalContentInsetPoints
        view.setFrameSize(NSSize(width: 800.5, height: 480))
        let usableW = 800.5 - 2 * inset
        let expectedCols = Int(usableW / cw)
        let s = try XCTUnwrap(view.lastPropagatedSizeForTesting())
        XCTAssertEqual(Int(s.cols), expectedCols)
    }

    func test_propagateResize_handlesSubCellRightLeftover() throws {
        let view = try makeView()
        let cw = view.metrics.cellWidth
        let inset = TerminalView.horizontalContentInsetPoints
        // Pick a width that lands mid-cell after subtracting the inset:
        // the leftover gets absorbed into the right inset, NOT a partial col.
        let frameWidth = 2 * inset + cw * 30 + 0.5
        view.setFrameSize(NSSize(width: frameWidth, height: 480))
        let s = try XCTUnwrap(view.lastPropagatedSizeForTesting())
        XCTAssertEqual(Int(s.cols), 30,
                       "sub-cell right leftover must be absorbed by the inset")
    }
}
