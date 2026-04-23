import SwiftUI
import AppKit
import Combine
import QuartzCore
import Sparkle
import os

/// Traditional AppKit entry point. We don't use a SwiftUI `App` because the
/// only scene we'd declare is `Settings { … }` — and that scene registers a
/// hidden handler that intercepts ⌘, at the app level, opening SwiftUI's
/// own (blank) Settings window instead of the custom AppKit one we built in
/// `SettingsWindowController`. Removing the SwiftUI App wrapper removes the
/// interception; AppDelegate drives the whole lifecycle.
@main
enum BlackbirdMain {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.run()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {

    private var controllers: [MainWindowController] = []

    /// Sparkle updater — present ONLY when the app is properly configured
    /// for auto-updates (real `SUFeedURL` and `SUPublicEDKey` set in
    /// Info.plist). On a dev build the Info.plist ships placeholders, which
    /// would otherwise cause `SPUStandardUpdaterController` to fail during
    /// init and show the "Unable to Check For Updates" alert on every
    /// launch. We refuse to instantiate until the config is real — the
    /// updater comes to life the moment we paste in a real appcast URL
    /// and EdDSA public key and rebuild, without any further code change.
    private lazy var updaterController: SPUStandardUpdaterController? = {
        guard Self.isUpdaterConfigured else { return nil }
        let ctrl = SPUStandardUpdaterController(
            startingUpdater: false,       // don't auto-start — we flip the
                                          // switch below after setting the
                                          // user's preference.
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        ctrl.updater.automaticallyChecksForUpdates = Preferences.shared.autoUpdateChecks
        ctrl.startUpdater()
        return ctrl
    }()

    /// True when Info.plist has a non-placeholder SUFeedURL and a non-empty
    /// SUPublicEDKey (both required by Sparkle 2.x). Kept here so the whole
    /// Sparkle integration is a single gate — flip the config values and
    /// every dependent path lights up. Exposed so `SettingsView` can gate
    /// its "Check for Updates Now" button on the same condition that
    /// decides whether the app-menu item is installed.
    static var isUpdaterConfigured: Bool {
        let feed = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String ?? ""
        let key = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String ?? ""
        let placeholder = feed.isEmpty
            || feed.contains("example.com")
            || key.isEmpty
        return !placeholder
    }

    private var autoUpdateObserver: AnyCancellable?

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    /// ⌘Q goes through here before any window-close notification fires. Show a
    /// single "processes are running" alert if confirmClose is on and any tab
    /// has a foreground child; then suppress the per-tab confirms for the
    /// rest of the termination so the user doesn't click through one alert
    /// per tab.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard Preferences.shared.confirmClose else { return .terminateNow }
        let running = controllers
            .compactMap { $0.session }
            .filter { $0.hasForegroundChild() }
        guard !running.isEmpty else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = running.count == 1
            ? "Quit with a process still running?"
            : "Quit with \(running.count) processes still running?"
        alert.informativeText = "Every open shell session will be terminated."
        alert.addButton(withTitle: "Quit")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning
        if alert.runModal() == .alertSecondButtonReturn {
            return .terminateCancel
        }
        // User consented — skip the per-tab "process is still running" alert.
        MainWindowController.bypassCloseConfirm = true
        // Reset on the next runloop tick so the flag doesn't stick true
        // forever if termination is later cancelled by a downstream save /
        // document prompt. AppKit's batch-close sweep after `.terminateNow`
        // runs synchronously on this same tick, so the bypass is still in
        // force for every `windowShouldClose` callback triggered by the
        // sweep; the async hop then clears the flag once the current
        // runloop iteration drains. (main-window F5)
        DispatchQueue.main.async {
            MainWindowController.bypassCloseConfirm = false
        }
        return .terminateNow
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        ThemeManager.shared.attach(toApp: NSApp)

        let underTest =
            ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            || ProcessInfo.processInfo.environment["XCTestSessionIdentifier"] != nil
            || ProcessInfo.processInfo.environment["XCTestBundlePath"] != nil
            || NSClassFromString("XCTestCase") != nil

        if underTest {
            // Safety net: under XCTest, force-exit after 60s so a missed
            // testBundleDidFinish observer or a hung test can't keep the host
            // process alive indefinitely.
            DispatchQueue.main.asyncAfter(deadline: .now() + 60) {
                exit(0)
            }
            return
        }

        // Normal (non-test) launch: open the main window with a shell session.
        // Replace Sparkle's verbose "up to date" alert before any updater
        // session can spin up (scheduled check, menu action, etc.).
        SparkleAlertOverride.install()
        // Main-thread hang detector. Only the DEFAULT flips between
        // build flavours — the env var's meaning is consistent across
        // both: "1" forces on, "0" forces off, unset falls back to the
        // build default. Debug = default-on (devs want the signal);
        // Release = default-off (production users shouldn't quietly
        // gather diagnostics). Any main-thread hang ≥ 0.5 s writes a
        // sampled stack under `~/Library/Logs/Blackbird/hang-<ts>.txt`.
        let hangEnv = ProcessInfo.processInfo.environment["BB_HANG_WATCHDOG"]
        #if DEBUG
        let installWatchdog = (hangEnv != "0")
        #else
        let installWatchdog = (hangEnv == "1")
        #endif
        if installWatchdog { MainThreadWatchdog.install() }
        installMainMenu()
        installSparkleMenuItem()
        // Live-toggle Sparkle's auto-check when the pref changes, so the
        // Settings > Updates toggle takes effect without relaunching. No-op
        // when the updater isn't configured (dev builds); the Preferences
        // observer still fires, it just hits a nil controller.
        //
        // INFINITE-FEEDBACK-LOOP HAZARD — the reason for the same-value guard
        // below:
        //   1. writing `automaticallyChecksForUpdates` calls Sparkle's
        //      SUHost.setBool:forUserDefaultsKey: → UserDefaults write
        //   2. the write fires NSUserDefaultsDidChangeNotification (synchronously,
        //      via CoreFoundation)
        //   3. SwiftUI's GLOBAL UserDefaultObserver is listening for that
        //      notification (it backs @AppStorage). It bridges EVERY
        //      UserDefaults change (not just our `bb.*` keys) into an
        //      Update.enqueueAction that fires objectWillChange on every
        //      subscribed ObservableObject — including `Preferences.shared`.
        //   4. our own sink (this closure) re-fires on Preferences.shared's
        //      objectWillChange and writes Sparkle again → back to step 1.
        //
        // Each iteration allocates a `DispatchQueue.main.async` block; the
        // main queue piles up enqueue-self blocks until the process OOMs.
        // This was the real cause of the reported "Settings click freezes
        // the app / beachballs" — the Settings window wasn't the bug site,
        // our Sparkle-bridging observer was.
        //
        // The guard: only write when Sparkle's current state disagrees with
        // our desired state. On the first real change (user toggles the
        // pref) we write once; the re-triggered sink immediately sees the
        // values match and skips, breaking the loop.
        autoUpdateObserver = Preferences.shared.objectWillChange
            .sink { [weak self] _ in
                DispatchQueue.main.async {
                    guard let ctrl = self?.updaterController else { return }
                    let desired = Preferences.shared.autoUpdateChecks
                    guard ctrl.updater.automaticallyChecksForUpdates != desired else { return }
                    ctrl.updater.automaticallyChecksForUpdates = desired
                }
            }
        // First-launch window has no source session to inherit from, so
        // pass the ⌘N "fresh start" cwd (nil → $HOME). Same policy.
        let controller = createTerminalController(cwd: CwdResolver.forNewWindow())
        controller.showWindow(nil)
    }

