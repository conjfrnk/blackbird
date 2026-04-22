import SwiftUI
import AppKit
import Combine
import Sparkle

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
        installMainMenu()
        installSparkleMenuItem()
        // Live-toggle Sparkle's auto-check when the pref changes, so the
        // Settings > Updates toggle takes effect without relaunching. No-op
        // when the updater isn't configured (dev builds); the Preferences
        // observer still fires, it just hits a nil controller.
        autoUpdateObserver = Preferences.shared.objectWillChange
            .sink { [weak self] _ in
                DispatchQueue.main.async {
                    self?.updaterController?.updater.automaticallyChecksForUpdates
                        = Preferences.shared.autoUpdateChecks
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
        let source = activeTerminalController
        let controller = createTerminalController(
            cwd: CwdResolver.forNewTab(source: source?.session),
            autosaveFrame: false   // tabs use the group's position
        )
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

    // MARK: - Menu

    private func installMainMenu() {
        let main = NSMenu()

        let appItem = NSMenuItem()
        main.addItem(appItem)
        appItem.submenu = buildAppMenu()

        let fileItem = NSMenuItem()
        main.addItem(fileItem)
        fileItem.submenu = buildFileMenu()

        let editItem = NSMenuItem()
        main.addItem(editItem)
        editItem.submenu = buildEditMenu()

        let viewItem = NSMenuItem()
        main.addItem(viewItem)
        viewItem.submenu = buildViewMenu()

        let windowItem = NSMenuItem()
        main.addItem(windowItem)
        windowItem.submenu = buildWindowMenu()

        NSApplication.shared.mainMenu = main
    }

    private func buildAppMenu() -> NSMenu {
        let menu = NSMenu(title: "Blackbird")
        menu.addItem(
            withTitle: "About Blackbird",
            action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
            keyEquivalent: ""
        )
        menu.addItem(.separator())
        // SwiftUI's Settings scene registers a hidden controller that handles
        // `showSettingsWindow:`. With @NSApplicationDelegateAdaptor + a fully
        // custom main menu, the responder chain doesn't reliably reach that
        // controller (NSApp isn't a handler, and the hidden SwiftUI controller
        // isn't in the chain). Route via AppDelegate.openSettings(_:) which
        // calls NSApp.sendAction — sendAction IS what correctly dispatches
        // to SwiftUI's registered selector handler. Fallback covers older
        // macOS that still uses `showPreferencesWindow:`.
        let settingsItem = NSMenuItem(
            title: "Settings…",
            action: #selector(openSettings(_:)),
            keyEquivalent: ","
        )
        settingsItem.target = self
        menu.addItem(settingsItem)
        menu.addItem(.separator())
        // Services submenu. TerminalView conforms to NSServicesMenuRequestor
        // so individual services (Dictionary, Open URL, system translate,
        // third-party text tools) can read the current selection. Without
        // this item the submenu doesn't get wired up — the protocol
        // conformance is live but no user-accessible entry point. Audit
        // app-entry F3. `servicesMenu` is a full NSMenu NSApp owns; we
        // just need an item to host it.
        let servicesItem = NSMenuItem(
            title: "Services",
            action: nil,
            keyEquivalent: ""
        )
        let servicesSubmenu = NSMenu(title: "Services")
        servicesItem.submenu = servicesSubmenu
        menu.addItem(servicesItem)
        NSApp.servicesMenu = servicesSubmenu
        menu.addItem(.separator())
        menu.addItem(
            withTitle: "Hide Blackbird",
            action: #selector(NSApplication.hide(_:)),
            keyEquivalent: "h"
        )
        let hideOthers = NSMenuItem(
            title: "Hide Others",
            action: #selector(NSApplication.hideOtherApplications(_:)),
            keyEquivalent: "h"
        )
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        menu.addItem(hideOthers)
        menu.addItem(
            withTitle: "Show All",
            action: #selector(NSApplication.unhideAllApplications(_:)),
            keyEquivalent: ""
        )
        menu.addItem(.separator())
        menu.addItem(
            withTitle: "Quit Blackbird",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        return menu
    }

    private func buildFileMenu() -> NSMenu {
        let menu = NSMenu(title: "File")
        menu.addItem(
            withTitle: "New Window",
            action: #selector(newWindow(_:)),
            keyEquivalent: "n"
        )
        menu.addItem(
            withTitle: "New Tab",
            action: #selector(newWindowForTab(_:)),
            keyEquivalent: "t"
        )
        return menu
    }

    private func buildEditMenu() -> NSMenu {
        let menu = NSMenu(title: "Edit")
        // Selectors route to first responder. TerminalView will wire these
        // in Plan 6 (selection + copy/paste). Present now so Mac users see
        // the expected menu items.
        menu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        menu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Cut",   action: #selector(NSText.cut(_:)),   keyEquivalent: "x")
        menu.addItem(withTitle: "Copy",  action: #selector(NSText.copy(_:)),  keyEquivalent: "c")
        menu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        menu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        menu.addItem(.separator())
        // Find submenu. Without an explicit menu entry, AppKit won't map
        // ⌘F / ⌘G / ⌘⇧G to TerminalView's performFind*Action selectors —
        // the custom first responder only receives menu-dispatched actions,
        // not raw key events (those are filtered as ⌘-prefixed at keyDown
        // and handed to super).
        let findSubmenu = NSMenu(title: "Find")
        findSubmenu.addItem(
            withTitle: "Find…",
            action: #selector(TerminalView.performFindPanelAction(_:)),
            keyEquivalent: "f"
        )
        let findNext = NSMenuItem(
            title: "Find Next",
            action: #selector(TerminalView.performFindNextAction(_:)),
            keyEquivalent: "g"
        )
        findSubmenu.addItem(findNext)
        let findPrev = NSMenuItem(
            title: "Find Previous",
            action: #selector(TerminalView.performFindPreviousAction(_:)),
            keyEquivalent: "G"
        )
        findPrev.keyEquivalentModifierMask = [.command, .shift]
        findSubmenu.addItem(findPrev)
        let replaceSelection = NSMenuItem(
            title: "Replace Selection",
            action: #selector(TerminalView.performReplaceCurrent(_:)),
            keyEquivalent: "e"
        )
        replaceSelection.keyEquivalentModifierMask = [.command, .option]
        findSubmenu.addItem(replaceSelection)
        findSubmenu.addItem(.separator())
        // ⌘⌥C toggles case-sensitive find, ⌘⌥R toggles regex mode.
        // Matches iTerm2 Find's equivalents; visible in the placeholder
        // when enabled. Routes through the responder chain to the focused
        // TerminalView's findBar (target=nil).
        let caseToggle = NSMenuItem(
            title: "Find: Case Sensitive",
            action: #selector(TerminalView.toggleFindCaseSensitive(_:)),
            keyEquivalent: "c"
        )
        caseToggle.keyEquivalentModifierMask = [.command, .option]
        findSubmenu.addItem(caseToggle)
        let regexToggle = NSMenuItem(
            title: "Find: Regular Expression",
            action: #selector(TerminalView.toggleFindRegex(_:)),
            keyEquivalent: "r"
        )
        regexToggle.keyEquivalentModifierMask = [.command, .option]
        findSubmenu.addItem(regexToggle)
        let findParent = NSMenuItem(title: "Find", action: nil, keyEquivalent: "")
        findParent.submenu = findSubmenu
        menu.addItem(findParent)
        menu.addItem(.separator())
        // ⌘K clears viewport + scrollback. Action is dispatched via the
        // responder chain (target = nil) so the focused TerminalView handles it.
        menu.addItem(
            withTitle: "Clear Buffer",
            action: #selector(TerminalView.clearBufferAndScrollback(_:)),
            keyEquivalent: "k"
        )
        return menu
    }

    private func buildViewMenu() -> NSMenu {
        let menu = NSMenu(title: "View")
        // ⌘+/⌘-/⌘0 adjust font size. The "+" key equivalent actually fires
        // on ⌘⇧= on most layouts; spelling it as "+" with the default command
        // mask matches what users expect to see in the menu and what AppKit
        // matches against the incoming keyDown.
        let biggerItem = NSMenuItem(
            title: "Bigger Text",
            action: #selector(TerminalView.increaseFontSize(_:)),
            keyEquivalent: "+"
        )
        biggerItem.keyEquivalentModifierMask = [.command]
        menu.addItem(biggerItem)

        let smallerItem = NSMenuItem(
            title: "Smaller Text",
            action: #selector(TerminalView.decreaseFontSize(_:)),
            keyEquivalent: "-"
        )
        smallerItem.keyEquivalentModifierMask = [.command]
        menu.addItem(smallerItem)

        let resetItem = NSMenuItem(
            title: "Actual Size",
            action: #selector(TerminalView.resetFontSize(_:)),
            keyEquivalent: "0"
        )
        resetItem.keyEquivalentModifierMask = [.command]
        menu.addItem(resetItem)

        menu.addItem(.separator())

        // Prompt navigation — walks the OSC 133 A marks recorded by
        // TerminalSession whenever the user's shell integration snippet
        // emits a prompt-start escape. Matches iTerm2's ⌘⇧↑ / ⌘⇧↓
        // convention so muscle memory carries over. No-op when no marks
        // have been recorded (shell integration not sourced).
        let prevPrompt = NSMenuItem(
            title: "Previous Prompt",
            action: #selector(TerminalView.jumpToPreviousPrompt(_:)),
            keyEquivalent: "\u{F700}" // NSUpArrowFunctionKey
        )
        prevPrompt.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(prevPrompt)

        let nextPrompt = NSMenuItem(
            title: "Next Prompt",
            action: #selector(TerminalView.jumpToNextPrompt(_:)),
            keyEquivalent: "\u{F701}" // NSDownArrowFunctionKey
        )
        nextPrompt.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(nextPrompt)

        menu.addItem(.separator())

        // Rename Tab… — routes via the responder chain to the key window's
        // MainWindowController. Uses ⌥⌘R because ⌘R is commonly a
        // refresh/reload shortcut in other apps, and we want to leave it
        // free for shells that bind it (zsh's history-incremental-search-
        // backward, for instance, is sometimes mapped to Ctrl-R — but
        // ⌘-R would still reach us first).
        let rename = NSMenuItem(
            title: "Rename Tab…",
            action: #selector(MainWindowController.renameActiveTab(_:)),
            keyEquivalent: "r"
        )
        rename.keyEquivalentModifierMask = [.command, .option]
        menu.addItem(rename)
        return menu
    }

    private func buildWindowMenu() -> NSMenu {
        let menu = NSMenu(title: "Window")
        menu.addItem(
            withTitle: "Minimize",
            action: #selector(NSWindow.performMiniaturize(_:)),
            keyEquivalent: "m"
        )
        menu.addItem(
            withTitle: "Zoom",
            action: #selector(NSWindow.performZoom(_:)),
            keyEquivalent: ""
        )
        menu.addItem(.separator())
        menu.addItem(
            withTitle: "Close",
            action: #selector(NSWindow.performClose(_:)),
            keyEquivalent: "w"
        )
        let closeWindow = NSMenuItem(
            title: "Close Window",
            action: #selector(closeWindow(_:)),
            keyEquivalent: "W"
        )
        closeWindow.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(closeWindow)
        menu.addItem(.separator())

        // Next / previous tab — AppKit handles these natively on tab-grouped
        // windows; wiring them here ensures they appear in the menu and are
        // discoverable via ⌘⇧] / ⌘⇧[.
        let nextTab = NSMenuItem(
            title: "Show Next Tab",
            action: #selector(NSWindow.selectNextTab(_:)),
            keyEquivalent: "]"
        )
        nextTab.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(nextTab)

        let prevTab = NSMenuItem(
            title: "Show Previous Tab",
            action: #selector(NSWindow.selectPreviousTab(_:)),
            keyEquivalent: "["
        )
        prevTab.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(prevTab)

        menu.addItem(.separator())

        // ⌘1-9 jump to a specific tab by position.
        for i in 1...9 {
            let item = NSMenuItem(
                title: "Tab \(i)",
                action: #selector(selectTab(_:)),
                keyEquivalent: String(i)
            )
            item.tag = i
            menu.addItem(item)
        }

        NSApplication.shared.windowsMenu = menu
        return menu
    }
}
