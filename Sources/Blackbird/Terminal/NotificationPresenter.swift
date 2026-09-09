import AppKit
import Foundation
import UserNotifications
import os

/// A program-originated notification (OSC 9 iTerm2 form, OSC 777
/// `;notify;title;body`, kitty OSC 99) after the core scrubbed control
/// characters and capped the lengths.
public struct TerminalNotification: Equatable {
    public let title: String
    public let body: String
    public init(title: String, body: String) {
        self.title = title
        self.body = body
    }
}

/// When a bell or notification from a session should reach the user
/// through means other than the tab's own surface. Pure; the view feeds
/// it the live AppKit state.
enum AttentionPolicy {
    /// True unless the user is already looking at exactly this tab: the
    /// app is active, its window is key, and the tab is the group's
    /// selected one. Every peer terminal (iTerm2, kitty, Ghostty) applies
    /// the same "not if you're already here" rule.
    static func needsAttention(appActive: Bool, windowKey: Bool, tabSelected: Bool) -> Bool {
        !(appActive && windowKey && tabSelected)
    }
}

/// Posts user notifications for OSC 9 / 777 / 99 and bells that arrive
/// while the user is elsewhere. `UNUserNotificationCenter` is only
/// reachable from a real app bundle, so an xctest host (no bundle
/// identifier of its own, or the XCTest environment marker) records the
/// request instead of posting; tests read `posted`.
final class NotificationPresenter {
    static let shared = NotificationPresenter()

    private static let logger = Logger(subsystem: "dev.conjfrnk.blackbird", category: "notifications")

    /// Notifications this presenter was asked to post, newest last. Bounded
    /// so a chatty program can't grow it without limit.
    private(set) var posted: [TerminalNotification] = []
    private static let postedCap = 64

    /// Whether the system notification centre can be used from this
    /// process. Evaluated once; the answer cannot change at run time.
    let isSystemCenterAvailable: Bool

    private var authorizationRequested = false

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
    }

    /// Post (or record) a notification. Main thread.
    func post(_ notification: TerminalNotification) {
        dispatchPrecondition(condition: .onQueue(.main))
        posted.append(notification)
        if posted.count > Self.postedCap {
            posted.removeFirst(posted.count - Self.postedCap)
        }
        guard isSystemCenterAvailable else { return }
        let center = UNUserNotificationCenter.current()
        let deliver = { [weak self] in
            let content = UNMutableNotificationContent()
            content.title = notification.title.isEmpty ? "Blackbird" : notification.title
            content.body = notification.body
            content.sound = .default
            let request = UNNotificationRequest(
                identifier: "bb-\(UUID().uuidString)",
                content: content,
                trigger: nil
            )
            center.add(request) { error in
                if let error {
                    Self.logger.error("UNUserNotificationCenter.add failed: \(error.localizedDescription, privacy: .public)")
                }
            }
            _ = self
        }
        if authorizationRequested {
            deliver()
            return
        }
        authorizationRequested = true
        center.requestAuthorization(options: [.alert, .sound]) { granted, error in
            if let error {
                Self.logger.error("notification authorization failed: \(error.localizedDescription, privacy: .public)")
            }
            guard granted else {
                Self.logger.log("notification authorization denied; program notifications will not be shown")
                return
            }
            DispatchQueue.main.async(execute: deliver)
        }
    }

    #if DEBUG
    func _resetForTests() { posted = [] }
    #endif
}
