import XCTest
import UserNotifications
import ObjectiveC
@testable import Blackbird

/// Blind regression test for bug app-lifecycle-3: a notification-permission
/// denial must not be sticky for the whole process lifetime.
///
/// Contract (from the bug report, terminal and macOS conventions):
///   - OSC 9 / 777 / 99 notifications that arrive while the user is elsewhere
///     are handed to macOS (`UNUserNotificationCenter.add`) once Blackbird is
///     allowed to notify.
///   - While macOS says "denied", nothing is handed over (no unauthorized
///     `add`).
///   - Permission is owned by macOS, not by Blackbird. If the user turns
///     Notifications on for Blackbird in System Settings WITHOUT quitting
///     Blackbird, the next program notification must be delivered. Sessions
///     run for days; a denial seen once must not mute them until relaunch.
///
/// Rig: the xctest host cannot talk to the real notification centre, so this
/// swizzles `+[UNUserNotificationCenter currentNotificationCenter]` to return
/// a fake centre whose permission status the test flips, exactly like the user
/// flipping the switch in System Settings. Both `requestAuthorization` and
/// `getNotificationSettings` answer from that one status, and `add` records
/// what reached the system. The swizzle is installed (and verified) before any
/// presenter exists and removed in tearDown; if it cannot be verified the test
/// aborts before the presenter can touch the real centre.
///
/// Pre-flight: one presenter, a handful of strings, no windows, no PTY, no
/// real notification traffic. Bounded waits: <= 3 s to reach `.denied`, <= 2 s
/// per expected delivery, 0.4 s fixed settle for the "must not deliver" phase.
final class NotificationAuthRefreshBlindTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        TestHostTermination.shared.register()
    }

    private var restoreCenter: (() -> Void)?

    override func setUpWithError() throws {
        try super.setUpWithError()
        let system = FakeNotificationSystem.shared
        system.reset(status: .denied)
        restoreCenter = try CenterSeam.install(system.center)
    }

    override func tearDown() {
        restoreCenter?()
        restoreCenter = nil
        FakeNotificationSystem.shared.reset(status: .denied)
        super.tearDown()
    }

    // MARK: - Helpers

    @discardableResult
    private func spin(timeout: TimeInterval, until condition: () -> Bool) -> Bool {
        let deadline = Date(timeIntervalSinceNow: timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.01))
        }
        return condition()
    }

    // MARK: - Tests

    func test_denialIsNotSticky_enablingNotificationsInSystemSettingsDeliversLaterPosts() {
        let system = FakeNotificationSystem.shared
        let presenter = NotificationPresenter(systemCenterAvailable: true)
        XCTAssertTrue(presenter.isSystemCenterAvailable,
                      "rig: presenter must be built with the system centre path enabled")

        // 1. Notifications are off for Blackbird; a background tab notifies.
        //    The presenter learns the denial (the bug report's authState=.denied).
        presenter.post(TerminalNotification(title: "Claude Code", body: "while denied #1"))
        spin(timeout: 3) { presenter.authState == .denied }
        XCTAssertEqual(presenter.authState, .denied,
                       "precondition: a post while macOS denies notifications must leave the "
                       + "presenter in .denied; centre calls: \(system.callLog)")
        XCTAssertEqual(system.deliveredToUser, [],
                       "precondition: nothing may reach the user while macOS denies permission")

        // 2. Still denied: a second notification is still not handed over.
        //    (Guards against a 'fix' that just forwards everything.)
        presenter.post(TerminalNotification(title: "Claude Code", body: "while denied #2"))
        spin(timeout: 0.4) { false }
        XCTAssertEqual(system.addAttempts, [],
                       "while macOS denies permission nothing may be passed to add(); "
                       + "saw \(system.addAttempts)")

        // 3. The user turns Notifications on for Blackbird in System Settings.
        //    Blackbird is NOT relaunched.
        system.setStatus(.authorized)

        // 4. The next background-tab notification must reach the user.
        let build = FakeDelivery(title: "Build finished", body: "make exited 0")
        presenter.post(TerminalNotification(title: build.title, body: build.body))
        spin(timeout: 2) { system.deliveredToUser.count >= 1 }
        XCTAssertEqual(system.deliveredToUser, [build],
                       "after Notifications were enabled in System Settings the next notification "
                       + "must be delivered without a relaunch; delivered=\(system.deliveredToUser) "
                       + "authState=\(presenter.authState) centre calls: \(system.callLog)")
        guard system.deliveredToUser.count == 1 else { return }

        // 5. And it keeps working afterwards.
        let tests = FakeDelivery(title: "Tests", body: "all 42 passed")
        presenter.post(TerminalNotification(title: tests.title, body: tests.body))
        spin(timeout: 2) { system.deliveredToUser.count >= 2 }
        XCTAssertEqual(system.deliveredToUser, [build, tests],
                       "once granted, every later notification must be delivered in order; "
                       + "delivered=\(system.deliveredToUser) authState=\(presenter.authState)")
    }
}

