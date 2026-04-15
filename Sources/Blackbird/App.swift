import SwiftUI
import AppKit

@main
struct BlackbirdApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // Settings placeholder — Plan 5 will wire the real settings pane.
        // Required by SwiftUI: `App.body` must produce at least one Scene.
        // Settings doesn't open a window until the user picks ⌘, so it
        // doesn't interfere with AppDelegate's AppKit-managed main window.
        Settings {
            EmptyView()
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {

    private var mainController: MainWindowController?

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
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
        let controller = MainWindowController()
        controller.showWindow(nil)
        mainController = controller
    }

    func applicationWillTerminate(_ notification: Notification) {
        mainController?.terminateSessions()
    }

    // MARK: - Menu

    private func installMainMenu() {
        let main = NSMenu()

        let appItem = NSMenuItem()
        main.addItem(appItem)
        appItem.submenu = buildAppMenu()

        let editItem = NSMenuItem()
        main.addItem(editItem)
        editItem.submenu = buildEditMenu()

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
        NSApplication.shared.windowsMenu = menu
        return menu
    }
}