    /// Inserts a "Check for Updates…" item into the app submenu right after
    /// "About Blackbird". Target is the Sparkle controller so the standard
    /// `checkForUpdates(_:)` selector is dispatched correctly. Kept separate
    /// from `buildAppMenu()` because `updaterController` is lazy and tests
    /// shouldn't trigger it.
    private func installSparkleMenuItem() {
        // Only show the menu entry when the updater is actually usable. A
        // visible "Check for Updates…" that pops an "Unable to check" alert
        // every time is worse than no menu item at all — users either click
        // it expecting a check (and get an error) or avoid it for fear of
        // hitting that error again. Hide until we ship real appcast config.
        guard let controller = updaterController else { return }
        guard
            let firstItem = NSApp.mainMenu?.items.first,
            let appSubmenu = firstItem.submenu
        else { return }
        let checkItem = NSMenuItem(
            title: "Check for Updates…",
            action: #selector(SPUStandardUpdaterController.checkForUpdates(_:)),
            keyEquivalent: ""
        )
        checkItem.target = controller
        appSubmenu.insertItem(checkItem, at: 1)
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Release any still-held EnableSecureEventInput refcount before
        // tearing down sessions. macOS auto-releases on process exit in
        // the normal path, but a pending alert or slow shell teardown
        // can keep the process alive past the point where deinit would
        // run, and secure-input-mode stuck on is painful system-wide
        // (other apps stop seeing keyboard events until it drains). Walk
        // every terminal view and explicitly call the disable path.
        // Audit terminal-view-1 F16.
        for controller in controllers {
            if let view = controller.terminalView {
                view.disableSecureEventInputIfHeld()
            }
        }
        controllers.forEach { $0.terminateSessions() }
        controllers.removeAll()
    }