// MARK: - Fake macOS notification system

private struct FakeDelivery: Equatable, CustomStringConvertible {
    let title: String
    let body: String
    var description: String { "(\(title) | \(body))" }
}

private struct CenterRigError: Error, CustomStringConvertible {
    let description: String
}

/// Thread-safe model of macOS's permission switch and of what reached the user.
/// Completion handlers are invoked from a background queue, like the real
/// centre's XPC replies.
private final class FakeNotificationSystem: @unchecked Sendable {
    static let shared = FakeNotificationSystem()

    private let lock = NSLock()
    private var status: UNAuthorizationStatus = .denied
    private var attempts: [FakeDelivery] = []
    private var delivered: [FakeDelivery] = []
    private var calls: [String] = []
    private weak var storedDelegate: (any UNUserNotificationCenterDelegate)?

    /// Kept alive for the whole process (the instance is made without Swift's
    /// initializer chain, so it must never be deallocated).
    private(set) lazy var center: FakeCenter = {
        guard let made = class_createInstance(FakeCenter.self, 0) as? FakeCenter else {
            fatalError("could not instantiate FakeCenter")
        }
        return made
    }()

    func reset(status: UNAuthorizationStatus) {
        lock.lock(); defer { lock.unlock() }
        self.status = status
        attempts = []
        delivered = []
        calls = []
    }

    func setStatus(_ newStatus: UNAuthorizationStatus) {
        lock.lock(); defer { lock.unlock() }
        status = newStatus
        calls.append("[system settings -> \(newStatus.rawValue)]")
    }

    func currentStatus() -> UNAuthorizationStatus {
        lock.lock(); defer { lock.unlock() }
        return status
    }

    func record(_ call: String) {
        lock.lock(); defer { lock.unlock() }
        calls.append(call)
    }

    /// What `UNUserNotificationCenter.add` was asked to post. Anything added
    /// while permission is not authorized is silently discarded by macOS, so
    /// it never counts as delivered.
    func recordAdd(title: String, body: String) {
        lock.lock(); defer { lock.unlock() }
        let item = FakeDelivery(title: title, body: body)
        attempts.append(item)
        if status == .authorized { delivered.append(item) }
        calls.append("add(\(item))@status=\(status.rawValue)")
    }

    var addAttempts: [FakeDelivery] {
        lock.lock(); defer { lock.unlock() }
        return attempts
    }

    var deliveredToUser: [FakeDelivery] {
        lock.lock(); defer { lock.unlock() }
        return delivered
    }

    var callLog: [String] {
        lock.lock(); defer { lock.unlock() }
        return calls
    }

    var delegate: (any UNUserNotificationCenterDelegate)? {
        get { lock.lock(); defer { lock.unlock() }; return storedDelegate }
        set { lock.lock(); defer { lock.unlock() }; storedDelegate = newValue }
    }
}

/// Settings snapshot answering from the fake permission status.
private final class FakeSettings: UNNotificationSettings {
    var snapshotRawStatus: Int = 0

    static func make(status: UNAuthorizationStatus) -> FakeSettings {
        guard let made = class_createInstance(FakeSettings.self, 0) as? FakeSettings else {
            fatalError("could not instantiate FakeSettings")
        }
        made.snapshotRawStatus = status.rawValue
        return made
    }

