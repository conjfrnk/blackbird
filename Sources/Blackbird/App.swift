import SwiftUI
import AppKit
import BBCore

@main
struct BlackbirdApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup {
            Text(Self.status)
                .font(.system(.title2, design: .monospaced))
                .padding()
                .frame(minWidth: 480, minHeight: 240)
        }
    }

    static var status: String {
        guard let term = BBTerm(size: .init(cols: 80, rows: 24)) else {
            return "BBTerm failed to init."
        }
        term.input("hello")
        guard let snap = term.snapshot() else {
            return "Snapshot failed."
        }
        return "First cell: \(snap.character(at: 0, row: 0).map(String.init) ?? "?")"
    }
}

/// Minimal AppDelegate. Task 5 replaces this with full AppKit window management.
/// Ensures the app quits when its last window closes, and — under XCTest —
/// arms a hard timeout so the host process can't leak if the test observer
/// misfires. Without this safety net we accumulated zombie Blackbird.app
/// processes across xcodebuild test runs.
final class AppDelegate: NSObject, NSApplicationDelegate {
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
            // Safety net: force-exit after 60 seconds so a missed
            // testBundleDidFinish observer or a hung test can't keep the
            // host process alive indefinitely. Our full suite runs in
            // under 1 second; 60s is comfortably above realistic totals.
            DispatchQueue.main.asyncAfter(deadline: .now() + 60) {
                exit(0)
            }
        }
    }
}
