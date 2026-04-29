import XCTest
import AppKit
@testable import Blackbird

/// Regression for M-15 (EC-2): `ScrollIndicator.update` was computing
/// `scrollFromBottom = displayOffset / max(historySize, 1)` without an
/// upper clamp. If the Rust scroll math ever produced
/// `displayOffset > historySize` (regression / transient mis-snap), the
/// resulting > 1.0 ratio would paint the thumb above the track — a
/// silent visual bug, not a crash.
///
/// The pin: feed `displayOffset > historySize` and verify the thumb's
/// origin Y is within `[0, track - thumbHeight]` (i.e. on the track,
/// not above its top edge). The thumb layer is private; observed via
/// `Mirror` so no DEBUG seam is required.
final class ScrollIndicatorTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        TestHostTermination.shared.register()
    }

    /// Pull the private `thumbLayer` out of the `ScrollIndicator`
    /// instance so we can read its frame after `update`.
    private func thumbFrame(of indicator: ScrollIndicator) -> NSRect? {
        let m = Mirror(reflecting: indicator)
        for child in m.children {
            if child.label == "thumbLayer", let layer = child.value as? CALayer {
                return layer.frame
            }
        }
        return nil
    }

    func test_displayOffsetExceedsHistorySize_thumbStaysOnTrack() {
        // 200pt-tall indicator, 50 lines history, 24 visible rows.
        // Force a "displayOffset way past historySize" state — without
        // the clamp this would put the thumb above the track top.
        let indicator = ScrollIndicator(frame: NSRect(x: 0, y: 0, width: 12, height: 200))
        indicator.update(displayOffset: 9999, historySize: 50, rows: 24)

        guard let f = thumbFrame(of: indicator) else {
            XCTFail("thumbLayer not observable via Mirror")
            return
        }
        let trackHeight: CGFloat = 200
        // Thumb origin y must lie on the track, not above its top edge.
        XCTAssertGreaterThanOrEqual(f.origin.y, 0,
            "thumb origin Y must not go negative")
        XCTAssertLessThanOrEqual(f.origin.y + f.size.height, trackHeight + 0.5,
            "thumb top must not exceed track top edge")
        // Sanity: thumb has nonzero height and finite frame.
        XCTAssertTrue(f.size.height.isFinite)
        XCTAssertGreaterThan(f.size.height, 0)
    }

    func test_displayOffsetEqualsHistorySize_thumbAtTop() {
        // Boundary case (already correct pre-fix): exactly at top.
        let indicator = ScrollIndicator(frame: NSRect(x: 0, y: 0, width: 12, height: 200))
        indicator.update(displayOffset: 50, historySize: 50, rows: 24)

        guard let f = thumbFrame(of: indicator) else {
            XCTFail("thumbLayer not observable via Mirror")
            return
        }
        let trackHeight: CGFloat = 200
        // At "top" → thumb y == track - thumbHeight.
        XCTAssertEqual(f.origin.y + f.size.height, trackHeight, accuracy: 0.5,
            "displayOffset == historySize should pin thumb-top to track-top")
    }

    func test_displayOffsetZero_thumbAtBottom() {
        let indicator = ScrollIndicator(frame: NSRect(x: 0, y: 0, width: 12, height: 200))
        indicator.update(displayOffset: 0, historySize: 50, rows: 24)

        guard let f = thumbFrame(of: indicator) else {
            XCTFail("thumbLayer not observable via Mirror")
            return
        }
        // At bottom → thumb y == 0.
        XCTAssertEqual(f.origin.y, 0, accuracy: 0.5,
            "displayOffset == 0 should pin thumb to track bottom")
    }
}
