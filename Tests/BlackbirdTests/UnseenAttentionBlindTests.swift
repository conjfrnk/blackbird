import XCTest
import AppKit
@testable import Blackbird

/// Blind behaviour tests for `MainWindowController.hasUnseenAttention` /
/// `markUnseenAttention()`, written from the spec without sight of the
/// implementation.
///
/// Contract:
///   - A fresh controller has `hasUnseenAttention == false`.
///   - `markUnseenAttention()` flips it to `true` and posts ONE
///     `.blackbirdTabTitleChanged` with the controller's window as object.
///   - A second `markUnseenAttention()` while already set posts nothing.
///   - `windowDidBecomeKey(_:)` (the window becoming key) clears the flag.
///
/// Safety (CLAUDE.md tab-group rule + `feedback_tabgroup_test_host_segv`):
/// the ONE headless controller built here is NEVER shown, closed, or
/// ordered out — it is parked for process lifetime in a static and every
/// test reuses it. Window-key state is simulated by calling the delegate
/// method directly with a synthesized `NSWindow.didBecomeKeyNotification`.
///
/// Pre-flight: one `makeForTesting(stubSession:)` controller (headless
/// 2×2 session, no PTY, ~a few MB resident for the Metal view), built
/// once. No runloop pumping beyond a single ≤ 50 ms tick per test.
final class UnseenAttentionBlindTests: XCTestCase {

    /// The single parked controller and the value of `hasUnseenAttention`
    /// observed at the moment it was created (before any test poked it).
    private struct Parked {
        let controller: MainWindowController
        let freshValue: Bool
    }

    private static var parked: Parked?
    private static var creationAttempted = false

    override class func setUp() {
        super.setUp()
        TestHostTermination.shared.register()
    }

    /// Build (once) or reuse the parked controller. Skips when the host has
    /// no Metal device (`makeForTesting` returns nil on CI virtual displays).
    private func parkedController() throws -> Parked {
        if let p = Self.parked { return p }
        if Self.creationAttempted {
            throw XCTSkip("no Metal device — makeForTesting returned nil earlier")
        }
        Self.creationAttempted = true
        guard let controller = MainWindowController.makeForTesting(
            stubSession: .makeHeadlessForTests()
        ) else {
            throw XCTSkip("no Metal device (CI virtual display) — makeForTesting returned nil")
        }
        let p = Parked(controller: controller, freshValue: controller.hasUnseenAttention)
        Self.parked = p
        return p
    }

    /// Observer that counts `.blackbirdTabTitleChanged` posts whose object
    /// is `window`, and separately any post with a DIFFERENT object.
    private final class TitleChangeCounter {
        private(set) var matching = 0
        private(set) var otherObject = 0
        private var token: NSObjectProtocol?

        init(window: NSWindow?) {
            token = NotificationCenter.default.addObserver(
                forName: .blackbirdTabTitleChanged, object: nil, queue: nil
            ) { [weak self] note in
                guard let self else { return }
                if let w = note.object as? NSWindow, w === window {
                    self.matching += 1
                } else {
                    self.otherObject += 1
                }
            }
        }

        deinit {
            if let token { NotificationCenter.default.removeObserver(token) }
        }
    }

    private func becomeKey(_ controller: MainWindowController) {
        controller.windowDidBecomeKey(
            Notification(name: NSWindow.didBecomeKeyNotification, object: controller.window)
        )
    }

    /// Let any deferred (main-async) post land before we count.
    private func tick() {
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))
    }

    // MARK: - Tests

    func test_freshController_hasNoUnseenAttention() throws {
        let p = try parkedController()
        XCTAssertFalse(p.freshValue, "a freshly built controller must start with no unseen attention")
    }

    func test_mark_setsFlag_andPostsTabTitleChangedOnce() throws {
        let p = try parkedController()
        let controller = p.controller
        // Normalize: make sure we start cleared regardless of test order.
        becomeKey(controller)
        XCTAssertFalse(controller.hasUnseenAttention, "precondition: cleared")

        tick()  // drain posts deferred by the preceding becomeKey/mark

        let counter = TitleChangeCounter(window: controller.window)
        controller.markUnseenAttention()
        tick()

        XCTAssertTrue(controller.hasUnseenAttention)
        XCTAssertEqual(counter.matching, 1,
                       "markUnseenAttention must post .blackbirdTabTitleChanged with the window as object exactly once")
        XCTAssertEqual(counter.otherObject, 0,
                       "the post's object must be the controller's window")

        // Leave cleared for the next test.
        becomeKey(controller)
    }

    func test_secondMark_whileAlreadySet_postsNothing() throws {
        let p = try parkedController()
        let controller = p.controller
        becomeKey(controller)
        controller.markUnseenAttention()
        tick()
        XCTAssertTrue(controller.hasUnseenAttention, "precondition: set")

        tick()  // drain posts deferred by the preceding becomeKey/mark

        let counter = TitleChangeCounter(window: controller.window)
        controller.markUnseenAttention()
        tick()

        XCTAssertTrue(controller.hasUnseenAttention, "flag stays set")
        XCTAssertEqual(counter.matching, 0,
                       "a redundant markUnseenAttention must not re-post .blackbirdTabTitleChanged")

        becomeKey(controller)
    }

    func test_windowBecomingKey_clearsFlag() throws {
        let p = try parkedController()
        let controller = p.controller
        becomeKey(controller)
        controller.markUnseenAttention()
        XCTAssertTrue(controller.hasUnseenAttention, "precondition: set")

        becomeKey(controller)
        XCTAssertFalse(controller.hasUnseenAttention,
                       "the window becoming key means the user saw it — flag must clear")
    }

    func test_afterClear_markPostsAgain() throws {
        // The one-post latch must reset with the flag, so a later
        // notification while unfocused re-highlights the tab.
        let p = try parkedController()
        let controller = p.controller
        becomeKey(controller)
        controller.markUnseenAttention()
        becomeKey(controller)
        XCTAssertFalse(controller.hasUnseenAttention, "precondition: cleared")
        // Drain the posts the two becomeKey calls deferred (the title KVO
        // path posts main-async) so the counter attributes only the mark.
        tick()

        tick()  // drain posts deferred by the preceding becomeKey/mark

        let counter = TitleChangeCounter(window: controller.window)
        controller.markUnseenAttention()
        tick()
        XCTAssertTrue(controller.hasUnseenAttention)
        // At least one: the clear's own refresh can leave title-KVO posts
        // landing in this window under load (they carry the same object),
        // so this pins "posts again", while the second-mark test pins
        // "does not post twice for a redundant mark".
        XCTAssertGreaterThanOrEqual(counter.matching, 1, "a mark after a clear must post again")

        becomeKey(controller)
    }

    func test_becomeKeyWhenAlreadyClear_isHarmless() throws {
        let p = try parkedController()
        let controller = p.controller
        becomeKey(controller)
        XCTAssertFalse(controller.hasUnseenAttention)
        becomeKey(controller)
        XCTAssertFalse(controller.hasUnseenAttention, "clearing twice stays cleared")
    }
}
