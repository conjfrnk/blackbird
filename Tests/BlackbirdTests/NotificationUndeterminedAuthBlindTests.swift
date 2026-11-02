import XCTest
import UserNotifications
import ObjectiveC
@testable import Blackbird

/// Blind regression test for bug app-lifecycle-3b: an UNDETERMINED
/// notification-permission status must never be latched as a final denial.
///
/// Contract (from the bug report, terminal and macOS conventions):
///   - `UNAuthorizationStatus.notDetermined` means "macOS has not recorded a
///     decision yet". It is the one state where Blackbird is still allowed to
///     (and must be able to) ask: `requestAuthorization` is what puts the
///     permission prompt in front of the user. Treating it like `.denied`
///     ("drop the notification, do not ask again") mutes notifications for the
///     whole process lifetime although the user never said no.
///   - Two doors lead there, both covered below:
///       1. A `requestAuthorization` call FAILS (transient error, no decision
///          recorded, status is still `.notDetermined`). A later program
///          notification must retry the prompt.
///       2. A cached denial is re-read on a later post and macOS now answers
///          `.notDetermined` (the user reset Blackbird's notification
///          permission, e.g. `tccutil reset` / re-adding the app). A later
///          program notification must ask again rather than be dropped.
///   - Retrying must not become "forward everything": nothing is ever handed
///     to `UNUserNotificationCenter.add` while macOS has not authorized.
///
/// Whether the notification that triggers the retry is delivered immediately or
/// the retry only becomes effective for the notification after it is a design
/// choice this test deliberately does not pin down: each scenario posts up to
/// two notifications after the failure, and requires that the prompt was asked
/// for again and that the LAST notification reached the user.
///
/// Rig: the xctest host cannot talk to the real notification centre, so this
/// swizzles `+[UNUserNotificationCenter currentNotificationCenter]` to return a
/// fake centre (same technique as `NotificationAuthRefreshBlindTests`). The
/// fake models macOS's permission switch: `requestAuthorization` against an
/// undetermined status follows a scripted outcome (transient error / user
/// allows / user denies), against a decided status it just reports the status;
/// `getNotificationSettings` answers from the same status; `add` records what
/// reached the system. The swizzle is installed (and verified) before any
/// presenter exists and removed in tearDown; if it cannot be verified the test
/// aborts before the presenter can touch the real centre.
///
/// Pre-flight cost: one presenter per test, a few strings, no windows, no PTY.
/// Bounded waits: <= 3 s for the first request, <= 2 s settle, <= 2 s per
/// expected delivery (two deliveries per scenario at most).
final class NotificationUndeterminedAuthBlindTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        TestHostTermination.shared.register()
    }

    private var restoreCenter: (() -> Void)?

    override func setUpWithError() throws {
        try super.setUpWithError()
        let system = UndeterminedFakeSystem.shared
        system.reset(status: .notDetermined, plan: [])
        restoreCenter = try UndeterminedCenterSeam.install(system.center)
    }

    override func tearDown() {
        restoreCenter?()
        restoreCenter = nil
        UndeterminedFakeSystem.shared.reset(status: .notDetermined, plan: [])
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

    /// Posts one notification and waits (bounded) for it to reach the user.
    @discardableResult
    private func postAndAwaitDelivery(
        _ presenter: NotificationPresenter,
        _ delivery: UndeterminedDelivery,
        system: UndeterminedFakeSystem
    ) -> Bool {
        presenter.post(TerminalNotification(title: delivery.title, body: delivery.body))
        return spin(timeout: 2) { system.deliveredToUser.contains(delivery) }
    }

    // MARK: - Tests

    /// Door 1: the permission request errors out, leaving macOS undecided.
    func test_failedPermissionRequest_leavesUndetermined_laterPostRetriesThePromptAndDelivers() {
        let system = UndeterminedFakeSystem.shared
        // The first prompt attempt fails transiently (nothing recorded by
        // macOS); the next attempt the user allows.
        system.reset(status: .notDetermined, plan: [.transientError, .allow])
        let presenter = NotificationPresenter(systemCenterAvailable: true)
        XCTAssertTrue(presenter.isSystemCenterAvailable,
                      "rig: presenter must be built with the system centre path enabled")

        // 1. A background tab notifies; Blackbird asks macOS for permission and
        //    the request FAILS.
        presenter.post(TerminalNotification(title: "Claude Code", body: "first, request fails"))
        spin(timeout: 3) { system.promptOutcomes.count >= 1 }
        spin(timeout: 2) { presenter.authState != .pending }
        XCTAssertEqual(system.promptOutcomes, [.transientError],
                       "precondition: the first post must put exactly one failing permission "
                       + "request to macOS; centre calls: \(system.callLog)")
        XCTAssertEqual(system.currentStatus(), .notDetermined,
                       "precondition: a failed request must leave macOS undecided")
        XCTAssertEqual(system.deliveredToUser, [],
                       "precondition: nothing may reach the user while permission is unresolved")
        let requestsAfterFailure = system.requestCount

        // 2. Later notifications arrive. The prompt must be asked for again, and
        //    the user (who allows this time) must receive notifications.
        let second = UndeterminedDelivery(title: "Build finished", body: "make exited 0")
        let third = UndeterminedDelivery(title: "Tests", body: "all 42 passed")
        postAndAwaitDelivery(presenter, second, system: system)
        postAndAwaitDelivery(presenter, third, system: system)

        XCTAssertGreaterThan(system.requestCount, requestsAfterFailure,
                             "an undetermined status after a failed request must not be latched as a "
                             + "denial: a later notification has to ask macOS for permission again; "
                             + "requests before=\(requestsAfterFailure) after=\(system.requestCount) "
                             + "authState=\(presenter.authState) centre calls: \(system.callLog)")
        XCTAssertEqual(system.deliveredToUser.filter { (item: UndeterminedDelivery) -> Bool in item == third },
                       [third],
                       "after the retried prompt was allowed the later notification must be "
                       + "delivered exactly once; delivered=\(system.deliveredToUser) "
                       + "authState=\(presenter.authState) centre calls: \(system.callLog)")
        XCTAssertEqual(system.addAttempts, system.deliveredToUser,
                       "nothing may be handed to add() while macOS has not authorized; "
                       + "attempts=\(system.addAttempts) delivered=\(system.deliveredToUser)")
    }

    /// Door 2: a cached denial is re-read and macOS now says "not determined".
    func test_cachedDenial_thenStatusBecomesUndetermined_laterPostAsksAgainInsteadOfDropping() {
        let system = UndeterminedFakeSystem.shared
        // Notifications are off for Blackbird; when the permission is later reset
        // and Blackbird asks again, the user allows.
        system.reset(status: .denied, plan: [.allow])
        let presenter = NotificationPresenter(systemCenterAvailable: true)
        XCTAssertTrue(presenter.isSystemCenterAvailable,
                      "rig: presenter must be built with the system centre path enabled")

        // 1. A real denial: the presenter ends up in .denied.
        presenter.post(TerminalNotification(title: "Claude Code", body: "while denied"))
        spin(timeout: 3) { presenter.authState == .denied }
        XCTAssertEqual(presenter.authState, .denied,
                       "precondition: a post while macOS denies notifications must leave the "
                       + "presenter in .denied; centre calls: \(system.callLog)")
        XCTAssertEqual(system.deliveredToUser, [],
                       "precondition: nothing may reach the user while macOS denies permission")
        XCTAssertEqual(system.promptOutcomes, [],
                       "precondition: against a decided status macOS shows no prompt")

        // 2. The user resets Blackbird's notification permission: macOS forgets
        //    the decision. Blackbird is NOT relaunched.
        system.setStatus(.notDetermined)
        let requestsBeforeReset = system.requestCount

        // 3. Later notifications arrive; the undetermined status must lead to a
        //    fresh permission request, not to a silent drop.
        let second = UndeterminedDelivery(title: "Build finished", body: "make exited 0")
        let third = UndeterminedDelivery(title: "Tests", body: "all 42 passed")
        postAndAwaitDelivery(presenter, second, system: system)
        postAndAwaitDelivery(presenter, third, system: system)

        XCTAssertGreaterThan(system.requestCount, requestsBeforeReset,
                             "a re-read status of .notDetermined must not be treated as a final "
                             + "denial: the presenter has to ask macOS for permission again; "
                             + "requests before reset=\(requestsBeforeReset) after=\(system.requestCount) "
                             + "authState=\(presenter.authState) centre calls: \(system.callLog)")
        XCTAssertEqual(system.deliveredToUser.filter { (item: UndeterminedDelivery) -> Bool in item == third },
                       [third],
                       "after the user allowed the re-asked prompt the later notification must be "
                       + "delivered exactly once; delivered=\(system.deliveredToUser) "
                       + "authState=\(presenter.authState) centre calls: \(system.callLog)")
        XCTAssertEqual(system.addAttempts, system.deliveredToUser,
                       "nothing may be handed to add() while macOS has not authorized; "
                       + "attempts=\(system.addAttempts) delivered=\(system.deliveredToUser)")
    }
}

