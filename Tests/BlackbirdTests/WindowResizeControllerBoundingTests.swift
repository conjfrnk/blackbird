import XCTest
import AppKit
@testable import Blackbird

/// Coverage for the NEW `boundingFrame` parameter on
/// `WindowResizeController.resizedFrame` / `frameForCurrentDrag`.
///
/// AppKit coordinate space: Y points UP, so a frame's `origin` is its
/// BOTTOM-LEFT corner; `maxY` is the top edge, `maxX` the right edge.
///
/// Contract under test (per revised spec), applied in this order after
/// the existing per-corner transform:
///   1. per-corner transform (unchanged — see WindowResizeControllerTests)
///   2. bounding clamp — only the DRAGGED edges of the corner are pulled
///      back inside `boundingFrame`, and ONLY when the bound leaves at
///      least the minimum size measured from the ANCHORED edge. If it
///      cannot fit the minimum, that axis is left UNCLAMPED (raw
///      transform value). Anchored edges are never moved.
///   3. min-size clamp — runs LAST and WINS; its edge-pinning uses
///      `startFrame` exactly as today.
///
/// Dragged edges by corner:
///   topLeft     -> {left,  top}
///   topRight    -> {right, top}
///   bottomLeft  -> {left,  bottom}
///   bottomRight -> {right, bottom}
///
/// Edge clamp — each fires iff the frame exceeds the bound on that edge
/// AND the "room" from the anchored edge is >= the minimum:
///   left   : minX < bound.minX AND (startFrame.maxX - bound.minX) >= minWidth
///            -> width -= (bound.minX - minX); origin.x = bound.minX   (maxX preserved)
///   right  : maxX > bound.maxX AND (bound.maxX - startFrame.minX) >= minWidth
///            -> width  = bound.maxX - origin.x                        (origin.x preserved)
///   top    : maxY > bound.maxY AND (bound.maxY - startFrame.minY) >= minHeight
///            -> height = bound.maxY - origin.y                        (origin.y preserved)
///   bottom : minY < bound.minY AND (startFrame.maxY - bound.minY) >= minHeight
///            -> height -= (bound.minY - minY); origin.y = bound.minY  (maxY preserved)
///
/// Every expected rect below is hand-computed in the comments.
final class WindowResizeControllerBoundingTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        TestHostTermination.shared.register()
    }

    // MARK: - Fixtures (match WindowResizeControllerTests)

    /// Bottom-left at (100,100), top-right at (900,700).
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

    // MARK: - 1. nil bounding == existing math (spot-check one corner)

    func test_nilBounding_matchesExistingMath_topLeft() {
        let (s, c) = mouse(dx: 30, dy: 20)
        // topLeft: origin.x += 30 -> 130; width -= 30 -> 770; height += 20 -> 620; origin.y unchanged.
        let explicitNil = WindowResizeController.resizedFrame(
            corner: .topLeft,
            startMouseGlobal: s, startFrame: startFrame, currentMouseGlobal: c,
            minWidth: 50, minHeight: 50, boundingFrame: nil)
        assertRect(explicitNil, x: 130, y: 100, width: 770, height: 620)

        // Default argument (parameter omitted) must behave identically.
        let defaulted = WindowResizeController.resizedFrame(
            corner: .topLeft,
            startMouseGlobal: s, startFrame: startFrame, currentMouseGlobal: c,
            minWidth: 50, minHeight: 50)
        XCTAssertEqual(defaulted, explicitNil)
    }

    // MARK: - 2. Roomy bound == nil bound (no edge exceeds the bound)

    func test_roomyBounding_identicalToNil_topLeft() {
        let (s, c) = mouse(dx: 30, dy: 20)
        // Same transform as above: frame (130,100,770,620) -> minX 130, maxX 900, minY 100, maxY 720.
        let nilResult = WindowResizeController.resizedFrame(
            corner: .topLeft,
            startMouseGlobal: s, startFrame: startFrame, currentMouseGlobal: c,
            minWidth: 50, minHeight: 50, boundingFrame: nil)
        // Bound engulfs the frame entirely -> neither dragged edge exceeds it -> no clamp.
        let roomy = NSRect(x: -1000, y: -1000, width: 4000, height: 4000)
        let bounded = WindowResizeController.resizedFrame(
            corner: .topLeft,
            startMouseGlobal: s, startFrame: startFrame, currentMouseGlobal: c,
            minWidth: 50, minHeight: 50, boundingFrame: roomy)
        assertRect(bounded, x: 130, y: 100, width: 770, height: 620)
        XCTAssertEqual(bounded, nilResult)
    }

    // MARK: - 3. Each corner overshoots BOTH dragged edges -> both clamp
    //            (each precondition leaves far more than min room from the anchor)

    func test_topLeft_overshootsBothDraggedEdges_clampsLeftAndTop() {
        // dx = -60 (drag left), dy = +90 (drag up).
        let (s, c) = mouse(dx: -60, dy: 90)
        // Transform: origin.x = 100-60 = 40; width = 800+60 = 860 (maxX 900);
        //            height = 600+90 = 690; origin.y = 100 (maxY 790).
        // Bound: minX 70, minY 50, maxX 970, maxY 680.
        let bound = NSRect(x: 70, y: 50, width: 900, height: 630)
        // left precondition: startFrame.maxX - bound.minX = 900 - 70 = 830 >= 50 -> applies.
        //   minX 40 < 70 -> width -= 30 -> 830; origin.x = 70 (maxX 900).
        // top  precondition: bound.maxY - startFrame.minY = 680 - 100 = 580 >= 50 -> applies.
        //   maxY 790 > 680 -> height = 680 - 100 = 580; origin.y = 100 (maxY 680).
        // right/bottom anchored: maxX 900 < 970; minY 100 > 50.
        let f = WindowResizeController.resizedFrame(
            corner: .topLeft,
            startMouseGlobal: s, startFrame: startFrame, currentMouseGlobal: c,
            minWidth: 50, minHeight: 50, boundingFrame: bound)
        assertRect(f, x: 70, y: 100, width: 830, height: 580)
    }

    func test_topRight_overshootsBothDraggedEdges_clampsRightAndTop() {
        // dx = +120 (drag right), dy = +90 (drag up).
        let (s, c) = mouse(dx: 120, dy: 90)
        // Transform: width = 800+120 = 920 (maxX 1020); height = 600+90 = 690 (maxY 790);
        //            origin unchanged (100,100).
        // Bound: minX 0, minY 0, maxX 950, maxY 680.
        let bound = NSRect(x: 0, y: 0, width: 950, height: 680)
        // right precondition: bound.maxX - startFrame.minX = 950 - 100 = 850 >= 50 -> applies.
        //   maxX 1020 > 950 -> width = 950 - 100 = 850; origin.x = 100 (maxX 950).
        // top   precondition: bound.maxY - startFrame.minY = 680 - 100 = 580 >= 50 -> applies.
        //   maxY 790 > 680 -> height = 680 - 100 = 580; origin.y = 100 (maxY 680).
        // left/bottom anchored: minX 100 > 0; minY 100 > 0.
        let f = WindowResizeController.resizedFrame(
            corner: .topRight,
            startMouseGlobal: s, startFrame: startFrame, currentMouseGlobal: c,
            minWidth: 50, minHeight: 50, boundingFrame: bound)
        assertRect(f, x: 100, y: 100, width: 850, height: 580)
    }

    func test_bottomLeft_overshootsBothDraggedEdges_clampsLeftAndBottom() {
        // dx = -70 (drag left), dy = -60 (drag down).
        let (s, c) = mouse(dx: -70, dy: -60)
        // Transform: origin.x = 100-70 = 30; width = 800+70 = 870 (maxX 900);
        //            origin.y = 100-60 = 40; height = 600+60 = 660 (maxY 700).
        // Bound: minX 80, minY 70, maxX 1080, maxY 1070.
        let bound = NSRect(x: 80, y: 70, width: 1000, height: 1000)
        // left   precondition: startFrame.maxX - bound.minX = 900 - 80 = 820 >= 50 -> applies.
        //   minX 30 < 80 -> width -= 50 -> 820; origin.x = 80 (maxX 900).
        // bottom precondition: startFrame.maxY - bound.minY = 700 - 70 = 630 >= 50 -> applies.
        //   minY 40 < 70 -> height -= 30 -> 630; origin.y = 70 (maxY 700).
        // right/top anchored: maxX 900 < 1080; maxY 700 < 1070.
        let f = WindowResizeController.resizedFrame(
            corner: .bottomLeft,
            startMouseGlobal: s, startFrame: startFrame, currentMouseGlobal: c,
            minWidth: 50, minHeight: 50, boundingFrame: bound)
        assertRect(f, x: 80, y: 70, width: 820, height: 630)
    }

    func test_bottomRight_overshootsBothDraggedEdges_clampsRightAndBottom() {
        // dx = +130 (drag right), dy = -80 (drag down).
        let (s, c) = mouse(dx: 130, dy: -80)
        // Transform: width = 800+130 = 930 (maxX 1030); origin.y = 100-80 = 20;
        //            height = 600+80 = 680 (maxY 700); origin.x = 100.
        // Bound: minX 0, minY 60, maxX 960, maxY 1060.
        let bound = NSRect(x: 0, y: 60, width: 960, height: 1000)
        // right  precondition: bound.maxX - startFrame.minX = 960 - 100 = 860 >= 50 -> applies.
        //   maxX 1030 > 960 -> width = 960 - 100 = 860; origin.x = 100 (maxX 960).
        // bottom precondition: startFrame.maxY - bound.minY = 700 - 60 = 640 >= 50 -> applies.
        //   minY 20 < 60 -> height -= 40 -> 640; origin.y = 60 (maxY 700).
        // left/top anchored: minX 100 > 0; maxY 700 < 1060.
        let f = WindowResizeController.resizedFrame(
            corner: .bottomRight,
            startMouseGlobal: s, startFrame: startFrame, currentMouseGlobal: c,
            minWidth: 50, minHeight: 50, boundingFrame: bound)
        assertRect(f, x: 100, y: 60, width: 860, height: 640)
    }

    // MARK: - 4. Anchored overhang preserved while dragged edges clamp
    //            (dragged-edge preconditions still leave >= min room from the anchor)

    func test_bottomRight_anchoredLeftOverhang_preservedWhileDraggedEdgesClamp() {
        // bottomRight drags {right, bottom}; anchored = {left(minX), top(maxY)}.
        // startFrame.minX = 100 lies LEFT of bound.minX = 150 -> anchored left edge
        // is already out of bounds and must stay at 100.
        // dx = +130 (right overshoot), dy = -70 (bottom overshoot).
        let (s, c) = mouse(dx: 130, dy: -70)
        // Transform: width = 800+130 = 930 (maxX 1030); origin.y = 100-70 = 30;
        //            height = 600+70 = 670 (maxY 700); origin.x = 100.
        // Bound: minX 150, minY 60, maxX 850, maxY 1000.
        let bound = NSRect(x: 150, y: 60, width: 700, height: 940)
        // right  precondition: bound.maxX - startFrame.minX = 850 - 100 = 750 >= 50 -> applies.
        //   maxX 1030 > 850 -> width = 850 - 100 = 750; origin.x stays 100 (maxX 850).
        // bottom precondition: startFrame.maxY - bound.minY = 700 - 60 = 640 >= 50 -> applies.
        //   minY 30 < 60 -> height -= 30 -> 640; origin.y = 60 (maxY 700).
        // anchored left origin.x = 100 stays even though 100 < bound.minX 150.
        let f = WindowResizeController.resizedFrame(
            corner: .bottomRight,
            startMouseGlobal: s, startFrame: startFrame, currentMouseGlobal: c,
            minWidth: 50, minHeight: 50, boundingFrame: bound)
        XCTAssertEqual(f.origin.x, 100, accuracy: 1e-9,
                       "anchored left edge overhang must be preserved (not pulled to bound.minX)")
        assertRect(f, x: 100, y: 60, width: 750, height: 640)
    }

    func test_topLeft_anchoredBottomOverhang_preservedWhileDraggedEdgesClamp() {
        // topLeft drags {left, top}; anchored = {right(maxX), bottom(minY)}.
        // startFrame.minY = 100 lies BELOW bound.minY = 150 -> anchored bottom edge
        // is already out of bounds and must stay at 100.
        // dx = -60 (left overshoot), dy = +90 (top overshoot).
        let (s, c) = mouse(dx: -60, dy: 90)
        // Transform: origin.x = 100-60 = 40; width = 800+60 = 860 (maxX 900);
        //            height = 600+90 = 690 (maxY 790); origin.y = 100.
        // Bound: minX 70, minY 150, maxX 1000, maxY 680.
        let bound = NSRect(x: 70, y: 150, width: 930, height: 530)
        // left precondition: startFrame.maxX - bound.minX = 900 - 70 = 830 >= 50 -> applies.
        //   minX 40 < 70 -> width -= 30 -> 830; origin.x = 70 (maxX 900).
        // top  precondition: bound.maxY - startFrame.minY = 680 - 100 = 580 >= 50 -> applies.
        //   maxY 790 > 680 -> height = 680 - 100 = 580; origin.y stays 100 (maxY 680).
        // anchored bottom origin.y = 100 stays even though 100 < bound.minY 150.
        let f = WindowResizeController.resizedFrame(
            corner: .topLeft,
            startMouseGlobal: s, startFrame: startFrame, currentMouseGlobal: c,
            minWidth: 50, minHeight: 50, boundingFrame: bound)
        XCTAssertEqual(f.origin.y, 100, accuracy: 1e-9,
                       "anchored bottom edge overhang must be preserved (not pulled to bound.minY)")
        assertRect(f, x: 70, y: 100, width: 830, height: 580)
    }

    // MARK: - 5. Bound skipped when it cannot fit the minimum from the anchored edge
    //            (revised rule: too-tight axis is left at the RAW transform value)

    func test_bottomLeft_boundTooTightForMinWidth_leftAxisSkipped() {
        // bottomLeft (LEFT corner). bound.minX = 850 leaves only 900 - 850 = 50 of
        // room from the anchored right edge (startFrame.maxX = 900), but minWidth = 100.
        // 50 >= 100 is FALSE -> left-axis clamp is SKIPPED, keeping the raw width.
        // dx = -100 (drag left hard), dy = 0.
        let (s, c) = mouse(dx: -100, dy: 0)
        // Raw transform: origin.x = 100-100 = 0; width = 800+100 = 900 (maxX 900);
        //                origin.y = 100; height = 600 (maxY 700).
        // Bound: minX 850, minY 0, maxX 1050, maxY 1000.
        let bound = NSRect(x: 850, y: 0, width: 200, height: 1000)
        // left  precondition FAILS (50 < 100) -> unclamped: origin.x stays 0, width stays 900.
        // bottom: minY 100 < bound.minY 0? No -> no bottom clamp.
        // min-size clamp: width 900 >= 100 and height 600 >= 50 -> no change.
        // Result is the RAW corner transform: (0,100,900,600).
        let f = WindowResizeController.resizedFrame(
            corner: .bottomLeft,
            startMouseGlobal: s, startFrame: startFrame, currentMouseGlobal: c,
            minWidth: 100, minHeight: 50, boundingFrame: bound)
        assertRect(f, x: 0, y: 100, width: 900, height: 600)
    }

    func test_bottomRight_boundTooTightForMinHeight_bottomAxisSkipped() {
        // bottomRight (BOTTOM corner). bound.minY = 650 leaves only 700 - 650 = 50 of
        // room from the anchored top edge (startFrame.maxY = 700), but minHeight = 100.
        // 50 >= 100 is FALSE -> bottom-axis clamp is SKIPPED, keeping the raw height.
        // dx = 0, dy = -100 (drag down hard).
        let (s, c) = mouse(dx: 0, dy: -100)
        // Raw transform: width = 800 (maxX 900); origin.y = 100-100 = 0;
        //                height = 600+100 = 700 (maxY 700); origin.x = 100.
        // Bound: minX 0, minY 650, maxX 1000, maxY 1650.
        let bound = NSRect(x: 0, y: 650, width: 1000, height: 1000)
        // bottom precondition FAILS (50 < 100) -> unclamped: origin.y stays 0, height stays 700.
        // right: maxX 900 > bound.maxX 1000? No -> no right clamp.
        // min-size clamp: width 800 >= 50 and height 700 >= 100 -> no change.
        // Result is the RAW corner transform: (100,0,800,700).
        let f = WindowResizeController.resizedFrame(
            corner: .bottomRight,
            startMouseGlobal: s, startFrame: startFrame, currentMouseGlobal: c,
            minWidth: 50, minHeight: 100, boundingFrame: bound)
        assertRect(f, x: 100, y: 0, width: 800, height: 700)
    }

    // MARK: - 6. Boundary: bound leaves EXACTLY min room from the anchor (>= is inclusive)
    //            -> clamp applies and the axis lands on exactly the minimum.

    func test_bottomLeft_boundLeavesExactlyMinWidth_clampsToMinWidth() {
        // bottomLeft (LEFT corner). bound.minX = 800 leaves 900 - 800 = 100 of room
        // from the anchored right edge; minWidth = 100 -> precondition 100 >= 100 (inclusive).
        // dx = -100 (drag left hard), dy = 0.
        let (s, c) = mouse(dx: -100, dy: 0)
        // Raw transform: origin.x = 0; width = 900 (maxX 900); origin.y = 100; height = 600.
        // Bound: minX 800, minY 0, maxX 1100, maxY 1000.
        let bound = NSRect(x: 800, y: 0, width: 300, height: 1000)
        // left precondition: 900 - 800 = 100 >= 100 -> APPLIES.
        //   minX 0 < 800 -> width -= 800 -> 100; origin.x = 800 (maxX 900).
        // bottom: minY 100 < 0? No.
        // min-size: width 100 < 100? No (equal) -> unchanged; height 600 >= 50.
        // Result: (800,100,100,600) with width EXACTLY minWidth.
        let f = WindowResizeController.resizedFrame(
            corner: .bottomLeft,
            startMouseGlobal: s, startFrame: startFrame, currentMouseGlobal: c,
            minWidth: 100, minHeight: 50, boundingFrame: bound)
        XCTAssertEqual(f.size.width, 100, accuracy: 1e-9,
                       "exactly-min room is inclusive: clamp applies and width == minWidth")
        assertRect(f, x: 800, y: 100, width: 100, height: 600)
    }

    func test_bottomRight_boundLeavesExactlyMinHeight_clampsToMinHeight() {
        // bottomRight (BOTTOM corner). bound.minY = 600 leaves 700 - 600 = 100 of room
        // from the anchored top edge; minHeight = 100 -> precondition 100 >= 100 (inclusive).
        // dx = 0, dy = -100 (drag down hard).
        let (s, c) = mouse(dx: 0, dy: -100)
        // Raw transform: width = 800 (maxX 900); origin.y = 0; height = 700 (maxY 700); origin.x = 100.
        // Bound: minX 0, minY 600, maxX 1000, maxY 1600.
        let bound = NSRect(x: 0, y: 600, width: 1000, height: 1000)
        // bottom precondition: 700 - 600 = 100 >= 100 -> APPLIES.
        //   minY 0 < 600 -> height -= 600 -> 100; origin.y = 600 (maxY 700).
        // right: maxX 900 > 1000? No.
        // min-size: height 100 < 100? No (equal) -> unchanged; width 800 >= 50.
        // Result: (100,600,800,100) with height EXACTLY minHeight.
        let f = WindowResizeController.resizedFrame(
            corner: .bottomRight,
            startMouseGlobal: s, startFrame: startFrame, currentMouseGlobal: c,
            minWidth: 50, minHeight: 100, boundingFrame: bound)
        XCTAssertEqual(f.size.height, 100, accuracy: 1e-9,
                       "exactly-min room is inclusive: clamp applies and height == minHeight")
        assertRect(f, x: 100, y: 600, width: 800, height: 100)
    }

    // MARK: - 7. Seam-crossing regression: bound entirely on the far side of the anchor
    //            -> the dragged axis is untouched (no snap-to-minimum).

    func test_bottomRight_boundEntirelyLeftOfAnchor_rightAxisUntouched() {
        // The bound follows the mouse's screen; after a seam crossing it can lie
        // entirely LEFT of the window's anchored left edge (startFrame.minX = 100).
        // bound.maxX = 50 < 100, so (bound.maxX - startFrame.minX) = -50 < minWidth
        // -> right-axis clamp must be SKIPPED (not "rescued" into a min snap).
        // dx = +100 (drag right), dy = 0.
        let (s, c) = mouse(dx: 100, dy: 0)
        // Raw transform: width = 800+100 = 900 (maxX 1000); origin.y = 100;
        //                height = 600 (maxY 700); origin.x = 100.
        // Bound entirely left of the anchor: minX -200, minY 0, maxX 50, maxY 2000.
        let bound = NSRect(x: -200, y: 0, width: 250, height: 2000)
        // right precondition: 50 - 100 = -50 >= 50? No -> SKIPPED; width stays 900.
        // bottom: minY 100 < 0? No.
        // min-size: width 900 >= 50; height 600 >= 50 -> no change.
        // Result is the RAW transform, bound had no effect: (100,100,900,600).
        let f = WindowResizeController.resizedFrame(
            corner: .bottomRight,
            startMouseGlobal: s, startFrame: startFrame, currentMouseGlobal: c,
            minWidth: 50, minHeight: 50, boundingFrame: bound)
        assertRect(f, x: 100, y: 100, width: 900, height: 600)
    }

    // MARK: - 8. frameForCurrentDrag threads the bound through

    func test_frameForCurrentDrag_passesBoundingThrough() throws {
        let controller = WindowResizeController()
        // localPoint (600,400) in bounds 800x600: right of midline (400) and
        // above midline (300) -> corner = topRight. begin() is pure (no NSWindow).
        controller.begin(
            localPoint: CGPoint(x: 600, y: 400),
            in: CGRect(x: 0, y: 0, width: 800, height: 600),
            startMouseGlobal: CGPoint(x: 500, y: 500),
            windowFrame: startFrame)

        // Reuse the topRight overshoot scenario: dx = +120, dy = +90 -> current (620,590).
        // Bound: minX 0, minY 0, maxX 950, maxY 680. Both preconditions hold
        // (right room 950-100 = 850 >= 50; top room 680-100 = 580 >= 50).
        // Expected (see test_topRight_overshootsBothDraggedEdges): (100,100,850,580).
        let bound = NSRect(x: 0, y: 0, width: 950, height: 680)
        let f = try XCTUnwrap(controller.frameForCurrentDrag(
            currentMouseGlobal: CGPoint(x: 620, y: 590),
            minWidth: 50, minHeight: 50, boundingFrame: bound),
            "a drag is in flight so a frame must be produced")
        assertRect(f, x: 100, y: 100, width: 850, height: 580)
    }

    func test_frameForCurrentDrag_returnsNilWhenNoDragBegun() {
        let controller = WindowResizeController()
        let f = controller.frameForCurrentDrag(
            currentMouseGlobal: CGPoint(x: 620, y: 590),
            minWidth: 50, minHeight: 50,
            boundingFrame: NSRect(x: 0, y: 0, width: 950, height: 680))
        XCTAssertNil(f, "no begin() -> no in-flight drag -> nil regardless of bound")
    }
}
