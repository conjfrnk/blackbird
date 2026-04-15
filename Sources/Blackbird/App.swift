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
        let controller = MainWindowController()
        controller.showWindow(nil)
        mainController = controller
    }

    func applicationWillTerminate(_ notification: Notification) {
        mainController?.terminateSessions()
    }
}
