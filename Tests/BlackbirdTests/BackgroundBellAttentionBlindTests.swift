import XCTest
import AppKit
import Combine
@testable import Blackbird

/// Blind behaviour tests for the "a bell in a tab you are not looking at
/// reaches you through the tab pill's attention dot (and the Dock bounce)"
/// path, written from the documented behaviour without sight of the
/// implementation.
///
/// Documented contract (README "Notifications", Settings > Behavior):
///   - Settings > Behavior > Bell = Visual / Sound / Visual and Sound / Off
///     governs what a shell BEL does. README: "a bell in a background tab
///     bounces the Dock icon (Settings -> Behavior: Bell = ... / Off)".
///   - Settings > Behavior > "Show notifications from programs" governs
///     program-originated alerts.
///   - A user who has turned the bell OFF *and* program notifications OFF
///     has asked to be left alone: a BEL arriving in a background tab must
///     NOT mark the tab (no unseen-attention dot, and by the same gate no
///     Dock bounce). With both settings at their defaults the dot still
///     appears (control case, so the rig is proven live).
///
/// Observable used: `MainWindowController.hasUnseenAttention` (the tab-pill
/// dot). The Dock bounce itself has no public query API, so it is covered
/// only through the dot that is raised from the same background-bell event.
///
/// The test deliberately does NOT pin the single-setting cases (Bell Off
/// with notifications on, or notifications off with the default bell):
/// the settings copy leaves either reading defensible. It pins only the
/// unambiguous case where BOTH controls say "no".
///
/// Safety (CLAUDE.md tab-group rule + `feedback_tabgroup_test_host_segv`):
/// the ONE headless controller built here (stub, no-PTY session) is NEVER
/// shown, closed, or ordered out; it is parked for process lifetime in a
/// static and every test reuses it. Window-key state is simulated by
/// calling the delegate method directly with a synthesized
/// `NSWindow.didBecomeKeyNotification`. Because the window is never key,
/// the tab is by construction "a tab you are not looking at".
///
/// Pre-flight (memory / time): one `makeForTesting(stubSession:)`
/// controller (headless 2x2 session, no PTY, a few MB for the Metal view),
/// built once; a one-byte BEL per feed; every wait is bounded (<= 3 s
/// timeouts, real settle time is a runloop hop) plus a 0.3 s negative
/// settle. Preferences touched are restored in `tearDown`.
final class BackgroundBellAttentionBlindTests: XCTestCase {

    private struct Parked {
        let controller: MainWindowController
        let session: TerminalSession
    }

    private static var parked: Parked?
    private static var creationAttempted = false

    private var savedBellRaw: String = ""
    private var savedProgramNotifications: Bool = true
    private var cancellables = Set<AnyCancellable>()

    override class func setUp() {
        super.setUp()
        TestHostTermination.shared.register()
    }

    override func setUp() {
        super.setUp()
        savedBellRaw = Preferences.shared.bellRaw
        savedProgramNotifications = Preferences.shared.programNotifications
    }

    override func tearDown() {
        cancellables.removeAll()
        if let p = Self.parked {
            becomeKey(p.controller)
        }
        Preferences.shared.bellRaw = savedBellRaw
        Preferences.shared.programNotifications = savedProgramNotifications
        super.tearDown()
    }

    // MARK: - Rig

    /// Build (once) or reuse the parked controller. Skips when the host has
    /// no Metal device (`makeForTesting` returns nil on CI virtual displays).
    private func parkedController() throws -> Parked {
        if let p = Self.parked { return p }
        if Self.creationAttempted {
            throw XCTSkip("no Metal device - makeForTesting returned nil earlier")
        }
        Self.creationAttempted = true
        let stub = TerminalSession.makeHeadlessForTests()
        guard let controller = MainWindowController.makeForTesting(stubSession: stub) else {
            throw XCTSkip("no Metal device (CI virtual display) - makeForTesting returned nil")
        }
        guard let session = controller.session else {
            throw XCTSkip("controller has no session - makeForTesting contract changed")
        }
        let p = Parked(controller: controller, session: session)
        Self.parked = p
        return p
    }

    private func becomeKey(_ controller: MainWindowController) {
        controller.windowDidBecomeKey(
            Notification(name: NSWindow.didBecomeKeyNotification, object: controller.window)
        )
    }

    /// Spin the main runloop for `seconds`.
    private func settle(_ seconds: TimeInterval) {
        RunLoop.current.run(until: Date(timeIntervalSinceNow: seconds))
    }

    /// Feed one BEL into the session and wait until the session publishes the
    /// incremented `bellCounter` (proves the BEL really reached the session,
    /// so a "no dot" result cannot be a bell that never arrived). Returns the
    /// counter delta observed.
    private func ringBell(on session: TerminalSession) -> UInt64 {
        let before = session.bellCounter
        let arrived = expectation(description: "bellCounter incremented")
        arrived.assertForOverFulfill = false
        session.$bellCounter
            .dropFirst()
            .sink { (value: UInt64) in
                if value != before { arrived.fulfill() }
            }
            .store(in: &cancellables)

        session.feedBytesForTests(Data([0x07]))
        wait(for: [arrived], timeout: 3.0)
        return session.bellCounter &- before
    }