// MARK: - Fake macOS notification system

private struct UndeterminedDelivery: Equatable, CustomStringConvertible {
    let title: String
    let body: String
    var description: String { "(\(title) | \(body))" }
}

/// What macOS does when `requestAuthorization` is called while the status is
/// `.notDetermined`.
private enum PromptOutcome: String, Equatable {
    /// The request fails (XPC hiccup); macOS records no decision.
    case transientError
    /// The user clicks Allow.
    case allow
    /// The user clicks Don't Allow.
    case deny
}

private struct UndeterminedRigError: Error, CustomStringConvertible {
    let description: String
}

/// Thread-safe model of macOS's permission switch and of what reached the user.
/// Completion handlers are invoked from a background queue, like the real
/// centre's XPC replies.
private final class UndeterminedFakeSystem: @unchecked Sendable {
    static let shared = UndeterminedFakeSystem()

    private let lock = NSLock()
    private var status: UNAuthorizationStatus = .notDetermined
    private var plan: [PromptOutcome] = []
    private var outcomes: [PromptOutcome] = []
    private var requests = 0
    private var attempts: [UndeterminedDelivery] = []
    private var delivered: [UndeterminedDelivery] = []
    private var calls: [String] = []
    private weak var storedDelegate: (any UNUserNotificationCenterDelegate)?

