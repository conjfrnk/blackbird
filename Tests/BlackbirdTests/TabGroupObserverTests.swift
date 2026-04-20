import XCTest
import AppKit
@testable import Blackbird

/// Structural smoke test for the tab-group identity reset logic in
/// `MainWindowController.refreshTabBar`. We can't directly inspect the KVO
/// tokens (they're private), so we drive the controller through a
/// detach/merge cycle and verify it doesn't crash, leaves the window in
/// a consistent state, and produces the expected `tabGroup` membership
/// at each step. The end-to-end pill-strip redraw is covered by manual
/// checks in the design doc's test plan.
final class TabGroupObserverTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        TestHostTermination.shared.register()
    }

    func test_detach_then_merge_keeps_controllers_consistent() {
        let a = MainWindowController(initialWorkingDirectory: nil, autosaveFrame: false)
        let b = MainWindowController(initialWorkingDirectory: nil, autosaveFrame: false)
        defer {
            a.terminateSessions()
            b.terminateSessions()
            a.window?.close()
            b.window?.close()
        }
        guard let aw = a.window, let bw = b.window else {
            return XCTFail("windows not created")
        }
        aw.makeKeyAndOrderFront(nil)
        aw.addTabbedWindow(bw, ordered: .above)
        // Flush the DispatchQueue.main.async'd observer attach that
        // installTitlebarTabBar defers.
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        XCTAssertNotNil(aw.tabGroup, "a joined a tab group")
        XCTAssertNotNil(bw.tabGroup, "b joined a tab group")
        XCTAssertTrue(aw.tabGroup === bw.tabGroup, "same group")

        // Detach b by moving it out of the group.
        bw.moveTabToNewWindow(nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        // Exercise the identity-reset branch; no crash + consistent state.
        a.refreshTabBar()
        b.refreshTabBar()
        XCTAssertNotEqual(
            aw.tabGroup.map(ObjectIdentifier.init),
            bw.tabGroup.map(ObjectIdentifier.init),
            "groups diverge after detach"
        )

        // Merge back.
        aw.addTabbedWindow(bw, ordered: .above)
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        a.refreshTabBar()
        b.refreshTabBar()
        XCTAssertNotNil(bw.tabGroup, "b rejoined a tab group")
        XCTAssertTrue(
            aw.tabGroup === bw.tabGroup,
            "after re-merge a and b share a group again"
        )
    }
}