    /// Wait (bounded) until `hasUnseenAttention` becomes true; returns the
    /// final value.
    private func waitForDot(_ controller: MainWindowController, timeout: TimeInterval) -> Bool {
        let deadline = Date(timeIntervalSinceNow: timeout)
        while !controller.hasUnseenAttention && Date() < deadline {
            settle(0.01)
        }
        return controller.hasUnseenAttention
    }

    private func applyBellPrefs(bell: Preferences.BellStyle, programNotifications: Bool) {
        Preferences.shared.bellRaw = bell.rawValue
        Preferences.shared.programNotifications = programNotifications
        // Precondition on the settings actually in force (not vacuous).
        XCTAssertEqual(Preferences.shared.bell, bell,
                       "precondition: Preferences.bell must read back as \(bell)")
        XCTAssertEqual(Preferences.shared.programNotifications, programNotifications,
                       "precondition: Preferences.programNotifications must read back as \(programNotifications)")
    }

    // MARK: - Tests

    /// Control: with the stock settings a BEL in a tab the user is not
    /// looking at raises the tab dot. Passes before and after the fix; it
    /// proves the rig delivers a BEL end to end and that the "Off" test
    /// below is not vacuously green.
    func test_backgroundBell_withDefaultSettings_dotsTheTab() throws {
        let p = try parkedController()
        becomeKey(p.controller)
        settle(0.05)
        XCTAssertEqual(p.controller.hasUnseenAttention, false,
                       "precondition: the dot starts cleared")

        applyBellPrefs(bell: .visual, programNotifications: true)

        let delta = ringBell(on: p.session)
        XCTAssertEqual(delta, 1, "precondition: exactly one BEL must reach the session (bellCounter delta)")

        let dotted = waitForDot(p.controller, timeout: 3.0)
        XCTAssertEqual(dotted, true,
                       "a BEL in a background tab with Bell=Visual and notifications on must dot the tab; hasUnseenAttention=\(dotted)")
    }

    /// The bug: Bell = Off and "Show notifications from programs" = off must
    /// stop the background-bell tab dot (and Dock bounce).
    func test_backgroundBell_withBellOffAndNotificationsOff_doesNotDotTheTab() throws {
        let p = try parkedController()

        // Phase 1 - prove the rig is live under default settings so the
        // phase-2 "no dot" cannot be a bell that never arrived.
        becomeKey(p.controller)
        settle(0.05)
        applyBellPrefs(bell: .visual, programNotifications: true)
        let delta1 = ringBell(on: p.session)
        XCTAssertEqual(delta1, 1, "precondition: the control BEL must reach the session")
        let controlDot = waitForDot(p.controller, timeout: 3.0)
        XCTAssertEqual(controlDot, true,
                       "precondition: under defaults a background BEL dots the tab (rig is live); hasUnseenAttention=\(controlDot)")

        // Phase 2 - user turns both controls off; tab is seen/cleared first.
        becomeKey(p.controller)
        settle(0.05)
        XCTAssertEqual(p.controller.hasUnseenAttention, false,
                       "precondition: the dot is cleared before the Off-settings BEL")
        applyBellPrefs(bell: .off, programNotifications: false)

        let delta2 = ringBell(on: p.session)
        XCTAssertEqual(delta2, 1, "precondition: the Off-settings BEL must reach the session (bellCounter delta)")
        settle(0.3)  // let every main-queue hop from the bell land

        XCTAssertEqual(p.controller.hasUnseenAttention, false,
                       "Bell=Off and Show notifications=off, yet a BEL in a background tab still raised the tab's unseen-attention dot (hasUnseenAttention=\(p.controller.hasUnseenAttention))")
    }

    /// A burst of bells with both controls off must stay quiet too (guards a
    /// fix that only suppresses the first bell or only the latch).
    func test_backgroundBellBurst_withBellOffAndNotificationsOff_doesNotDotTheTab() throws {
        let p = try parkedController()
        becomeKey(p.controller)
        settle(0.05)
        XCTAssertEqual(p.controller.hasUnseenAttention, false,
                       "precondition: the dot starts cleared")
        applyBellPrefs(bell: .off, programNotifications: false)

        var total: UInt64 = 0
        for _ in 0..<3 {
            total &+= ringBell(on: p.session)
        }
        XCTAssertEqual(total, 3, "precondition: all three BELs must reach the session")
        settle(0.3)

        XCTAssertEqual(p.controller.hasUnseenAttention, false,
                       "three BELs with Bell=Off and notifications off must not dot the tab (hasUnseenAttention=\(p.controller.hasUnseenAttention))")
    }
}
