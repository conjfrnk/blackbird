import AppKit
import Foundation
import UserNotifications
import os

public struct TerminalNotification: Equatable {
    public let title: String
    public let body: String
    public init(title: String, body: String) {
        self.title = title
        self.body = body
    }
}

enum AttentionPolicy {
    static func needsAttention(appActive: Bool, windowKey: Bool, tabSelected: Bool) -> Bool {
        !(appActive && windowKey && tabSelected)
    }
}

/// `UNUserNotificationCenter` is only reachable from a real app bundle; an xctest host records into `posted` instead.
/// Must be the centre's delegate: without `willPresent`, macOS files a foreground app's notification silently into the list.
final class NotificationPresenter: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationPresenter()

    private static let logger = Logger(subsystem: "dev.conjfrnk.blackbird", category: "notifications")

    private(set) var posted: [TerminalNotification] = []
    private static let postedCap = 64

    let isSystemCenterAvailable: Bool

    /// `pending` while the permission prompt is up or a post re-reads the status after a denial.
    enum AuthState: Equatable { case unknown, pending, granted, denied }
    private(set) var authState: AuthState = .unknown
    private var queuedWhilePending: [(TerminalNotification, Int?)] = []
    private static let queueCap = 16

    static let windowNumberKey = "bb.windowNumber"

    init(systemCenterAvailable: Bool? = nil) {
        if let forced = systemCenterAvailable {
            isSystemCenterAvailable = forced
        } else {
            let env = ProcessInfo.processInfo.environment
            let underXCTest = env["XCTestConfigurationFilePath"] != nil
                || env["XCTestBundlePath"] != nil
                || NSClassFromString("XCTestCase") != nil
            isSystemCenterAvailable = Bundle.main.bundleIdentifier != nil && !underXCTest
        }
        super.init()
        if isSystemCenterAvailable {
            UNUserNotificationCenter.current().delegate = self
        }
    }

    func post(_ notification: TerminalNotification, windowNumber: Int? = nil) {
        dispatchPrecondition(condition: .onQueue(.main))
        posted.append(notification)
        if posted.count > Self.postedCap {
            posted.removeFirst(posted.count - Self.postedCap)
        }
        guard isSystemCenterAvailable else { return }
        switch authState {
        case .granted:
            deliver(notification, windowNumber: windowNumber)
        case .denied:
            // The user can flip the permission in System Settings while we run, so re-read the live
            // status before dropping. `.pending` queues posts racing the async reply behind this one.
            authState = .pending
            queuedWhilePending = [(notification, windowNumber)]
            UNUserNotificationCenter.current().getNotificationSettings { [weak self] settings in
                let status = settings.authorizationStatus
                DispatchQueue.main.async {
                    guard let self else { return }
                    switch status {
                    case .authorized, .provisional, .ephemeral:
                        self.settlePending(.granted)
                    case .notDetermined:
                        // macOS holds no decision (the user reset the permission), so ask again.
                        self.requestAuthorization()
                    default:
                        self.settlePending(.denied)
                    }
                }
            }
        case .pending:
            queuedWhilePending.append((notification, windowNumber))
            if queuedWhilePending.count > Self.queueCap {
                queuedWhilePending.removeFirst(queuedWhilePending.count - Self.queueCap)
            }
        case .unknown:
            authState = .pending
            queuedWhilePending = [(notification, windowNumber)]
            requestAuthorization()
        }
    }

    /// Main thread, in `.pending` with the triggering notification queued.
    private func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { [weak self] granted, error in
            DispatchQueue.main.async {
                guard let self else { return }
                if let error {
                    Self.logger.error("notification authorization failed: \(error.localizedDescription, privacy: .public)")
                }
                let dropped = self.queuedWhilePending.count
                if granted {
                    self.settlePending(.granted)
                } else if error != nil {
                    // A failed request records no decision with macOS; latching a denial
                    // would mute notifications until relaunch.
                    self.settlePending(.unknown)
                    Self.logger.log("notification authorization request failed; \(dropped, privacy: .public) queued program notification(s) dropped, the next one asks again")
                } else {
                    self.settlePending(.denied)
                    Self.logger.log("notification authorization denied; \(dropped, privacy: .public) queued program notification(s) dropped; later ones are re-checked against System Settings → Notifications → Blackbird and shown once it is enabled")
                }
            }
        }
    }

    private func settlePending(_ state: AuthState) {
        let queued = queuedWhilePending
        queuedWhilePending = []
        authState = state
        guard state == .granted else { return }
        for (n, w) in queued { deliver(n, windowNumber: w) }
    }

    private func deliver(_ notification: TerminalNotification, windowNumber: Int?) {
        let content = UNMutableNotificationContent()
        content.title = notification.title.isEmpty ? "Blackbird" : notification.title
        content.body = notification.body
        content.sound = .default
        if let windowNumber {
            content.userInfo = [Self.windowNumberKey: windowNumber]
        }
        let request = UNNotificationRequest(
            identifier: "bb-\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                Self.logger.error("UNUserNotificationCenter.add failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    // MARK: - UNUserNotificationCenterDelegate

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list, .sound])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        defer { completionHandler() }
        guard let number = response.notification.request.content.userInfo[Self.windowNumberKey] as? Int else { return }
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
            if let window = NSApp.window(withWindowNumber: number) {
                window.tabGroup?.selectedWindow = window
                window.makeKeyAndOrderFront(nil)
            }
        }
    }

    #if DEBUG
    func _resetForTests() {
        posted = []
        queuedWhilePending = []
        authState = .unknown
    }
    #endif
}
