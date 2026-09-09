import AppKit
import Foundation
import UserNotifications
import os

/// A program-originated notification (OSC 9 iTerm2 form, OSC 777
/// `;notify;title;body`, kitty OSC 99) after the core scrubbed control
/// characters and capped the lengths. The core never emits one with both
/// halves empty; the view fills an empty title with the tab title before
/// posting, so a presented notification always has a title.
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

/// Posts user notifications for OSC 9 / 777 / 99 that arrive while the
/// user is elsewhere. `UNUserNotificationCenter` is only reachable from a
/// real app bundle, so an xctest host (no bundle identifier of its own, or
/// the XCTest environment marker) records the request instead of posting;
/// tests read `posted`.
///
/// The presenter is the centre's delegate so that a notification posted
/// while Blackbird is the ACTIVE app (another tab or window has the
/// user's attention — the common "Claude Code finished in a background
/// tab" case) still shows a banner: without `willPresent` macOS files a
/// foreground app's notification silently into the list. Clicking a
/// banner selects the originating tab.
final class NotificationPresenter: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationPresenter()

    private static let logger = Logger(subsystem: "dev.conjfrnk.blackbird", category: "notifications")

    /// Notifications this presenter was asked to post, newest last. Bounded
    /// so a chatty program can't grow it without limit.
    private(set) var posted: [TerminalNotification] = []
    private static let postedCap = 64

    /// Whether the system notification centre can be used from this
    /// process. Evaluated once; the answer cannot change at run time.
    let isSystemCenterAvailable: Bool

    /// Authorization is a three-state affair: unknown until asked, pending
    /// while the permission prompt is up, then granted or denied. Posting
    /// during `pending` used to call `add` unauthorized and lose the
    /// notification; posting after `denied` kept calling `add` and logging.
    enum AuthState: Equatable { case unknown, pending, granted, denied }
    private(set) var authState: AuthState = .unknown
    /// Notifications that arrived while the prompt was up; delivered on
    /// grant, dropped on denial. Bounded like `posted`.
    private var queuedWhilePending: [(TerminalNotification, Int?)] = []
    private static let queueCap = 16

    /// `userInfo` key carrying the originating window number so a click
    /// on the banner can select that tab.
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

    /// Post (or record) a notification. Main thread. `windowNumber` is the
    /// originating tab's `NSWindow.windowNumber`, selected when the banner
    /// is clicked.
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
            // Logged once at denial time; nothing more to say per post.
            return
        case .pending:
            queuedWhilePending.append((notification, windowNumber))
            if queuedWhilePending.count > Self.queueCap {
                queuedWhilePending.removeFirst(queuedWhilePending.count - Self.queueCap)
            }
        case .unknown:
            authState = .pending
            queuedWhilePending = [(notification, windowNumber)]
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { [weak self] granted, error in
                DispatchQueue.main.async {
                    guard let self else { return }
                    if let error {
                        Self.logger.error("notification authorization failed: \(error.localizedDescription, privacy: .public)")
                    }
                    let queued = self.queuedWhilePending
                    self.queuedWhilePending = []
                    if granted {
                        self.authState = .granted
                        for (n, w) in queued { self.deliver(n, windowNumber: w) }
                    } else {
                        self.authState = .denied
                        Self.logger.log("notification authorization denied; \(queued.count, privacy: .public) queued program notification(s) dropped and later ones will not be shown (System Settings → Notifications → Blackbird)")
                    }
                }
            }
        }
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

    /// Show the banner even while Blackbird is the active app: the policy
    /// that decided to post already knows the user is on another tab or
    /// window.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list, .sound])
    }

    /// A click on the banner selects the originating tab.
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