    /// Kept alive for the whole process (the instance is made without Swift's
    /// initializer chain, so it must never be deallocated).
    private(set) lazy var center: UndeterminedFakeCenter = {
        guard let made = class_createInstance(UndeterminedFakeCenter.self, 0) as? UndeterminedFakeCenter else {
            fatalError("could not instantiate UndeterminedFakeCenter")
        }
        return made
    }()

    func reset(status: UNAuthorizationStatus, plan: [PromptOutcome]) {
        lock.lock(); defer { lock.unlock() }
        self.status = status
        self.plan = plan
        outcomes = []
        requests = 0
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

    /// Resolves one `requestAuthorization` call. Against an undetermined status
    /// the next scripted outcome applies (default: the user allows); against a
    /// decided status macOS shows nothing and just reports the decision.
    func resolveRequest() -> (granted: Bool, failed: Bool) {
        lock.lock(); defer { lock.unlock() }
        requests += 1
        guard status == .notDetermined else {
            let granted = status == .authorized
            calls.append("requestAuthorization#\(requests) status=\(status.rawValue) -> no prompt, granted=\(granted)")
            return (granted, false)
        }
        let outcome = plan.isEmpty ? PromptOutcome.allow : plan.removeFirst()
        outcomes.append(outcome)
        switch outcome {
        case .transientError:
            calls.append("requestAuthorization#\(requests) status=0 -> prompt outcome=transientError")
            return (false, true)
        case .allow:
            status = .authorized
            calls.append("requestAuthorization#\(requests) status=0 -> prompt outcome=allow")
            return (true, false)
        case .deny:
            status = .denied
            calls.append("requestAuthorization#\(requests) status=0 -> prompt outcome=deny")
            return (false, false)
        }
    }

    /// What `UNUserNotificationCenter.add` was asked to post. Anything added
    /// while permission is not authorized is silently discarded by macOS, so
    /// it never counts as delivered.
    func recordAdd(title: String, body: String) {
        lock.lock(); defer { lock.unlock() }
        let item = UndeterminedDelivery(title: title, body: body)
        attempts.append(item)
        if status == .authorized { delivered.append(item) }
        calls.append("add(\(item))@status=\(status.rawValue)")
    }

    var requestCount: Int {
        lock.lock(); defer { lock.unlock() }
        return requests
    }

    var promptOutcomes: [PromptOutcome] {
        lock.lock(); defer { lock.unlock() }
        return outcomes
    }

    var addAttempts: [UndeterminedDelivery] {
        lock.lock(); defer { lock.unlock() }
        return attempts
    }

    var deliveredToUser: [UndeterminedDelivery] {
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
private final class UndeterminedFakeSettings: UNNotificationSettings {
    var snapshotRawStatus: Int = 0

    static func make(status: UNAuthorizationStatus) -> UndeterminedFakeSettings {
        guard let made = class_createInstance(UndeterminedFakeSettings.self, 0) as? UndeterminedFakeSettings else {
            fatalError("could not instantiate UndeterminedFakeSettings")
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
private final class UndeterminedFakeCenter: UNUserNotificationCenter {
    private var system: UndeterminedFakeSystem { UndeterminedFakeSystem.shared }

    override var delegate: (any UNUserNotificationCenterDelegate)? {
        get { system.delegate }
        set { system.record("setDelegate"); system.delegate = newValue }
    }

    override func requestAuthorization(
        options: UNAuthorizationOptions = [],
        completionHandler: @escaping @Sendable (Bool, (any Error)?) -> Void
    ) {
        let resolved = system.resolveRequest()
        DispatchQueue.global(qos: .userInitiated).async {
            if resolved.failed {
                // NSXPCConnectionInterrupted: a realistic transient failure.
                let error = NSError(domain: NSCocoaErrorDomain, code: 4097, userInfo: nil)
                completionHandler(false, error)
            } else {
                completionHandler(resolved.granted, nil)
            }
        }
    }

    override func getNotificationSettings(
        completionHandler: @escaping @Sendable (UNNotificationSettings) -> Void
    ) {
        let status = system.currentStatus()
        system.record("getNotificationSettings -> status=\(status.rawValue)")
        nonisolated(unsafe) let settings = UndeterminedFakeSettings.make(status: status)
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
private enum UndeterminedCenterSeam {
    static func install(_ fake: UndeterminedFakeCenter) throws -> () -> Void {
        let selector = NSSelectorFromString("currentNotificationCenter")
        guard let method = class_getClassMethod(UNUserNotificationCenter.self, selector) else {
            throw UndeterminedRigError(description: "rig: +currentNotificationCenter not found")
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
            throw UndeterminedRigError(description: "rig: UNUserNotificationCenter.current() is not the fake centre")
        }
        return restore
    }
}