    /// macOS 14+ emits a runtime warning on launch when the delegate
    /// doesn't implement this. Blackbird doesn't use state restoration
    /// (no Restorable flag on any window), so the answer is simply
    /// "yes, our zero state is secure by definition." Audit app-entry F2.
    func applicationSupportsSecureRestorableState(
        _ app: NSApplication
    ) -> Bool {
        true
    }

    @objc func openSettings(_ sender: Any?) {
        // AppKit-hosted settings window — see SettingsWindowController for
        // why we don't rely on SwiftUI's `Settings { … }` scene wiring.
        SettingsWindowController.shared.show()
    }

    /// Responder-chain entry point for the Settings window's "Check for
    /// Updates Now" button. The button uses NSApp.sendAction with a nil
    /// target; AppDelegate is in the responder chain so this selector is
    /// reached without the button needing a direct reference to the
    /// private `updaterController`. No-op when the updater isn't
    /// configured (dev builds on placeholder Info.plist) — matches the
    /// menu item's behavior.
    @objc func checkForUpdatesFromUI(_ sender: Any?) {
        updaterController?.checkForUpdates(sender)
    }

    // MARK: - Controller factory

    @discardableResult
    private func createTerminalController(
        cwd: String?,
        autosaveFrame: Bool = true
    ) -> MainWindowController {
        let controller = MainWindowController(
            initialWorkingDirectory: cwd,
            autosaveFrame: autosaveFrame
        )
        controller.onClose = { [weak self, weak controller] in
            guard let self, let controller else { return }
            self.controllers.removeAll { $0 === controller }
            // Dropping a tab shrinks the group — repaint all remaining
            // tabs' pill strips. If the last tab in the group closed,
            // nothing to refresh here anyway.
            DispatchQueue.main.async { [weak self] in
                self?.refreshAllTabBars()
            }
        }
        controllers.append(controller)
        return controller
    }

    /// Find the currently-foregrounded Blackbird terminal controller, if any.
    /// Walks our controller list rather than trusting `NSApp.keyWindow`, which
    /// may point at the Settings window or a non-Blackbird window.
    private var activeTerminalController: MainWindowController? {
        if let keyWindow = NSApp.keyWindow,
           let match = controllers.first(where: { $0.window === keyWindow }) {
            return match
        }
        // Fallback: last-focused Blackbird window. `orderedIndex` is lower
        // for more recently used windows.
        return controllers
            .compactMap { $0 }
            .filter { $0.window != nil }
            .sorted { ($0.window?.orderedIndex ?? .max) < ($1.window?.orderedIndex ?? .max) }
            .first
    }

    // MARK: - Tab / window actions

