import XCTest
import AppKit
import SwiftUI
@testable import Blackbird

/// Blind behaviour tests for the Settings -> Diagnostics list being stale
/// after the Settings window is closed and reopened (spec, not
/// implementation):
///
///  The Diagnostics section lists hang reports (`~/Library/Logs/Blackbird/
///  hang-*.txt`) and crash reports (`~/Library/Logs/DiagnosticReports/
///  Blackbird-*.ips`). Its whole purpose is to surface FRESH reports. The
///  Settings window is built once and reused, so the section the user last
///  looked at is still selected when they press Cmd-, again.
///
///  Contract pinned here: the user opens Settings, selects Diagnostics,
///  closes the window (Cmd-W / Esc). While it is closed a report file
///  appears on disk. The user reopens Settings (the real production entry
///  point, `SettingsWindowController.shared.show()`). The Diagnostics
///  section, once on screen, MUST list that new report -- no Refresh click,
///  no switching sections required. (If a reopen lands on a different
///  section the user clicks Diagnostics; the same expectation holds: the
///  list is current.)
///
/// Black-box by construction:
///   * The window is driven only through `SettingsWindowController.shared`
///     (`show()`), found via `NSApp.windows` as a `SettingsWindow`, and closed
///     through `performClose` (what Cmd-W and Esc both do).
///   * Section changes go through the on-screen section selector (the
///     `NSSegmentedControl` SwiftUI's segmented picker produces, labelled
///     "Appearance" / "Behavior" / "Updates" / "Diagnostics").
///   * The visible list is read from the live accessibility tree of the
///     window. On this SwiftUI the report rows' file names and the empty-state
///     sentence are NOT exposed there, but every report row exposes exactly
///     one "Actions" menu label (the per-row Reveal/Copy/Email menu), so the
///     number of "Actions" nodes is the number of rows on screen. The row
///     count is CALIBRATED against a single known report (`perRow`) rather
///     than assumed to be 1, and the calibration step doubles as the proof
///     that the channel is alive and that the home redirect works.
///
/// Home-directory isolation: the Diagnostics view reads the REAL
/// `~/Library/Logs/...` (no injection seam on the view), so each test points
/// the process home at a throwaway directory for its duration by setting
/// `CFFIXED_USER_HOME` (honoured by `FileManager.homeDirectoryForCurrentUser`
/// / `NSHomeDirectory()`), asserts the redirect took effect, and restores it
/// in a `defer`. Nothing is ever written to the user's real log directories.
///
/// Defaults hygiene: the test host is the app itself, so `UserDefaults.standard`
/// is the real app domain. Showing/closing the Settings window makes AppKit
/// autosave its frame under `NSWindow Frame BlackbirdSettings*`; those keys
/// are snapshotted before and restored after so the user's saved Settings
/// frame is never changed.
///
/// Memory + time pre-flight: one 560x600 Settings window (the process-wide
/// `SettingsWindowController` singleton, built once) plus its SwiftUI host;
/// <= 3 files of < 100 bytes in a temp dir. No Metal, no PTY, no
/// `MainWindowController`. Each test: a handful of 0.4-0.6 s runloop pumps
/// plus polls bounded at 3 s; ~4-9 s worst case when the bug is present. The
/// Settings window is a standalone `SettingsWindow` (never a tab-group
/// member -- asserted), so close/orderOut is safe (CLAUDE.md tab-group rule
/// N/A); `animationBehavior = .none` is applied to it to avoid an
/// `_NSWindowTransformAnimation` for the order-out.
@MainActor
final class DiagnosticsReopenFreshnessBlindTests: XCTestCase {

    // MARK: - Spec strings

    private static let diagnosticsLabel = "Diagnostics"
    private static let otherPaneLabel = "Appearance"
    /// Title of the per-row menu; one per report row.
    private static let rowMenuLabel = "Actions"

    private static let seedHangFileName = "hang-BLINDREOPEN0.txt"
    private static let newHangFileName = "hang-BLINDREOPEN1.txt"
    private static let newCrashFileName = "Blackbird-BLINDREOPEN2.ips"

    // MARK: - Sandbox (home redirect + defaults snapshot)

    private final class Sandbox {
        let home: URL
        var hangDirectory: URL { home.appendingPathComponent("Library/Logs/Blackbird", isDirectory: true) }
        var crashDirectory: URL { home.appendingPathComponent("Library/Logs/DiagnosticReports", isDirectory: true) }

