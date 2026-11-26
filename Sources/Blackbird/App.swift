import SwiftUI
import AppKit
import Combine
import QuartzCore
import Sparkle
import os

/// AppKit entry point rather than a SwiftUI `App`: a `Settings { … }` scene registers a hidden handler that
/// intercepts ⌘, and opens SwiftUI's own blank Settings window.
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

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private var controllers: [MainWindowController] = []

    private static let menuLogger = Logger(subsystem: "dev.conjfrnk.blackbird",
                                           category: "menu")

    private static let tabsLogger = Logger(subsystem: "dev.conjfrnk.blackbird",
                                           category: "tabs")

    /// Shared by `validateMenuItem` and the action bodies: `NSApp.sendAction` dispatch skips menu validation.
    private func ownedKeyWindow() -> NSWindow? {
        guard let win = NSApp.keyWindow,
              controllers.contains(where: { $0.window === win }) else { return nil }
        return win
    }

    /// nil unless Info.plist carries real Sparkle config; with placeholders the controller alerts on every launch.
    private lazy var updaterController: SPUStandardUpdaterController? = {
        guard Self.isUpdaterConfigured else { return nil }
        let ctrl = SPUStandardUpdaterController(
            startingUpdater: false,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        ctrl.updater.automaticallyChecksForUpdates = Preferences.shared.autoUpdateChecks
        ctrl.startUpdater()
        return ctrl
    }()

    static var isUpdaterConfigured: Bool {
        let feed = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String ?? ""
        let key = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String ?? ""
        let placeholder = feed.isEmpty
            || feed.contains("example.com")
            || key.isEmpty
        return !placeholder
    }

    private var autoUpdateObserver: AnyCancellable?

    private var tabOrderObserver: NSObjectProtocol?

    private var externalTabActionObserver: NSObjectProtocol?

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // The XCTest host outlives every window a test creates; quitting here would kill it between tests.
        !isUnderTest
    }

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
        // Stays true through AppKit's synchronous batch-close sweep; cleared in `applicationWillTerminate`.
        MainWindowController.setCloseConfirmBypass(true)
        return .terminateNow
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        ThemeManager.shared.attach(toApp: NSApp)
        configureProcessSignals()

        if startTestHostIfUnderTest() { return }

        // Order is load-bearing: `prewarmSubsystems` installs the Sparkle alert override before any updater
        // session, and the auto-update bridge comes after the updater is reachable.
        prewarmSubsystems()
        installDiagnostics()
        installMainMenu()
        installAutoUpdateBridge()
        installTabOrderObserver()
        installExternalTabActionObserver()
        ContextMenuKeyInterceptor.install()
        NSApp.servicesProvider = self
        didFinishLaunching = true
        // `application(_:open:)` can arrive before this hook; those URLs were held and open now as the first window(s).
        let held = pendingOpenURLs
        pendingOpenURLs = []
        let opened = openTerminalWindows(atFileURLs: held)
        if opened == 0 {
            openFirstWindow()
        }
        // After the first window, so font enumeration never contends with window construction / PTY spawn.
        MonospaceFontFamilies.prewarm()
    }

    // MARK: - Dock menu

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()
        menu.addItem(withTitle: "New Window", action: #selector(newWindow(_:)), keyEquivalent: "")
        return menu
    }

    // MARK: - Open at a folder

    func application(_ application: NSApplication, open urls: [URL]) {
        // Nothing is wired before applicationDidFinishLaunching, and MainWindowController starts its shell in init.
        if !didFinishLaunching {
            pendingOpenURLs.append(contentsOf: urls)
            return
        }
        let opened = openTerminalWindows(atFileURLs: urls)
        if opened == 0 {
            AppDelegate.launchLogger.error("open: none of \(urls.count, privacy: .public) URL(s) named an existing folder or file")
            NSSound.beep()
        }
    }

    private var didFinishLaunching = false
    private var pendingOpenURLs: [URL] = []
    static let launchLogger = Logger(subsystem: "dev.conjfrnk.blackbird", category: "launch")

    /// The Services entry "New Blackbird Terminal at Folder" (NSServices block in project.yml).
    @objc func newTerminalAtFolder(
        _ pboard: NSPasteboard,
        userData: String,
        error: AutoreleasingUnsafeMutablePointer<NSString>
    ) {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        guard let urls = pboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL],
              !urls.isEmpty else {
            error.pointee = "The pasteboard carried no folder."
            return
        }
        let opened = openTerminalWindows(atFileURLs: urls)
        if opened == 0 {
            error.pointee = "None of the items is an existing folder or file."
        }
    }

    @discardableResult
    private func openTerminalWindows(atFileURLs urls: [URL]) -> Int {
        var opened = 0
        for url in urls where openTerminalWindow(atFileURL: url) != nil {
            opened += 1
        }
        return opened
    }

    /// nil for non-file URLs and missing paths: a Finder gesture must not silently land in $HOME.
    static func startingDirectory(forOpening url: URL) -> String? {
        guard url.isFileURL else { return nil }
        let path = url.standardizedFileURL.path
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir) else { return nil }
        return isDir.boolValue ? path : url.standardizedFileURL.deletingLastPathComponent().path
    }

    @discardableResult
    func openTerminalWindow(atFileURL url: URL) -> MainWindowController? {
        guard let dir = Self.startingDirectory(forOpening: url) else { return nil }
        let controller = createTerminalController(cwd: dir, autosaveFrame: false)
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        scheduleTabBarRefresh()
        return controller
    }

    /// Ignore SIGPIPE so a write racing PTY slave close can't kill the app; the child resets it to SIG_DFL after fork.
    private func configureProcessSignals() {
        signal(SIGPIPE, SIG_IGN)
    }

    /// The idle monitor exits the test host only after 300 s without a test start / finish heartbeat.
    private func startTestHostIfUnderTest() -> Bool {
        guard isUnderTest else { return false }
        TestHostActivityMonitor.shared.start()
        return true
    }

    private var isUnderTest: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            || ProcessInfo.processInfo.environment["XCTestSessionIdentifier"] != nil
            || ProcessInfo.processInfo.environment["XCTestBundlePath"] != nil
            || NSClassFromString("XCTestCase") != nil
    }

    private func prewarmSubsystems() {
        // First touch runs `tic` + `infocmp` synchronously; start it off-main so `PTY.spawn` finds it memoized.
        KittyTerminfo.prewarm()

        ShellIntegration.prewarm()

        SparkleAlertOverride.install()
    }

    private func installDiagnostics() {
        // BB_HANG_WATCHDOG: "1" forces on, "0" forces off, unset falls back to the build default.
        let hangEnv = ProcessInfo.processInfo.environment["BB_HANG_WATCHDOG"]
        #if DEBUG
        let installWatchdog = (hangEnv != "0")
        #else
        let installWatchdog: Bool = {
            switch hangEnv {
            case "1": return true
            case "0": return false
            default: return Preferences.shared.hangDetection
            }
        }()
        #endif
        if installWatchdog { MainThreadWatchdog.install(hangThreshold: 1.0, pingInterval: 0.25) }
        // Runs regardless of installWatchdog: the partials are from a prior session. A capture in progress is
        // younger than the prune's 60 s age gate, so it is skipped.
        DispatchQueue.global(qos: .utility).async {
            HangReportStore.pruneOrphanPartials()
            HangReportStore.pruneExcessReports(keep: 20)
        }
    }

    /// The same-value guard breaks a feedback loop: writing Sparkle's flag writes UserDefaults, SwiftUI's global
    /// defaults observer then fires `objectWillChange` on `Preferences.shared`, and this sink would write again.
    private func installAutoUpdateBridge() {
        autoUpdateObserver = Preferences.shared.objectWillChange
            .sink { [weak self] _ in
                DispatchQueue.main.async {
                    guard let ctrl = self?.updaterController else { return }
                    let desired = Preferences.shared.autoUpdateChecks
                    guard ctrl.updater.automaticallyChecksForUpdates != desired else { return }
                    ctrl.updater.automaticallyChecksForUpdates = desired
                }
            }
    }

    private func installTabOrderObserver() {
        tabOrderObserver = NotificationCenter.default.addObserver(
            forName: TabOrderCoordinator.orderDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            // The only poster is on the main thread, so delivery is synchronous; assumeIsolated avoids a
            // `Task { @MainActor in }` hop that would defer the strip repaint a runloop turn.
            MainActor.assumeIsolated {
                self?.refreshAllTabBars()
            }
        }
    }

    /// Sweeps every controller: a window that had no tab group a moment ago has no per-group refresh path.
    private func installExternalTabActionObserver() {
        externalTabActionObserver = NotificationCenter.default.addObserver(
            forName: TerminalWindow.externalTabActionDidRun,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                Self.tabsLogger.log("externalTabActionDidRun — sweeping refreshTabBar() across \(self?.controllers.count ?? 0, privacy: .public) controller(s)")
                self?.refreshAllTabBars()
            }
        }
    }

    private func openFirstWindow() {
        let controller = createTerminalController(cwd: CwdResolver.forNewWindow())
        controller.showWindow(nil)
    }

    func insertSparkleMenuItem(into appSubmenu: NSMenu) {
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
        // Secure event input left on blocks keyboard events system-wide while the process lingers.
        for controller in controllers {
            if let view = controller.terminalView {
                view.disableSecureEventInputIfHeld()
            }
            // Flush a deferred frame save (its timer dies with the process) before the controllers are released.
            controller.framePersistence.flushPendingSave()
        }
        controllers.forEach { $0.terminateSessions() }
        controllers.removeAll()
        MainWindowController.setCloseConfirmBypass(false)
    }

    /// macOS 14+ logs a runtime warning at launch when the delegate doesn't implement this.
    func applicationSupportsSecureRestorableState(
        _ app: NSApplication
    ) -> Bool {
        true
    }

    @objc func openSettings(_ sender: Any?) {
        SettingsWindowController.shared.show()
    }

    /// Reached through `NSApp.sendAction` with a nil target from the Settings window.
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
            self.scheduleTabBarRefresh()
        }
        controllers.append(controller)
        return controller
    }

    private var activeTerminalController: MainWindowController? {
        if let keyWindow = NSApp.keyWindow,
           let match = controllers.first(where: { $0.window === keyWindow }) {
            return match
        }
        // `orderedIndex` is lower for more recently used windows.
        return controllers
            .filter { $0.window != nil }
            .sorted { ($0.window?.orderedIndex ?? .max) < ($1.window?.orderedIndex ?? .max) }
            .first
    }

    // MARK: - Tab / window actions

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
            // addTabbedWindow(_:ordered:) orders front and makes key itself; showWindow first flashes a standalone window.
            sourceWindow.addTabbedWindow(newWindow, ordered: .above)
        } else {
            controller.showWindow(nil)
        }
        newWindow.makeKeyAndOrderFront(nil)
        // NSWindowTabGroup's `.windows` is not reliably KVO-fireable on tab-add, so refresh explicitly.
        scheduleTabBarRefresh()
    }

    private func refreshAllTabBars() {
        for c in controllers { c.refreshTabBar() }
    }

    /// Deferred one main-runloop tick so the tab group settles first.
    private func scheduleTabBarRefresh() {
        DispatchQueue.main.async { [weak self] in
            self?.refreshAllTabBars()
        }
    }

    @objc func newWindow(_ sender: Any?) {
        let controller = createTerminalController(
            cwd: CwdResolver.forNewWindow(),
            autosaveFrame: false
        )
        // `.preferred` tabbing lets macOS auto-merge this window when the system "Prefer Tabs" is Always. Disallowed
        // for the creation instant only: staying .disallowed would make the window un-mergeable for life.
        controller.disallowTabbingForCreationInstant()
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
    }

    /// Tag is the 1-based index. `Any?` sender: a typed `NSMenuItem` parameter's @objc thunk traps on any other sender.
    @objc func selectTab(_ sender: Any?) {
        guard let item = sender as? NSMenuItem else {
            Self.menuLogger.error(
                "selectTab: unexpected sender type \(String(describing: type(of: sender)), privacy: .public) — expected NSMenuItem"
            )
            return
        }
        guard let window = ownedKeyWindow() else {
            Self.menuLogger.notice(
                "selectTab: no Blackbird-owned key window; ignoring tag=\(item.tag, privacy: .public)"
            )
            return
        }
        // Visual (pill) order from TabOrderCoordinator; `tabbedWindows` is AppKit's arrival order.
        let tabs = TabOrderCoordinator.shared.orderedTabs(of: window)
        let index = item.tag - 1
        guard index >= 0, index < tabs.count else {
            Self.menuLogger.debug(
                "selectTab: tag \(item.tag, privacy: .public) out of range (tabs=\(tabs.count, privacy: .public))"
            )
            return
        }
        tabs[index].makeKeyAndOrderFront(nil)
    }

    @objc func closeWindow(_ sender: Any?) {
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
        // Multi-tab sweep only: a single-tab ⌘⇧W must keep the per-tab confirm.
        if MainWindowController.shouldBypassPerTabConfirm(tabCount: tabs.count) {
            MainWindowController.setCloseConfirmBypass(true)
        }
        defer { MainWindowController.setCloseConfirmBypass(false) }
        for tab in tabs {
            tab.performClose(nil)
        }
    }

}

// MARK: - NSMenuItemValidation

/// These selectors have `target=nil`, so AppKit reaches AppDelegate whichever window is key (Settings, alerts).
extension AppDelegate: NSMenuItemValidation {
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        dispatchPrecondition(condition: .onQueue(.main))
        switch item.action {
        case #selector(selectTab(_:)):
            guard let win = ownedKeyWindow() else { return false }
            // Must use the same lookup as the action body.
            let tabs = TabOrderCoordinator.shared.orderedTabs(of: win)
            return item.tag >= 1 && item.tag <= tabs.count
        case #selector(closeWindow(_:)):
            return ownedKeyWindow() != nil
        default:
            return true
        }
    }
}