    /// Called by the tab bar "+" button and by the ⌘T menu item. New tabs
    /// inherit the previous tab's cwd so ⌘T inside `~/projects/foo` lands
    /// in `~/projects/foo`, matching Terminal.app / iTerm2.
    @objc func newWindowForTab(_ sender: Any?) {
        let t0 = CACurrentMediaTime()
        let source = activeTerminalController
        let controller = createTerminalController(
            cwd: CwdResolver.forNewTab(source: source?.session),
            autosaveFrame: false   // tabs use the group's position
        )
        let tCreate = CACurrentMediaTime()
        if StartupTelemetry.isEnabled {
            StartupTelemetry.logger.log(
                "newWindowForTab: controller_init=\(((tCreate - t0) * 1000), format: .fixed(precision: 1), privacy: .public)ms"
            )
        }
        guard let newWindow = controller.window else { return }
        if let sourceWindow = source?.window {
            // addTabbedWindow(_:ordered:) orders-front and makes-key as a
            // side effect — no separate showWindow / makeKeyAndOrderFront
            // needed. Doing both was causing a brief standalone-window
            // flash before the merge on some launches.
            sourceWindow.addTabbedWindow(newWindow, ordered: .above)
        } else {
            // No existing Blackbird window — fall back to a standalone.
            controller.showWindow(nil)
        }
        newWindow.makeKeyAndOrderFront(nil)
        // Tell every controller in the group to refresh its custom tab
        // bar. NSWindowTabGroup's `.windows` property is not reliably
        // KVO-fireable on tab-add, so we invalidate explicitly.
        DispatchQueue.main.async { [weak self] in
            self?.refreshAllTabBars()
        }
    }

    /// Re-run `refreshTabBar` on every MainWindowController so the pill
    /// strip matches the current tab group. Used after tab-add / -close
    /// since NSWindowTabGroup KVO isn't reliable.
    private func refreshAllTabBars() {
        for c in controllers { c.refreshTabBar() }
    }

    /// Opens a new independent window (⌘N). Per spec §3, ⌘N is a *fresh
    /// start* — always spawns at `$HOME`, never inherits the active tab's
    /// cwd. That's the behavioural contrast with ⌘T (which does inherit).
    /// Never merges into a tab group either.
    @objc func newWindow(_ sender: Any?) {
        let controller = createTerminalController(
            cwd: CwdResolver.forNewWindow(),
            autosaveFrame: false
        )
        // Default `tabbingMode = .preferred` would let macOS auto-merge this
        // into the existing tab group when the user's system "Prefer Tabs"
        // setting is "Always" (or "In Full Screen" while fullscreen). ⌘N
        // must *always* produce a separate window — flip to .disallowed for
        // this specific window before showing. ⌘T stays on the sibling
        // newWindowForTab path, which uses `addTabbedWindow` explicitly and
        // isn't subject to the tabbingMode check.
        controller.window?.tabbingMode = .disallowed
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
    }

    /// Selects a numbered tab (⌘1–⌘9). Tag encodes the 1-based index.
    @objc func selectTab(_ sender: NSMenuItem) {
        guard let window = NSApp.keyWindow else { return }
        let tabs = window.tabbedWindows ?? [window]
        let index = sender.tag - 1
        guard index < tabs.count else { return }
        tabs[index].makeKeyAndOrderFront(nil)
    }

    /// Closes every tab in the key window. Shows a confirmation alert when
    /// there are multiple tabs so the user can't accidentally nuke all sessions.
    @objc func closeWindow(_ sender: Any?) {
        guard let window = NSApp.keyWindow else { return }
        let tabs = window.tabbedWindows ?? [window]
        if tabs.count > 1 {
            let alert = NSAlert()
            alert.messageText = "Close \(tabs.count) tabs?"
            alert.informativeText = "All shell sessions in this window will be terminated."
            alert.addButton(withTitle: "Close")
            alert.addButton(withTitle: "Cancel")
            alert.alertStyle = .warning
            if alert.runModal() == .alertSecondButtonReturn { return }
        }
        // Suppress the per-tab "process is still running" confirm for this
        // sweep — the multi-tab alert above already covered consent. Without
        // this, closing two tabs with running commands would pop an extra
        // alert per tab.
        MainWindowController.bypassCloseConfirm = true
        defer { MainWindowController.bypassCloseConfirm = false }
        for tab in tabs {
            tab.performClose(nil)
        }
    }

}
