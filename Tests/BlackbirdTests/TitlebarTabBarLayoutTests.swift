import XCTest
import AppKit
@testable import Blackbird

/// Layout invariants for the combined titlebar accessory (tab strip + SKE
/// lock icon in a single `.right` NSTitlebarAccessoryViewController).
/// Before the merge, two sibling `.right` accessories stacked in AppKit-
/// defined order that sometimes hid the lock behind the strip on multi-
/// tab windows — these tests pin the single-accessory invariants so the
/// bug can't silently come back.
final class TitlebarTabBarLayoutTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        TestHostTermination.shared.register()
    }

    private func makeController() -> (TitlebarTabBarViewController, NSWindow) {
        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 400),
            styleMask: [.titled],
            backing: .buffered,
            defer: true
        )
        let vc = TitlebarTabBarViewController(window: w)
        return (vc, w)
    }

    func test_singleTab_container_is_lockReservation_wide_and_strip_is_hidden() {
        let (vc, _) = makeController()
        vc.refreshSingleTab()

        XCTAssertEqual(vc.view.frame.width, TitlebarTabBarViewController.lockReservation,
                       "Single-tab accessory width must equal lockReservation.")
        XCTAssertEqual(vc.view.frame.height, TabStripView.height)

        let strip = vc.view.subviews.first { $0 is TabStripView }
        XCTAssertNotNil(strip, "TabStripView should be a subview of the accessory container.")
        XCTAssertTrue(strip?.isHidden ?? false, "Strip should be hidden in single-tab mode.")
    }

    func test_multiTab_container_spans_availableWidth_and_strip_reserves_lock_area() {
        let (vc, _) = makeController()
        let available: CGFloat = 720
        vc.refreshMultiTab(availableWidth: available)

        XCTAssertEqual(vc.view.frame.width, available,
                       "Multi-tab accessory width must equal the caller's availableWidth.")

        let strip = vc.view.subviews.compactMap { $0 as? TabStripView }.first
        XCTAssertNotNil(strip, "TabStripView must be present in the accessory view hierarchy.")
        XCTAssertFalse(strip?.isHidden ?? true, "Strip should be visible in multi-tab mode.")
        XCTAssertEqual(strip?.frame.width,
                       available - TitlebarTabBarViewController.lockReservation,
                       "Strip width must be availableWidth minus the trailing lock reservation.")
    }

    func test_lock_sits_at_trailing_edge_in_both_modes() {
        let (vc, _) = makeController()

        vc.refreshSingleTab()
        var lockMaxX = vc.lockView.frame.maxX
        XCTAssertEqual(lockMaxX, vc.view.frame.width - 8, accuracy: 0.5,
                       "Single-tab: lock must sit 8pt from the container's trailing edge.")

        vc.refreshMultiTab(availableWidth: 720)
        lockMaxX = vc.lockView.frame.maxX
        XCTAssertEqual(lockMaxX, vc.view.frame.width - 8, accuracy: 0.5,
                       "Multi-tab: lock must sit 8pt from the container's trailing edge.")
    }

    func test_lock_vertical_center_matches_pill_vertical_center() {
        // Pills in TabStripView's flipped coords: y=4, h=24 → center y=16
        // from top. The accessory container is unflipped, so 16-from-top on
        // a 28-tall view equals 12-from-bottom. The lock's midY should land
        // on that same 12, independent of accessory width.
        let (vc, _) = makeController()
        vc.refreshMultiTab(availableWidth: 720)
        let expectedCenterY: CGFloat = 12
        XCTAssertEqual(vc.lockView.frame.midY, expectedCenterY, accuracy: 0.5,
                       "Lock midY must align with pill-row center (12pt from container bottom).")
    }

    func test_resize_repositions_lock_to_new_trailing_edge() {
        // Regression: a window resize should slide the lock to the new
        // trailing edge, not leave it frozen at the old x.
        let (vc, _) = makeController()
        vc.refreshMultiTab(availableWidth: 600)
        let firstMaxX = vc.lockView.frame.maxX

        vc.refreshMultiTab(availableWidth: 900)
        let secondMaxX = vc.lockView.frame.maxX

        XCTAssertNotEqual(firstMaxX, secondMaxX,
                          "Lock should reposition when availableWidth changes.")
        XCTAssertEqual(secondMaxX, 900 - 8, accuracy: 0.5,
                       "After growing to 900pt, lock must pin to the new trailing edge.")
    }
}
