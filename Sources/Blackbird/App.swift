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

    /// Diagnostics for the menu / responder-chain action plumbing.
    /// NOT gated on `#if DEBUG`: the leakage-class bug this is a canary
    /// for (⌘⇧W flipping `bypassCloseConfirm` while a non-Blackbird window
    /// is key, allowing a nested-modal in the Settings close path to
    /// silently bypass per-tab close confirmation in another
    /// MainWindowController) is field-undiagnosable in Release without a
    /// breadcrumb. Same Release-diagnosability rationale as `tabsLogger`
    /// / `focusLogger` (audit H-2 / M-4 / M-5). H-9 leak class.
    private static let menuLogger = Logger(subsystem: "dev.conjfrnk.blackbird",
                                           category: "menu")

    /// Returns the current key window if it's owned by Blackbird (a
    /// `MainWindowController` we track), else nil. Single chokepoint
    /// shared by `validateMenuItem` (menu-driven dispatch) AND the
    /// action implementations (programmatic / AppleScript /
    /// `NSApp.sendAction` paths) so the gating is identical at every
    /// entry point. `validateMenuItem` is consulted only for menu
    /// dispatch, so without this guard inside the action bodies a
    /// programmatic `closeWindow(_:)` call while Settings is keyWindow
    /// would still flip `MainWindowController.bypassCloseConfirm` and
    /// leak the bypass into a nested-modal sibling controller's
    /// `windowShouldClose`. (audit H-9, Pragmatic DRY.)
    private func ownedKeyWindow() -> NSWindow? {
        guard let win = NSApp.keyWindow,
              controllers.contains(where: { $0.window === win }) else { return nil }
        return win
    }

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

    /// Lifetime-owns the `TabOrderCoordinator.orderDidChange` observer
    /// installed in `applicationDidFinishLaunching`. Stored so the
    /// closure that refreshes every controller's pill strip on a
    /// drag-reorder doesn't get released the runloop tick after install.
    private var tabOrderObserver: NSObjectProtocol?

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
        // The flag stays true through AppKit's synchronous batch-close
        // sweep that follows `.terminateNow`, then is cleared in
        // `applicationWillTerminate` (audit L10). The previous async-
        // hop reset relied on no future delegate cancelling termination
        // after `.terminateNow`; the synchronous reset in willTerminate
        // is robust against that hypothetical and avoids leaving an
        // async closure pending against a half-torn-down process.
        MainWindowController.bypassCloseConfirm = true
        return .terminateNow
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        ThemeManager.shared.attach(toApp: NSApp)

        // Ignore SIGPIPE process-wide. Without this, a write() racing PTY
        // slave close (or any closed pipe) delivers SIGPIPE → SIG_DFL →
        // app death. The child resets SIGPIPE to SIG_DFL for itself in
        // PTY.swift after fork, so subprocesses retain default semantics.
        signal(SIGPIPE, SIG_IGN)

        let underTest =
            ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            || ProcessInfo.processInfo.environment["XCTestSessionIdentifier"] != nil
            || ProcessInfo.processInfo.environment["XCTestBundlePath"] != nil
            || NSClassFromString("XCTestCase") != nil

        if underTest {
            // Safety net (reworked per audit S2-004): under XCTest,
            // force-exit only when the bundle goes IDLE, so a missed
            // testBundleDidFinish observer or an abandoned host can't
            // linger — without killing healthy long runs. The previous
            // shape was an unconditional `asyncAfter(60) { exit(0) }`
            // with no cancellation: XCTest spins the main runloop
            // between tests, so any run whose wall clock passed 60 s
            // was shot mid-suite. xctest restarts the host (each
            // restart re-arming a fresh 60 s fuse), producing the
            // phantom exit-65 / "Failing tests: <none>" churn CI
            // documented in 0a8fbbc and a misleading failure blamed on
            // whichever test was in flight. TestHostTermination posts
            // an activity heartbeat at every test start/finish; this
            // monitor exits only after 300 s with no heartbeat — a
            // genuinely hung or abandoned host.
            TestHostActivityMonitor.shared.start()
            return
        }

        // Normal (non-test) launch: open the main window with a shell session.

        // Kick the kitty-terminfo resolution onto a background thread NOW,
        // before we build the menu / window / renderer. That work runs two
        // synchronous child-process round-trips (`tic` + `infocmp`) the
        // first time it's touched; left on the main thread it lands on the
        // first `PTY.spawn` and delays the first window's paint. Starting it
        // here lets it complete concurrently with the ~20 ms of renderer +
        // window construction below, so `PTY.spawn`'s read is (almost
        // always) a memoized no-op. Strictly safe — see
        // `PTY.prewarmKittyTerminfo()`'s `swift_once` rationale.
        PTY.prewarmKittyTerminfo()

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
        // S4-003 (2026-05-17): reap orphan hang-*.txt.partial siblings
        // left over from a prior session's force-quit during the
        // captureHangReport sample(1) window. These are invisible to
        // the Settings → Diagnostics .txt-only filter and would
        // otherwise accumulate silently in ~/Library/Logs/Blackbird/.
        // Called regardless of installWatchdog because the orphan is
        // from a PRIOR session that may have armed the watchdog even
        // if this session doesn't.
        //
        // Off the main thread: this enumerates ~/Library/Logs/Blackbird,
        // stats each entry, and creates the directory on first launch —
        // synchronous disk I/O that has no business on the cold-launch
        // critical path before the first window paints. It's pure
        // FileManager + os.Logger work (thread-safe) reaping files from a
        // PRIOR session, so it has no ordering dependency on this launch.
        // Backgrounding does NOT widen the (already-present) race with a
        // concurrent watchdog capture: the synchronous version ran right
        // after install() too. A capture-in-progress partial is always
        // younger than the prune's 60 s age gate, so it's skipped — that
        // freshness, not the thread it runs on, is what protects a live
        // partial.
        DispatchQueue.global(qos: .utility).async {
            MainThreadWatchdog.pruneOrphanPartials()
        }
        // `installMainMenu` builds the full menu tree (including the
        // conditional Sparkle "Check for Updates…" item via
        // `insertSparkleMenuItem(into:)`) BEFORE publishing it as the
        // app's main menu. Earlier this used to publish the menu first,
        // then mutate it to insert Sparkle — leaving a one-tick window
        // where a user mid-⌘ at launch could see an inconsistent menu
        // shape. (audit L-27)
        installMainMenu()
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
        // A drag-reorder in any window's pill strip commits the new
        // permutation to `TabOrderCoordinator` and posts a notification
        // (object = NSWindowTabGroup). Sibling tabs in the same group
        // need to repaint their strips so the visual order is consistent
        // across every member of the group; the simplest correct path is
        // to refresh every controller — refresh is keyed by tab group, so
        // unrelated windows are no-ops. Stored on the delegate so it
        // lives for the app's lifetime.
        tabOrderObserver = NotificationCenter.default.addObserver(
            forName: TabOrderCoordinator.orderDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.refreshAllTabBars()
        }
        // First-launch window has no source session to inherit from, so
        // pass the ⌘N "fresh start" cwd (nil → $HOME). Same policy.
        let controller = createTerminalController(cwd: CwdResolver.forNewWindow())
        controller.showWindow(nil)
    }

    /// Inserts a "Check for Updates…" item into the supplied app submenu
    /// right after "About Blackbird". Target is the Sparkle controller so
    /// the standard `checkForUpdates(_:)` selector is dispatched correctly.
    /// Kept separate from `buildAppMenu()` because `updaterController` is
    /// lazy and tests shouldn't trigger it.
    ///
    /// Called from `installMainMenu` BEFORE the menu is published as
    /// `NSApp.mainMenu`, so users mid-⌘ at launch can never observe a
    /// half-built menu shape. (audit L-27)
    func insertSparkleMenuItem(into appSubmenu: NSMenu) {
        // Only show the menu entry when the updater is actually usable. A
        // visible "Check for Updates…" that pops an "Unable to check" alert
        // every time is worse than no menu item at all — users either click
        // it expecting a check (and get an error) or avoid it for fear of
        // hitting that error again. Hide until we ship real appcast config.
        guard let controller = updaterController else { return }
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
        // Audit L10. AppKit's batch-close sweep ran synchronously between
        // `applicationShouldTerminate` returning `.terminateNow` and us
        // arriving here, so every per-tab `windowShouldClose` saw
        // `bypassCloseConfirm == true` as intended. Reset synchronously
        // before process exit so a hypothetical downstream delegate that
        // ever cancels termination doesn't leave the flag stuck on for
        // the rest of the session.
        MainWindowController.bypassCloseConfirm = false
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
        // Block creation-time auto-merge but revert to .preferred next tick so
        // this window can still receive tabs later (drag-merge / Merge All
        // Windows). Leaving it .disallowed permanently made ⌘N windows
        // un-mergeable for life. (F-S6-003)
        controller.disallowTabbingForCreationInstant()
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
    }

    /// Selects a numbered tab (⌘1–⌘9). Tag encodes the 1-based index.
    ///
    /// Sender is typed `Any?` to match the other AppDelegate selectors
    /// (`closeWindow`, `newWindow`, `newWindowForTab`, `openSettings`).
    /// A typed-Swift `NSMenuItem` parameter would still emit an @objc thunk
    /// that does an unconditional cast — a future custom-binding caller
    /// (e.g., a "record keyboard shortcut" feature) passing a non-NSMenuItem
    /// sender would trap. Cast inside the body and guard. (audit L-26)
    @objc func selectTab(_ sender: Any?) {
        guard let item = sender as? NSMenuItem else {
            Self.menuLogger.error(
                "selectTab: unexpected sender type \(String(describing: type(of: sender)), privacy: .public) — expected NSMenuItem"
            )
            return
        }
        // Programmatic / AppleScript / NSApp.sendAction paths bypass
        // `validateMenuItem`, so re-check Blackbird ownership here. (H-9)
        guard let window = ownedKeyWindow() else {
            Self.menuLogger.notice(
                "selectTab: no Blackbird-owned key window; ignoring tag=\(item.tag, privacy: .public)"
            )
            return
        }
        // Visual (pill) order, not AppKit's arrival order — see
        // TabOrderCoordinator. `tabbedWindows` is system order and would
        // route ⌘1-9 against the system permutation after the user has
        // dragged a pill, jumping to a tab whose pill sits elsewhere.
        let tabs: [NSWindow]
        if let group = window.tabGroup {
            tabs = TabOrderCoordinator.shared.orderedTabs(for: group)
        } else {
            tabs = [window]
        }
        let index = item.tag - 1
        guard index >= 0, index < tabs.count else {
            Self.menuLogger.debug(
                "selectTab: tag \(item.tag, privacy: .public) out of range (tabs=\(tabs.count, privacy: .public))"
            )
            return
        }
        tabs[index].makeKeyAndOrderFront(nil)
    }

    /// Closes every tab in the key window. Shows a confirmation alert when
    /// there are multiple tabs so the user can't accidentally nuke all sessions.
    @objc func closeWindow(_ sender: Any?) {
        // Programmatic / AppleScript / NSApp.sendAction paths bypass
        // `validateMenuItem` — without this guard, ⌘⇧W dispatched while
        // Settings (or any non-Blackbird window) is key would still flip
        // `MainWindowController.bypassCloseConfirm`, and a nested-modal
        // running between the flip and the deferred reset would see the
        // leaked flag in another controller's `windowShouldClose`.
        // (audit H-9 — the bug the original commit message claimed fixed.)
        guard let window = ownedKeyWindow() else {
            Self.menuLogger.notice("closeWindow: no Blackbird-owned key window; ignoring")
            return
        }
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
        // alert per tab. ONLY for a multi-tab sweep: a single-tab ⌘⇧W must
        // keep the per-tab confirm (matching plain ⌘W), else it kills a
        // running process with no confirmation at all. (F-S6-002)
        if MainWindowController.shouldBypassPerTabConfirm(tabCount: tabs.count) {
            MainWindowController.bypassCloseConfirm = true
        }
        defer { MainWindowController.bypassCloseConfirm = false }
        for tab in tabs {
            tab.performClose(nil)
        }
    }

}

