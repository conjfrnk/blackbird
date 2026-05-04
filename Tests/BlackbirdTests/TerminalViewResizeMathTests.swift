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

    func test_usableViewSize_matchesPropagateResizeFormula() throws {
        let view = try makeView()
        let m = view.metrics
        let bounds = CGSize(width: 1234.0, height: 567.0)
        let titlebar: CGFloat = 28
        let usable = TerminalView.usableViewSize(
            forBounds: bounds,
            titlebarTopInset: titlebar,
            metrics: m
        )
        XCTAssertEqual(usable.width,
                       1234.0 - 2 * TerminalView.horizontalContentInsetPoints,
                       accuracy: 0.001)
        XCTAssertEqual(usable.height,
                       567.0 - titlebar - TerminalView.bottomContentInsetPoints,
                       accuracy: 0.001)
    }

    func test_usableViewSize_clampsToOneCellMinimum() throws {
        let view = try makeView()
        let m = view.metrics
        // Tiny bounds — usableWidth/Height must clamp to one cell, not go
        // negative. propagateResize relies on this floor so the
        // grid(forPixelSize:) call always returns ≥ 1×1.
        let usable = TerminalView.usableViewSize(
            forBounds: CGSize(width: 1, height: 1),
            titlebarTopInset: 28,
            metrics: m
        )
        XCTAssertEqual(usable.width, m.cellWidth, accuracy: 0.001)
        XCTAssertEqual(usable.height, m.cellHeight, accuracy: 0.001)
    }
}
