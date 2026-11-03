import XCTest
import AppKit
@testable import Blackbird

/// Blind regression test for settings-persistence-1: a custom Shell
/// (Settings > Behavior > Shell, pref `bb.shellPath`) that is an executable
/// regular file but dies at startup must not make Blackbird quit.
///
/// Observable contract (terminal / macOS conventions):
///
///   A new window whose configured program exits within moments of being
///   spawned is a startup failure, not a user typing `exit`. Terminal
///   emulators keep the window up (iTerm2 "[Process completed]", Terminal.app
///   "close only if the shell exited cleanly") and a startup failure of the
///   user's own configured program must not silently vanish. In Blackbird the
///   last window closing quits the app
///   (`applicationShouldTerminateAfterLastWindowClosed`), so the window
///   flashing and closing means the app quits on every launch and every new
///   tab / window flashes and closes, with the only recovery being
///   `defaults delete dev.conjfrnk.blackbird bb.shellPath` from some other
///   terminal.
///
///   Any sound fix satisfies "the window is still open a couple of seconds
///   later": falling back to the login shell, keeping the window up with the
///   exit status shown, or a Retry / Close sheet. None of them lets the window
///   close on its own. The test therefore asserts only that, and prints the
///   measured close latency when it fails.
///
/// Programs under test (all executable regular files that spawn fine but
/// die at startup, exactly the Trigger in the bug report):
///   1. `/usr/bin/false`                      (exits 1 immediately)
///   2. a `#!/bin/sh` script that `exec`s a binary that does not exist
///   3. a +x script with no shebang           (the kernel rejects the exec)
///   4. `/usr/bin/true`                       (exits 0 immediately)
///   5. a `#!/bin/sh` wrapper that runs a setup command and falls off the
///      end without `exec`ing a shell        (exits with that command's
///      status, usually 0)
/// The exit status is irrelevant: a program that is gone within moments of
/// being spawned never gave the user a prompt, whatever it returned.
///
/// Safety / cost pre-flight (per CLAUDE.md test-authoring rules):
///   - The preference is injected through `UserDefaults`' in-memory
///     argument domain (the same layer `-bb.shellPath foo` on the command
///     line writes to). It is NEVER persisted: the xctest host is
///     Blackbird.app itself, so persisting `/usr/bin/false` into
///     `dev.conjfrnk.blackbird` and then dying (this very bug can terminate
///     the host) would brick the developer's real app on next launch.
///   - At most ONE real `MainWindowController` is alive at any time (a
///     static slot ratchet, same pattern as `MainWindowControllerLifetimeTests`);
///     each test creates one, tears it down and releases the slot before
///     returning. The failing programs never reach a prompt; on the fixed
///     path a fallback may start one real login shell, which
///     `terminateSessions()` ends.
///   - Memory: one window + one Metal view (a few MB). Time: <= 2.2 s per
///     test (a 2 s observation window, exited early when the window closes);
///     the helper `Process` precondition runs tiny binaries, < 50 ms.
final class CustomShellDiesAtStartupBlindTests: XCTestCase {

    // MARK: - One-live-controller ratchet

    private static var liveControllerCount = 0
    private static let liveControllerLock = NSLock()

    private static func acquireControllerSlot() {
        liveControllerLock.lock()
        defer { liveControllerLock.unlock() }
        precondition(
            liveControllerCount == 0,
            "CustomShellDiesAtStartupBlindTests: a previous test left a real "
                + "MainWindowController alive; at most ONE may exist."
        )
        liveControllerCount = 1
    }

    private static func releaseControllerSlot() {
        liveControllerLock.lock()
        defer { liveControllerLock.unlock() }
        liveControllerCount = max(0, liveControllerCount - 1)
    }

    override class func setUp() {
        super.setUp()
        TestHostTermination.shared.register()
    }

    // MARK: - Fixtures

