import XCTest
@testable import Blackbird

final class SecureInputIndicatorTests: XCTestCase {

    // MARK: - SecureInputPoller

    func testIndicatorVisibleTracksPublishedSecureInputState() {
        let poller = SecureInputPoller()
        XCTAssertFalse(poller.isSecureInputActive, "Initial state should be false")

        poller._injectSecureStateForTests(true)
        XCTAssertTrue(poller.isSecureInputActive, "State should be true after injection")

        poller._injectSecureStateForTests(false)
        XCTAssertFalse(poller.isSecureInputActive, "State should be false after injection")
    }

    // MARK: - SecureInputIndicatorView

    func testIndicatorViewReflectsActiveState() {
        let view = SecureInputIndicatorView()

        XCTAssertTrue(view.isHidden, "View should be hidden initially")

        view.setActive(true)
        XCTAssertFalse(view.isHidden, "View should be visible when active")

        view.setActive(false)
        XCTAssertTrue(view.isHidden, "View should be hidden when inactive")
    }
}