        private let previousFixedHome: String?
        private let savedFrameDefaults: [String: Any]
        private static let frameKeyPrefix = "NSWindow Frame BlackbirdSettings"

        init() throws {
            let fm = FileManager.default
            let root = fm.temporaryDirectory
                .appendingPathComponent("bb-diag-reopen-blind-\(UUID().uuidString)", isDirectory: true)
            try fm.createDirectory(at: root, withIntermediateDirectories: true)
            home = root

            if let raw = getenv("CFFIXED_USER_HOME") {
                previousFixedHome = String(cString: raw)
            } else {
                previousFixedHome = nil
            }
            var snapshot: [String: Any] = [:]
            for (key, value) in UserDefaults.standard.dictionaryRepresentation()
            where key.hasPrefix(Self.frameKeyPrefix) {
                snapshot[key] = value
            }
            savedFrameDefaults = snapshot

            setenv("CFFIXED_USER_HOME", root.path, 1)
        }

        func restore() {
            if let previousFixedHome {
                setenv("CFFIXED_USER_HOME", previousFixedHome, 1)
            } else {
                unsetenv("CFFIXED_USER_HOME")
            }
            let defaults = UserDefaults.standard
            for key in defaults.dictionaryRepresentation().keys
            where key.hasPrefix(Self.frameKeyPrefix) && savedFrameDefaults[key] == nil {
                defaults.removeObject(forKey: key)
            }
            for (key, value) in savedFrameDefaults {
                defaults.set(value, forKey: key)
            }
            try? FileManager.default.removeItem(at: home)
        }

        func writeReport(named name: String, in directory: URL) throws {
            let fm = FileManager.default
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data("blind-test report body\n".utf8).write(to: directory.appendingPathComponent(name))
        }

        func removeReport(named name: String, in directory: URL) throws {
            try FileManager.default.removeItem(at: directory.appendingPathComponent(name))
        }
    }

    // MARK: - Runloop helpers