    /// How long the window gets to stay open before we call it survived.
    /// The reported auto-close latency is 25 ms to 0.3 s; 2 s leaves a wide
    /// margin for a slow CI runner without making the passing path slow.
    private static let observationSeconds: TimeInterval = 2.0

    private var scratchDir: URL?

    /// Writes an executable file (mode 0755) with `contents` and returns its
    /// absolute path.
    private func makeExecutable(named name: String, contents: String) throws -> String {
        let dir: URL
        if let existing = scratchDir {
            dir = existing
        } else {
            dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("bb-customshell-blind-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            scratchDir = dir
            addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        }
        let url = dir.appendingPathComponent(name)
        try Data(contents.utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url.path
    }

    /// Overrides `bb.shellPath` for this process only, via the in-memory
    /// argument domain. Restores the prior domain contents on teardown.
    private func overrideShellPreference(with path: String) {
        let defaults = UserDefaults.standard
        let domainName = UserDefaults.argumentDomain
        let saved: [String: Any] = defaults.volatileDomain(forName: domainName)
        var merged: [String: Any] = saved
        merged["bb.shellPath"] = path
        defaults.removeVolatileDomain(forName: domainName)
        defaults.setVolatileDomain(merged, forName: domainName)
        addTeardownBlock {
            defaults.removeVolatileDomain(forName: domainName)
            defaults.setVolatileDomain(saved, forName: domainName)
        }
    }

    /// Spins the main runloop in 20 ms slices until `condition` is true or
    /// `seconds` elapse. Returns the elapsed milliseconds at exit.
    @discardableResult
    private func pumpRunLoop(for seconds: TimeInterval, until condition: () -> Bool) -> Int {
        let start = Date()
        let deadline = start.addingTimeInterval(seconds)
        while Date() < deadline && !condition() {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.02))
        }
        return Int(Date().timeIntervalSince(start) * 1000)
    }

    // MARK: - The scenario

    /// Launch a real window whose configured Shell is `shellPath` and report
    /// whether (and when) the window closed on its own.
    private func assertWindowSurvivesStartupDeath(
        ofShell shellPath: String,
        label: String,
        mayExitZero: Bool = false,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        // Rig precondition: the program really is an executable regular file
        // (so Settings accepts it and the resolver may pick it) ...
        XCTAssertTrue(ShellResolver.isExecutableFile(shellPath),
                      "[\(label)] rig precondition: \(shellPath) must be an executable regular file",
                      file: file, line: line)

        // ... and the program really does die at startup when run on its own.
        let probe = Process()
        probe.executableURL = URL(fileURLWithPath: shellPath)
        probe.standardInput = FileHandle.nullDevice
        probe.standardOutput = FileHandle.nullDevice
        probe.standardError = FileHandle.nullDevice
        var probeDiedAtStartup = false
        do {
            try probe.run()
            let started = Date()
            while probe.isRunning && Date().timeIntervalSince(started) < 2.0 {
                Thread.sleep(forTimeInterval: 0.005)
            }
            probeDiedAtStartup = !probe.isRunning && (mayExitZero || probe.terminationStatus != 0)
            if probe.isRunning { probe.terminate() }
        } catch {
            // The kernel refused the exec (no shebang): also "dies at startup".
            probeDiedAtStartup = true
        }
        XCTAssertTrue(probeDiedAtStartup,
                      "[\(label)] rig precondition: \(shellPath) must exit (non-zero unless mayExitZero) or fail to exec on its own within 2 s",
                      file: file, line: line)

        // The preference must actually be seen by the code that resolves the shell.
        overrideShellPreference(with: shellPath)
        XCTAssertEqual(Preferences.shared.shellPath, shellPath,
                       "[\(label)] rig precondition: Preferences.shared.shellPath must read the injected value",
                       file: file, line: line)

        Self.acquireControllerSlot()
        defer { Self.releaseControllerSlot() }

        // Exactly what App does for a new window / the first window at launch.
        let controller = MainWindowController(initialWorkingDirectory: nil, autosaveFrame: false)
        guard controller.terminalView != nil, controller.session != nil else {
            controller.terminateSessions()
            controller.window?.close()
            throw XCTSkip("no Metal device (CI virtual display): the controller has no TerminalView / session")
        }
        let window = try XCTUnwrap(controller.window, "[\(label)] controller must own a window")

        var closedAfterMs: Int?
        let launchedAt = Date()
        let closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: window, queue: .main
        ) { _ in
            if closedAfterMs == nil {
                closedAfterMs = Int(Date().timeIntervalSince(launchedAt) * 1000)
            }
        }
        defer {
            NotificationCenter.default.removeObserver(closeObserver)
            controller.terminateSessions()
            if !controller.isClosing { window.close() }
        }