    override var authorizationStatus: UNAuthorizationStatus {
        UNAuthorizationStatus(rawValue: snapshotRawStatus) ?? .notDetermined
    }
    override var alertSetting: UNNotificationSetting { snapshotRawStatus == 2 ? .enabled : .disabled }
    override var soundSetting: UNNotificationSetting { snapshotRawStatus == 2 ? .enabled : .disabled }
    override var badgeSetting: UNNotificationSetting { snapshotRawStatus == 2 ? .enabled : .disabled }
    override var notificationCenterSetting: UNNotificationSetting { snapshotRawStatus == 2 ? .enabled : .disabled }
    override var lockScreenSetting: UNNotificationSetting { snapshotRawStatus == 2 ? .enabled : .disabled }
}

/// Fake `UNUserNotificationCenter`. Instances are created with
/// `class_createInstance` because the real class marks `init` unavailable.
private final class FakeCenter: UNUserNotificationCenter {
    private var system: FakeNotificationSystem { FakeNotificationSystem.shared }

    override var delegate: (any UNUserNotificationCenterDelegate)? {
        get { system.delegate }
        set { system.record("setDelegate"); system.delegate = newValue }
    }

    override func requestAuthorization(
        options: UNAuthorizationOptions = [],
        completionHandler: @escaping @Sendable (Bool, (any Error)?) -> Void
    ) {
        let granted = system.currentStatus() == .authorized
        system.record("requestAuthorization -> granted=\(granted)")
        DispatchQueue.global(qos: .userInitiated).async { completionHandler(granted, nil) }
    }

    override func getNotificationSettings(
        completionHandler: @escaping @Sendable (UNNotificationSettings) -> Void
    ) {
        let status = system.currentStatus()
        system.record("getNotificationSettings -> status=\(status.rawValue)")
        nonisolated(unsafe) let settings = FakeSettings.make(status: status)
        DispatchQueue.global(qos: .userInitiated).async { completionHandler(settings) }
    }

    override func add(
        _ request: UNNotificationRequest,
        withCompletionHandler completionHandler: (@Sendable ((any Error)?) -> Void)? = nil
    ) {
        system.recordAdd(title: request.content.title, body: request.content.body)
        if let completionHandler {
            DispatchQueue.global(qos: .userInitiated).async { completionHandler(nil) }
        }
    }

    override func setNotificationCategories(_ categories: Set<UNNotificationCategory>) {
        system.record("setNotificationCategories")
    }

    override func removeAllDeliveredNotifications() {
        system.record("removeAllDeliveredNotifications")
    }

    override func removeAllPendingNotificationRequests() {
        system.record("removeAllPendingNotificationRequests")
    }

    override func removeDeliveredNotifications(withIdentifiers identifiers: [String]) {
        system.record("removeDeliveredNotifications")
    }

    override func removePendingNotificationRequests(withIdentifiers identifiers: [String]) {
        system.record("removePendingNotificationRequests")
    }
}

/// Makes `UNUserNotificationCenter.current()` return the fake centre.
private enum CenterSeam {
    static func install(_ fake: FakeCenter) throws -> () -> Void {
        let selector = NSSelectorFromString("currentNotificationCenter")
        guard let method = class_getClassMethod(UNUserNotificationCenter.self, selector) else {
            throw CenterRigError(description: "rig: +currentNotificationCenter not found")
        }
        let original = method_getImplementation(method)
        let block: @convention(block) (AnyObject) -> AnyObject = { _ in fake }
        let replacement = imp_implementationWithBlock(block)
        method_setImplementation(method, replacement)

        let restore: () -> Void = {
            method_setImplementation(method, original)
            imp_removeBlock(replacement)
        }
        // Verify BEFORE any presenter exists: if the seam did not take, abort
        // so the presenter can never reach the real centre.
        guard UNUserNotificationCenter.current() === fake else {
            restore()
            throw CenterRigError(description: "rig: UNUserNotificationCenter.current() is not the fake centre")
        }
        return restore
    }
}