    @discardableResult
    private func pump(until timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date(timeIntervalSinceNow: timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.01))
        }
        return condition()
    }

    private func pump(for seconds: TimeInterval) {
        pump(until: seconds) { false }
    }

    // MARK: - Keeper window (the app quits when its last window closes)

    /// The test host is the real app, whose delegate answers `true` to
    /// `applicationShouldTerminateAfterLastWindowClosed`. In production the
    /// terminal window is open behind Settings; in the bare test host the
    /// Settings window is the ONLY window, so closing it (the very step under
    /// test) would terminate the host a few runloop turns later. A plain
    /// standalone titled window kept on screen for the duration of the test
    /// stands in for the terminal window. It is never closed (only ordered
    /// out, after the deferred last-window check has had time to run), and
    /// is not a tab-group member.
    private func showKeeperWindow() -> NSWindow {
        let keeper = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 160, height: 100),
            styleMask: [.titled],
            backing: .buffered,
            defer: false)
        keeper.title = "Blind-test keeper"
        keeper.isReleasedWhenClosed = false
        keeper.animationBehavior = .none
        let visible = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        keeper.setFrameOrigin(NSPoint(x: visible.maxX - keeper.frame.width - 40,
                                      y: visible.minY + 40))
        keeper.orderFront(nil)
        return keeper
    }

    private func retireKeeperWindow(_ keeper: NSWindow) {
        pump(for: 0.6)
        keeper.orderOut(nil)
    }

    // MARK: - Settings window access

    private func settingsWindow() -> SettingsWindow? {
        NSApp.windows.compactMap { $0 as? SettingsWindow }.first
    }

    /// Open Settings through the production entry point and return its window.
    private func openSettings() throws -> SettingsWindow {
        SettingsWindowController.shared.show()
        let window = try XCTUnwrap(
            settingsWindow(),
            "SettingsWindowController.shared.show() did not leave a SettingsWindow in NSApp.windows "
            + "(windows: \(NSApp.windows.map { String(describing: type(of: $0)) }))")
        window.animationBehavior = .none
        XCTAssertTrue(window.isVisible,
                      "precondition: Settings window must be visible after show() (isVisible=\(window.isVisible))")
        XCTAssertNil(window.tabbedWindows,
                     "precondition: the Settings window must not be merged into a tab group")
        pump(for: 0.3)
        deliverKeyEventsIfHostIsInactive(window)
        pump(for: 0.3)
        return window
    }

    /// In production, `show()` (Cmd-,) makes the Settings window key and main,
    /// and AppKit posts `didBecomeMain`/`didBecomeKey` for it. The xctest host
    /// often runs with no active GUI session (frontmost app is
    /// `com.apple.loginwindow` on a locked screen; `NSApp.isActive` stays
    /// false and `activate` is refused), so AppKit never delivers those events
    /// even though `show()` called `makeKeyAndOrderFront`. Deliver them
    /// ourselves, for the window only, when the real ones could not occur, so
    /// a fix that refreshes on window-became-key is exercised exactly as it
    /// would be in production. The unfixed code ignores them, so this cannot
    /// make the regression pass vacuously.
    private func deliverKeyEventsIfHostIsInactive(_ window: NSWindow) {
        guard !window.isKeyWindow else { return }
        NotificationCenter.default.post(name: NSWindow.didBecomeMainNotification, object: window)
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window)
    }

    /// Close like Cmd-W / Esc do (`SettingsWindow.cancelOperation` -> performClose).
    private func closeSettings(_ window: SettingsWindow) {
        window.performClose(nil)
        pump(until: 1.0) { !window.isVisible }
        if window.isVisible {
            // performClose can be ignored without a key window; the
            // user-visible outcome needed is just "window gone".
            window.orderOut(nil)
            pump(until: 1.0) { !window.isVisible }
        }
    }

    // MARK: - Section selector

    private func findSegmentedControl(under root: NSView) -> NSSegmentedControl? {
        if let seg = root as? NSSegmentedControl { return seg }
        for sub in root.subviews {
            if let found = findSegmentedControl(under: sub) { return found }
        }
        return nil
    }

    private func sectionSelector(in window: NSWindow) -> NSSegmentedControl? {
        guard let root = window.contentView?.superview ?? window.contentView else { return nil }
        return findSegmentedControl(under: root)
    }

    private func segmentLabels(_ control: NSSegmentedControl) -> [String] {
        (0..<control.segmentCount).map { control.label(forSegment: $0) ?? "<nil>" }
    }

    /// Click a section in the selector (select the segment, deliver its action).
    private func selectSection(_ label: String, in window: NSWindow) throws {
        pump(until: 2.0) { self.sectionSelector(in: window) != nil }
        let control = try XCTUnwrap(
            sectionSelector(in: window),
            "no section selector (NSSegmentedControl) found in the Settings window")
        let index = try XCTUnwrap(
            (0..<control.segmentCount).first(where: { control.label(forSegment: $0) == label }),
            "section selector has no '\(label)' segment; labels = \(segmentLabels(control))")
        control.selectedSegment = index
        if let action = control.action {
            _ = control.sendAction(action, to: control.target)
        } else {
            control.performClick(nil)
        }
        pump(for: 0.5)
    }

    private func selectedSectionLabel(in window: NSWindow) -> String? {
        guard let control = sectionSelector(in: window), control.selectedSegment >= 0 else { return nil }
        return control.label(forSegment: control.selectedSegment)
    }

    /// Put the Diagnostics section on screen with a list loaded from the
    /// CURRENT contents of disk, whatever state the (process-wide, reused)
    /// Settings window was left in: switch to another section and back, which
    /// builds a fresh Diagnostics view.
    private func freshlyNavigateToDiagnostics(in window: NSWindow) throws {
        try selectSection(Self.otherPaneLabel, in: window)
        try selectSection(Self.diagnosticsLabel, in: window)
    }

    // MARK: - On-screen row count via the accessibility tree

    /// Walks the window's NSView subtree and every accessibility-children
    /// edge (SwiftUI's `AccessibilityNode`s do not formally conform to
    /// `NSAccessibilityProtocol`, so everything goes through KVC), counting
    /// distinct nodes whose label, title or string value is exactly `needle`.
    @MainActor
    private final class AXCounter {
        private(set) var matches = 0
        private var visited = Set<ObjectIdentifier>()
        private let needle: String

        init(needle: String) { self.needle = needle }

        private func string(_ node: NSObject, _ key: String) -> String? {
            guard node.responds(to: NSSelectorFromString(key)) else { return nil }
            return node.value(forKey: key) as? String
        }

        func visit(_ object: AnyObject, depth: Int) {
            guard depth < 40, visited.count < 8000 else { return }
            guard visited.insert(ObjectIdentifier(object)).inserted else { return }
            if let node = object as? NSObject {
                if string(node, "accessibilityLabel") == needle
                    || string(node, "accessibilityTitle") == needle
                    || string(node, "accessibilityValue") == needle {
                    matches += 1
                }
                if node.responds(to: NSSelectorFromString("accessibilityChildren")),
                   let children = node.value(forKey: "accessibilityChildren") as? [AnyObject] {
                    for child in children { visit(child, depth: depth + 1) }
                }
            }
            if let view = object as? NSView {
                for sub in view.subviews { visit(sub, depth: depth + 1) }
            }
        }
    }

    /// Number of "Actions" menu labels exposed by the window (one per report
    /// row currently on screen, times a constant `perRow` factor).
    private func rowMenuCount(in window: NSWindow) -> Int {
        guard let root = window.contentView else { return 0 }
        let counter = AXCounter(needle: Self.rowMenuLabel)
        counter.visit(root, depth: 0)
        return counter.matches
    }

    // MARK: - Shared scenario

    /// How many reports are on disk when the user first looks at Diagnostics.
    private enum Baseline {
        /// Empty list ("No diagnostics yet").
        case empty
        /// One older report is listed.
        case oneReport
    }

    /// The whole contract, end to end:
    ///  1. open Settings, land on Diagnostics (list loaded from disk);
    ///  2. close the window;
    ///  3. a new report (`newName` in `newDirectory`) appears on disk;
    ///  4. reopen Settings; the Diagnostics list on screen must show it.
    private func assertNewReportIsListedAfterReopen(
        baseline: Baseline, newName: String, newDirectory: (Sandbox) -> URL, kind: String
    ) throws {
        let keeper = showKeeperWindow()
        defer { retireKeeperWindow(keeper) }
        let sandbox = try Sandbox()
        defer { sandbox.restore() }

        // Precondition: the process home really is the throwaway one.
        XCTAssertEqual(
            FileManager.default.homeDirectoryForCurrentUser.resolvingSymlinksInPath().path,
            sandbox.home.resolvingSymlinksInPath().path,
            "precondition: CFFIXED_USER_HOME redirect must make the throwaway dir the process home, "
            + "otherwise the Diagnostics view would read the real ~/Library/Logs")

        // --- Calibration + channel-liveness proof: exactly one report on disk.
        try sandbox.writeReport(named: Self.seedHangFileName, in: sandbox.hangDirectory)
        let window = try openSettings()
        defer { closeSettings(window) }
        try freshlyNavigateToDiagnostics(in: window)
        XCTAssertEqual(selectedSectionLabel(in: window), Self.diagnosticsLabel,
                       "precondition: Diagnostics must be the selected section")
        pump(until: 3.0) { self.rowMenuCount(in: window) >= 1 }
        pump(for: 0.3)
        let perRow = rowMenuCount(in: window)
        XCTAssertGreaterThanOrEqual(
            perRow, 1,
            "precondition: with exactly one report on disk the Diagnostics list must expose at least one "
            + "'\(Self.rowMenuLabel)' menu label in the accessibility tree (measured \(perRow)); without it "
            + "the on-screen row count cannot be observed")
        guard perRow >= 1 else { return }

        // --- Baseline the user looks at before closing.
        var rowsBeforeClose = 1
        if baseline == .empty {
            try sandbox.removeReport(named: Self.seedHangFileName, in: sandbox.hangDirectory)
            try freshlyNavigateToDiagnostics(in: window)   // documented workaround: fresh section
            pump(for: 0.5)
            rowsBeforeClose = 0
        }
        XCTAssertEqual(selectedSectionLabel(in: window), Self.diagnosticsLabel,
                       "precondition: Diagnostics must be the selected section before closing")
        XCTAssertEqual(rowMenuCount(in: window), rowsBeforeClose * perRow,
                       "precondition: before closing, the Diagnostics list must show \(rowsBeforeClose) "
                       + "report row(s) (perRow factor \(perRow))")

        // --- Close (Cmd-W / Esc).
        closeSettings(window)
        XCTAssertFalse(window.isVisible, "precondition: Settings window must be closed")

        // --- A new report appears while the window is closed.
        try sandbox.writeReport(named: newName, in: newDirectory(sandbox))
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: newDirectory(sandbox).appendingPathComponent(newName).path),
            "precondition: the new report file must exist on disk")
        pump(for: 0.3)

        // --- Reopen the way the user does (Cmd-,). If the window comes back
        // on another section the user clicks Diagnostics; if it comes back on
        // Diagnostics nothing else is touched (no Refresh, no section hop).
        let reopened = try openSettings()
        XCTAssertTrue(reopened === window, "the Settings window is built once and reused")
        pump(until: 2.0) { self.sectionSelector(in: reopened) != nil }
        if selectedSectionLabel(in: reopened) != Self.diagnosticsLabel {
            try selectSection(Self.diagnosticsLabel, in: reopened)
        }
        XCTAssertEqual(selectedSectionLabel(in: reopened), Self.diagnosticsLabel,
                       "the Diagnostics section must be the one on screen after reopening")

        // --- The list on screen must now include the new report. Give any
        // reload mechanism (appear / become-key / reopen hook) time to land.
        let expectedRows = rowsBeforeClose + 1
        let reached = pump(until: 3.0) { self.rowMenuCount(in: reopened) == expectedRows * perRow }
        pump(for: 0.3)
        let finalCount = rowMenuCount(in: reopened)
        XCTAssertEqual(
            finalCount, expectedRows * perRow,
            "after closing and reopening Settings on Diagnostics, the \(kind) report '\(newName)' written "
            + "while the window was closed is not listed: on screen \(finalCount / perRow) report row(s) "
            + "('\(Self.rowMenuLabel)' labels \(finalCount), perRow \(perRow)), expected \(expectedRows) "
            + "(stale list; settled within poll: \(reached))")
    }

    // MARK: - Tests

    /// The headline bug: a hang report written while Settings was closed must
    /// be listed when Settings is reopened on Diagnostics (older report was
    /// already listed).
    func test_hangReportWrittenWhileSettingsClosed_isListedAfterReopen() throws {
        try assertNewReportIsListedAfterReopen(
            baseline: .oneReport, newName: Self.newHangFileName,
            newDirectory: { $0.hangDirectory }, kind: "hang")
    }

    /// Same contract for a macOS crash report (`Blackbird-*.ips` in
    /// `~/Library/Logs/DiagnosticReports`).
    func test_crashReportWrittenWhileSettingsClosed_isListedAfterReopen() throws {
        try assertNewReportIsListedAfterReopen(
            baseline: .oneReport, newName: Self.newCrashFileName,
            newDirectory: { $0.crashDirectory }, kind: "crash")
    }

    /// The "No diagnostics yet" form of the bug: the empty state must not
    /// survive a reopen once a report exists.
    func test_hangReportWrittenWhileSettingsClosed_replacesEmptyStateAfterReopen() throws {
        try assertNewReportIsListedAfterReopen(
            baseline: .empty, newName: Self.newHangFileName,
            newDirectory: { $0.hangDirectory }, kind: "hang")
    }

    /// Control (passes with or without the bug): a freshly built Diagnostics
    /// section lists every report on disk, so the row-count channel and the
    /// home redirect scale with the number of files (two files -> twice the
    /// one-file label count).
    func test_control_freshDiagnosticsSectionRowCountScalesWithReportsOnDisk() throws {
        let keeper = showKeeperWindow()
        defer { retireKeeperWindow(keeper) }
        let sandbox = try Sandbox()
        defer { sandbox.restore() }
        XCTAssertEqual(
            FileManager.default.homeDirectoryForCurrentUser.resolvingSymlinksInPath().path,
            sandbox.home.resolvingSymlinksInPath().path,
            "precondition: the throwaway dir must be the process home")

        try sandbox.writeReport(named: Self.seedHangFileName, in: sandbox.hangDirectory)
        let window = try openSettings()
        defer { closeSettings(window) }
        try freshlyNavigateToDiagnostics(in: window)
        pump(until: 3.0) { self.rowMenuCount(in: window) >= 1 }
        pump(for: 0.3)
        let oneFile = rowMenuCount(in: window)
        XCTAssertGreaterThanOrEqual(oneFile, 1, "one report on disk -> at least one row menu label")

        try sandbox.writeReport(named: Self.newCrashFileName, in: sandbox.crashDirectory)
        try freshlyNavigateToDiagnostics(in: window)
        pump(until: 3.0) { self.rowMenuCount(in: window) >= 2 * oneFile }
        pump(for: 0.3)
        XCTAssertEqual(rowMenuCount(in: window), 2 * oneFile,
                       "two reports on disk (one hang + one crash) must show twice the one-report label count")
    }
}
