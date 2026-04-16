import SwiftUI
import AppKit
import Sparkle

@main
struct BlackbirdApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // We deliberately ship an empty scene body. Windows are built by
        // `AppDelegate.createTerminalController()` as AppKit `NSWindow`s, and
        // Settings is a standalone AppKit-hosted `NSHostingController`
        // (see SettingsWindowController) — that path is more reliable under
        // @NSApplicationDelegateAdaptor + custom main menu than SwiftUI's
        // `Settings { … }` scene, which has flaky `showSettingsWindow:`
        // wiring when the main menu is replaced.
        Settings { EmptyView() }  // placeholder — never presented.
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {

    private var controllers: [MainWindowController] = []

    /// Sparkle updater. Instantiated lazily so XCTest hosts don't spin it up.
    /// `startingUpdater: true` kicks off the background scheduled-check loop
    /// as soon as this is first referenced (which we do from
    /// `applicationDidFinishLaunching` for non-test launches).
    private lazy var updaterController: SPUStandardUpdaterController = {
        SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
    }()

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
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
        installMainMenu()
        installSparkleMenuItem()
        let controller = createTerminalController()
        controller.showWindow(nil)
    }

    /// Inserts a "Check for Updates…" item into the app submenu right after
    /// "About Blackbird". Target is the Sparkle controller so the standard
    /// `checkForUpdates(_:)` selector is dispatched correctly. Kept separate
    /// from `buildAppMenu()` because `updaterController` is lazy and tests
    /// shouldn't trigger it.
    private func installSparkleMenuItem() {
        guard
            let firstItem = NSApp.mainMenu?.items.first,
            let appSubmenu = firstItem.submenu
        else { return }
        let checkItem = NSMenuItem(
            title: "Check for Updates…",
            action: #selector(SPUStandardUpdaterController.checkForUpdates(_:)),
            keyEquivalent: ""
        )
        checkItem.target = updaterController
        appSubmenu.insertItem(checkItem, at: 1)
    }

    func applicationWillTerminate(_ notification: Notification) {
        controllers.forEach { $0.terminateSessions() }
        controllers.removeAll()
    }

    @objc func openSettings(_ sender: Any?) {
        // AppKit-hosted settings window — see SettingsWindowController for
        // why we don't rely on SwiftUI's `Settings { … }` scene wiring.
        SettingsWindowController.shared.show()
    }

    // MARK: - Controller factory

    @discardableResult
    private func createTerminalController() -> MainWindowController {
        let controller = MainWindowController()
        controller.onClose = { [weak self, weak controller] in
            guard let self, let controller else { return }
            self.controllers.removeAll { $0 === controller }
        }
        controllers.append(controller)
        return controller
    }

    // MARK: - Tab / window actions

    /// Called by the tab bar "+" button and by the ⌘T menu item.
    @objc func newWindowForTab(_ sender: Any?) {
        let controller = createTerminalController()
        // Merge into the key window's tab group so it appears as a new tab.
        if let currentWindow = NSApp.keyWindow {
            currentWindow.addTabbedWindow(controller.window!, ordered: .above)
        }
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
    }

    /// Opens a new independent window (⌘N).
    @objc func newWindow(_ sender: Any?) {
        let controller = createTerminalController()
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
