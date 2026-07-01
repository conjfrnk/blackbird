import XCTest
import AppKit
@testable import Blackbird

/// Pure-geometry coverage for `WindowResizeController.resizedFrame`.
///
/// AppKit coordinate space: Y points UP, so a frame's `origin` is its
/// BOTTOM-LEFT corner. `maxY` is the top edge, `maxX` the right edge.
/// These tests exercise the per-corner transform and the min-size clamp
/// with no windows/views — every expected value is hand-computed from
/// the contract.
final class WindowResizeControllerTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        TestHostTermination.shared.register()
    }

    // MARK: - Fixtures

    /// Generous start frame; bottom-left at (100,100), top-right at (900,700).
    private let startFrame = NSRect(x: 100, y: 100, width: 800, height: 600)

    /// `start` + (dx, dy) global mouse points.
    private func mouse(dx: CGFloat, dy: CGFloat) -> (start: CGPoint, current: CGPoint) {
        let start = CGPoint(x: 500, y: 500)
        return (start, CGPoint(x: start.x + dx, y: start.y + dy))
    }

    private func assertRect(
        _ got: NSRect,
        x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat,
        accuracy: CGFloat = 1e-9,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertEqual(got.origin.x, x, accuracy: accuracy, "origin.x", file: file, line: line)
        XCTAssertEqual(got.origin.y, y, accuracy: accuracy, "origin.y", file: file, line: line)
        XCTAssertEqual(got.size.width, width, accuracy: accuracy, "width", file: file, line: line)
        XCTAssertEqual(got.size.height, height, accuracy: accuracy, "height", file: file, line: line)
    }

    private func assertPointEqual(
        _ got: CGPoint, _ want: CGPoint,
        accuracy: CGFloat = 1e-9,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertEqual(got.x, want.x, accuracy: accuracy, "x", file: file, line: line)
        XCTAssertEqual(got.y, want.y, accuracy: accuracy, "y", file: file, line: line)
    }

    // MARK: - 1. Each corner, no clamping (dx = +30, dy = +20)

    func test_topLeft_noClamp_appliesTransform() {
        let (s, c) = mouse(dx: 30, dy: 20)
        let f = WindowResizeController.resizedFrame(
            corner: .topLeft,
            startMouseGlobal: s, startFrame: startFrame, currentMouseGlobal: c,
            minWidth: 50, minHeight: 50)
        // origin.x += dx -> 130; width -= dx -> 770; height += dy -> 620; origin.y unchanged.
        assertRect(f, x: 130, y: 100, width: 770, height: 620)
    }

    func test_topRight_noClamp_appliesTransform() {
        let (s, c) = mouse(dx: 30, dy: 20)
        let f = WindowResizeController.resizedFrame(
            corner: .topRight,
            startMouseGlobal: s, startFrame: startFrame, currentMouseGlobal: c,
            minWidth: 50, minHeight: 50)
        // width += dx -> 830; height += dy -> 620; origin unchanged.
        assertRect(f, x: 100, y: 100, width: 830, height: 620)
    }

    func test_bottomLeft_noClamp_appliesTransform() {
        let (s, c) = mouse(dx: 30, dy: 20)
        let f = WindowResizeController.resizedFrame(
            corner: .bottomLeft,
            startMouseGlobal: s, startFrame: startFrame, currentMouseGlobal: c,
            minWidth: 50, minHeight: 50)
        // origin.x += dx -> 130; width -= dx -> 770; origin.y += dy -> 120; height -= dy -> 580.
        assertRect(f, x: 130, y: 120, width: 770, height: 580)
    }

    func test_bottomRight_noClamp_appliesTransform() {
        let (s, c) = mouse(dx: 30, dy: 20)
        let f = WindowResizeController.resizedFrame(
            corner: .bottomRight,
            startMouseGlobal: s, startFrame: startFrame, currentMouseGlobal: c,
            minWidth: 50, minHeight: 50)
        // width += dx -> 830; origin.y += dy -> 120; height -= dy -> 580; origin.x unchanged.
        assertRect(f, x: 100, y: 120, width: 830, height: 580)
    }

    // MARK: - 2. Opposite corner stays pinned (no-clamp deltas)

    func test_topLeft_pinsBottomRightPoint() {
        let (s, c) = mouse(dx: 30, dy: 20)
        let f = WindowResizeController.resizedFrame(
            corner: .topLeft,
            startMouseGlobal: s, startFrame: startFrame, currentMouseGlobal: c,
            minWidth: 50, minHeight: 50)
        // Bottom-right = (maxX, minY) must equal the start frame's.
        assertPointEqual(CGPoint(x: f.maxX, y: f.minY),
                         CGPoint(x: startFrame.maxX, y: startFrame.minY))
    }

    func test_topRight_pinsBottomLeftPoint() {
        let (s, c) = mouse(dx: 30, dy: 20)
        let f = WindowResizeController.resizedFrame(
            corner: .topRight,
            startMouseGlobal: s, startFrame: startFrame, currentMouseGlobal: c,
            minWidth: 50, minHeight: 50)
        // Bottom-left = (minX, minY) must equal the start frame's origin.
        assertPointEqual(CGPoint(x: f.minX, y: f.minY),
                         CGPoint(x: startFrame.minX, y: startFrame.minY))
    }

    func test_bottomLeft_pinsTopRightPoint() {
        let (s, c) = mouse(dx: 30, dy: 20)
        let f = WindowResizeController.resizedFrame(
            corner: .bottomLeft,
            startMouseGlobal: s, startFrame: startFrame, currentMouseGlobal: c,
            minWidth: 50, minHeight: 50)
        // Top-right = (maxX, maxY) must equal the start frame's.
        assertPointEqual(CGPoint(x: f.maxX, y: f.maxY),
                         CGPoint(x: startFrame.maxX, y: startFrame.maxY))
    }

    func test_bottomRight_pinsTopLeftPoint() {
        let (s, c) = mouse(dx: 30, dy: 20)
        let f = WindowResizeController.resizedFrame(
            corner: .bottomRight,
            startMouseGlobal: s, startFrame: startFrame, currentMouseGlobal: c,
            minWidth: 50, minHeight: 50)
        // Top-left = (minX, maxY) must equal the start frame's.
        assertPointEqual(CGPoint(x: f.minX, y: f.maxY),
                         CGPoint(x: startFrame.minX, y: startFrame.maxY))
    }

    // MARK: - 3. Width clamp pins the correct horizontal edge

    func test_leftCorner_widthUnderflow_pinsRightEdge() {
        // .bottomLeft dragged far right: width -= dx -> 800 - 750 = 50 < 100.
        // Left corner clamp: origin.x = maxX - minWidth; width = minWidth.
        let (s, c) = mouse(dx: 750, dy: 0)
        let f = WindowResizeController.resizedFrame(
            corner: .bottomLeft,
            startMouseGlobal: s, startFrame: startFrame, currentMouseGlobal: c,
            minWidth: 100, minHeight: 50)
        XCTAssertEqual(f.size.width, 100, accuracy: 1e-9)
        XCTAssertEqual(f.origin.x, startFrame.maxX - 100, accuracy: 1e-9,
                       "left-corner width clamp must pin the right edge")
    }

    func test_rightCorner_widthUnderflow_doesNotMoveOriginX() {
        // .bottomRight dragged far left: width += dx -> 800 - 760 = 40 < 100.
        // Right corner: width clamps to minWidth but origin.x is untouched.
        let (s, c) = mouse(dx: -760, dy: 0)
        let f = WindowResizeController.resizedFrame(
            corner: .bottomRight,
            startMouseGlobal: s, startFrame: startFrame, currentMouseGlobal: c,
            minWidth: 100, minHeight: 50)
        XCTAssertEqual(f.size.width, 100, accuracy: 1e-9)
        XCTAssertEqual(f.origin.x, startFrame.origin.x, accuracy: 1e-9,
                       "right-corner width clamp must leave origin.x (left edge) fixed")
    }

    // MARK: - 4. Height clamp pins the correct vertical edge

    func test_bottomCorner_heightUnderflow_pinsTopEdge() {
        // .bottomRight dragged far up: height -= dy -> 600 - 550 = 50 < 100.
        // Bottom corner clamp: origin.y = maxY - minHeight; height = minHeight.
        let (s, c) = mouse(dx: 0, dy: 550)
        let f = WindowResizeController.resizedFrame(
            corner: .bottomRight,
            startMouseGlobal: s, startFrame: startFrame, currentMouseGlobal: c,
            minWidth: 50, minHeight: 100)
        XCTAssertEqual(f.size.height, 100, accuracy: 1e-9)
        XCTAssertEqual(f.origin.y, startFrame.maxY - 100, accuracy: 1e-9,
                       "bottom-corner height clamp must pin the top edge")
    }

    func test_topCorner_heightUnderflow_doesNotMoveOriginY() {
        // .topRight dragged far down: height += dy -> 600 - 560 = 40 < 100.
        // Top corner: height clamps to minHeight but origin.y is untouched.
        let (s, c) = mouse(dx: 0, dy: -560)
        let f = WindowResizeController.resizedFrame(
            corner: .topRight,
            startMouseGlobal: s, startFrame: startFrame, currentMouseGlobal: c,
            minWidth: 50, minHeight: 100)
        XCTAssertEqual(f.size.height, 100, accuracy: 1e-9)
        XCTAssertEqual(f.origin.y, startFrame.origin.y, accuracy: 1e-9,
                       "top-corner height clamp must leave origin.y (bottom edge) fixed")
    }

    // MARK: - 5. Zero delta is a no-op

    func test_zeroDelta_returnsStartFrame() {
        let s = CGPoint(x: 500, y: 500)
        for corner in [WindowResizeController.Corner.topLeft, .topRight, .bottomLeft, .bottomRight] {
            let f = WindowResizeController.resizedFrame(
                corner: corner,
                startMouseGlobal: s, startFrame: startFrame, currentMouseGlobal: s,
                minWidth: 50, minHeight: 50)
            assertRect(f, x: startFrame.origin.x, y: startFrame.origin.y,
                       width: startFrame.size.width, height: startFrame.size.height)
        }
    }
}