        let observedMs = pumpRunLoop(for: Self.observationSeconds) {
            closedAfterMs != nil || controller.isClosing
        }

        let expectedNoClose: Int? = nil
        XCTAssertEqual(
            closedAfterMs, expectedNoClose,
            "[\(label)] the window closed itself \(closedAfterMs.map(String.init) ?? "nil") ms after launch "
                + "(isClosing=\(controller.isClosing)): Settings > Shell = \(shellPath) is an executable that dies "
                + "at startup, and the last window closing quits the app, so Blackbird quits on every launch "
                + "with no feedback. A startup failure of the configured shell must leave the window open "
                + "(login-shell fallback, exit status shown, or a retry/close sheet).",
            file: file, line: line
        )
        XCTAssertFalse(
            controller.isClosing,
            "[\(label)] the controller is tearing its window down (observed for \(observedMs) ms of a "
                + "\(Int(Self.observationSeconds * 1000)) ms window); a configured shell that dies at startup "
                + "must not take the window (and the app) with it",
            file: file, line: line
        )
    }

    // MARK: - Tests

    /// The exact Trigger example: `/usr/bin/false`.
    func testWindowSurvivesWhenCustomShellIsUsrBinFalse() throws {
        try assertWindowSurvivesStartupDeath(ofShell: "/usr/bin/false", label: "/usr/bin/false")
    }

    /// A +x script whose `exec` target is missing: the program starts, then
    /// dies a few milliseconds later.
    func testWindowSurvivesWhenCustomShellExecsAMissingBinary() throws {
        let script = try makeExecutable(
            named: "exec-missing.sh",
            contents: "#!/bin/sh\nexec /nonexistent/bb-no-such-binary-\(UUID().uuidString) \"$@\"\n"
        )
        try assertWindowSurvivesStartupDeath(ofShell: script, label: "exec-missing script")
    }

    /// A +x file with no shebang line: the kernel rejects the exec (ENOEXEC),
    /// so the spawned child dies without ever running a shell.
    func testWindowSurvivesWhenCustomShellScriptHasNoShebang() throws {
        let script = try makeExecutable(
            named: "no-shebang.sh",
            contents: "echo this script has no interpreter line\n"
        )
        try assertWindowSurvivesStartupDeath(ofShell: script, label: "no-shebang script")
    }

    /// A program that exits 0 the moment it starts is the same lock-out: the
    /// status does not make the window any more wanted.
    func testWindowSurvivesWhenCustomShellIsUsrBinTrue() throws {
        try assertWindowSurvivesStartupDeath(
            ofShell: "/usr/bin/true", label: "/usr/bin/true", mayExitZero: true
        )
    }

    /// A +x wrapper that runs a setup command and never `exec`s a shell exits
    /// with that command's status (0 here).
    func testWindowSurvivesWhenCustomShellWrapperExitsZeroWithoutExecingAShell() throws {
        let script = try makeExecutable(
            named: "wrapper-exit-zero.sh",
            contents: "#!/bin/sh\n/usr/bin/true\n"
        )
        try assertWindowSurvivesStartupDeath(
            ofShell: script, label: "exit-0 wrapper script", mayExitZero: true
        )
    }
}