// MARK: - NSMenuItemValidation (audit H-9)

/// `selectTab(_:)` (⌘1-9) and `closeWindow(_:)` (⌘⇧W) are wired to
/// AppDelegate selectors with `target=nil`. AppKit walks the responder
/// chain and reaches AppDelegate regardless of which window class is key
/// — Settings, About, a Sparkle alert, etc. Without a validator, ⌘5
/// pressed while Settings is key would route to the AppDelegate handler,
/// snapshot `NSApp.keyWindow` (the Settings window), and either no-op
/// confusingly or attempt to walk a non-existent tab group. ⌘⇧W is worse:
/// `closeWindow` flips the static `MainWindowController.bypassCloseConfirm`
/// for the duration of the call; any nested-modal that runs between flip
/// and reset (a future "unsaved changes" alert in the Settings close path)
/// would see the leaked flag and silently bypass per-tab close confirmation
/// in any MainWindowController whose `windowShouldClose` fires in nested
/// mode.
///
/// Gate both selectors on (a) keyWindow exists, (b) it belongs to a
/// MainWindowController we own, and for `selectTab` (c) the tag falls
/// inside the current tab group. Other selectors fall through with
/// `return true` so we don't accidentally mask AppKit's default validation
/// for items we don't introduce.
extension AppDelegate: NSMenuItemValidation {
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        // AppKit invokes `validateMenuItem` on the main thread during the
        // menu update cycle. Lock the contract so a future caller (e.g.,
        // a background queue building a custom menu) can't silently
        // wander off-main and read `controllers` / `NSApp.keyWindow`
        // from a non-main context. Sibling pattern of the KVO tripwires
        // (audit L-2) and the M-12 Settings tripwires.
        dispatchPrecondition(condition: .onQueue(.main))
        switch item.action {
        case #selector(selectTab(_:)):
            guard let win = ownedKeyWindow() else { return false }
            // Mirror the action body's lookup — both must agree on
            // "what counts as a tab" and "in what order". Using
            // `tabbedWindows` here while the action consults the
            // coordinator would let a brief reconciliation lag (close
            // → next read) enable a menu item whose action would then
            // guard-fail silently. Counts converge instantly in
            // practice but the inconsistency is gratuitous; both
            // paths go through the coordinator.
            let tabs: [NSWindow]
            if let group = win.tabGroup {
                tabs = TabOrderCoordinator.shared.orderedTabs(for: group)
            } else {
                tabs = [win]
            }
            return item.tag >= 1 && item.tag <= tabs.count
        case #selector(closeWindow(_:)):
            return ownedKeyWindow() != nil
        default:
            return true
        }
    }
}


/// Audit S2-004: idle-based replacement for the test-host 60 s exit
/// fuse. The TESTS (TestHostTermination, in the injected bundle — same
/// process) post `activityNotification` on every test start/finish;
/// this monitor exits the host only when no heartbeat has arrived for
/// `idleLimit`. A single test legitimately running longer than the
/// limit would still be shot — 300 s is far past the suite's slowest
/// test (the project gates test cost deliberately) while keeping
/// zombie-host cleanup prompt enough for CI.
///
/// Exit code stays 0 on the idle path, preserving the original
/// safety-net semantics: a genuinely red run is caught by
/// TestHostTermination's issueCount → exit(1) propagation and by CI's
/// "both suites printed passed" grep, not by this last-resort fuse.
final class TestHostActivityMonitor {
    static let shared = TestHostActivityMonitor()
    static let activityNotification = Notification.Name(
        "dev.conjfrnk.blackbird.testHostActivity"
    )
    private static let idleLimit: TimeInterval = 300
    private static let checkInterval: TimeInterval = 30

    /// Main-queue confined (observer is delivered on .main; the timer
    /// fires on the main runloop).
    private var lastActivity = Date()
    private var observer: NSObjectProtocol?
    private var timer: Timer?

    func start() {
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(
            forName: Self.activityNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.lastActivity = Date()
        }
        let t = Timer(timeInterval: Self.checkInterval, repeats: true) { [weak self] _ in
            guard let self else { return }
            let idle = Date().timeIntervalSince(self.lastActivity)
            if idle > Self.idleLimit {
                FileHandle.standardError.write(Data(
                    "Blackbird test-host safety net: no test activity for \(Int(idle)) s — exiting host.\n".utf8
                ))
                exit(0)
            }
        }
        // .common so the check still fires while XCTest runs the
        // runloop in non-default modes (modal panels, tracking).
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }
}
