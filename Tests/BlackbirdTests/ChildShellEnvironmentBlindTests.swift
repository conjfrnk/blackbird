import XCTest
import AppKit
import Darwin
@testable import Blackbird

/// Blind regression test for mpe-5: the program a tab runs and the `$SHELL`
/// that tab's processes see must agree.
///
/// Observable contract (terminal / macOS conventions):
///
///   `$SHELL` is "the user's shell", and a tool that wants to run it (tmux
///   `default-shell`, vim/neovim `'shell'`, `sudo -s`, git/ssh helpers) reads
///   it from the environment. `login(1)` (and therefore Terminal.app) exports
///   `SHELL=<the shell it is about to exec>` regardless of what the launcher
///   had in its own environment. A terminal that runs `/bin/bash` in a tab
///   while leaving the launcher's `SHELL=/bin/zsh` in that tab's environment
///   makes `tmux`, `sudo -s`, ... start a different shell from the one on
///   screen, so Settings > Shell (CHANGELOG 0.9.x: "empty = the account's
///   login shell from the passwd database ... `$SHELL` inherited from
///   whatever launched Blackbird decided") is only half honoured.
///
///   Therefore, whichever program the tab is told to run:
///     - the Settings > Shell preference (when it names an executable), or
///     - the passwd login shell (empty preference; also the situation after
///       `chsh -s` without logging out and back in, or when Blackbird was
///       started from Finder / the Dock / a login item with a stale SHELL),
///   the child's `$SHELL` is that program's path, byte for byte, whatever
///   `SHELL` the Blackbird process itself carried (set to another shell, or
///   not set at all).
///
/// How the child's `$SHELL` is observed:
///   - Preference tests: Settings > Shell is pointed at a tiny executable
///     named `bash` (a `#!/bin/dash` script: dash, unlike bash-as-sh, does
///     not invent a missing `SHELL`) that records `$SHELL` into a file and
///     then `exec`s `/bin/cat` (stays alive on the pty until the session is
///     terminated). The shell the tab runs is, by construction, that file's
///     own path.
///   - Empty-preference test: the real passwd login shell is spawned (a
///     platform binary, whose exec-time environment the kernel refuses to
///     show), so the test types a `printf` of `$SHELL` into the tab through
///     `TerminalSession.send` and reads the answer from the raw pty bytes.
///
/// Safety / cost pre-flight (per CLAUDE.md test-authoring rules):
///   - The preference is injected through `UserDefaults`' in-memory argument
///     domain (the layer `-bb.shellPath foo` on the command line writes
///     to) and is NEVER persisted: the xctest host is Blackbird.app itself.
///   - At most ONE real `MainWindowController` is alive at any time (static
///     slot ratchet, same as `CustomShellDiesAtStartupBlindTests`); each
///     test tears its controller down and releases the slot before it
///     returns.
///   - The process-wide `SHELL` variable is changed with setenv/unsetenv and
///     restored in a teardown block.
///   - Memory: one window + one Metal view (a few MB), one `/bin/cat` or
///     one login shell, a few KiB of captured pty bytes. Time: each test
///     <= ~15 s worst case (polling is exited as soon as the observation is
///     available, normally well under 1 s plus window creation; a slow
///     login-shell rc file is the only thing that stretches it).
final class ChildShellEnvironmentBlindTests: XCTestCase {

    // MARK: - One-live-controller ratchet

    private static var liveControllerCount = 0
    private static let liveControllerLock = NSLock()

    private static func acquireControllerSlot() {
        liveControllerLock.lock()
        defer { liveControllerLock.unlock() }
        precondition(
            liveControllerCount == 0,
            "ChildShellEnvironmentBlindTests: a previous test left a real "
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

    /// Sentinel the recorder writes when the child has no `SHELL` at all.
    private static let unsetMarker = "<SHELL-not-set-in-child>"

    /// Longest we wait for the recorder file to appear.
    private static let observationSeconds: TimeInterval = 10.0

    /// Longest we wait for a real login shell (user rc files!) to answer.
    private static let loginShellSeconds: TimeInterval = 20.0

    private var scratchDir: URL?

    /// Per-test scratch directory, symlink-resolved (`/var` -> `/private/var`)
    /// so the path handed to Settings is also its canonical path and a
    /// correct fix cannot be failed by a realpath() round trip.
    private func makeScratchDirectory() throws -> URL {
        if let existing = scratchDir { return existing }
        let base = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
        let dir = base.appendingPathComponent(
            "bb-childshell-blind-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        scratchDir = dir
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    /// Writes an executable named `bash` that records the `SHELL` it was
    /// started with into `outputPath` (atomically, via rename) and then
    /// replaces itself with `/bin/cat`, which sits on the pty until hung up.
    /// The interpreter is dash on purpose: bash (what `/bin/sh` is on macOS)
    /// assigns the passwd login shell to an unset `SHELL` and would hide the
    /// "launcher had no SHELL" case.
    private func makeRecorderShell(outputPath: String) throws -> String {
        guard FileManager.default.isExecutableFile(atPath: "/bin/dash") else {
            throw XCTSkip("/bin/dash is not available on this host")
        }
        let dir = try makeScratchDirectory()
        let url = dir.appendingPathComponent("bash")
        let script = """
            #!/bin/dash
            printf '%s' "${SHELL-\(Self.unsetMarker)}" > '\(outputPath).tmp'
            /bin/mv '\(outputPath).tmp' '\(outputPath)'
            exec /bin/cat
            """
        try Data((script + "\n").utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url.path
    }

    /// Overrides `bb.shellPath` for this process only (argument domain),
    /// restoring the prior domain contents on teardown.
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

    /// Sets (or, for nil, removes) `SHELL` in this process's own environment
    /// -- what Blackbird "inherited from the launcher" -- and restores the
    /// original on teardown.
    private func setLauncherSHELL(_ value: String?) {
        let original: String? = getenv("SHELL").map { String(cString: $0) }
        if let value = value {
            setenv("SHELL", value, 1)
        } else {
            unsetenv("SHELL")
        }
        addTeardownBlock {
            if let original = original {
                setenv("SHELL", original, 1)
            } else {
                unsetenv("SHELL")
            }
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

    /// Creates the one real controller (exactly what App does for a new
    /// window), runs `body`, and tears everything down. Skips on hosts with
    /// no Metal device (the controller then has no view / session).
    private func withLiveController(_ body: (MainWindowController) throws -> Void) throws {
        Self.acquireControllerSlot()
        defer { Self.releaseControllerSlot() }

        let controller = MainWindowController(initialWorkingDirectory: nil, autosaveFrame: false)
        guard controller.terminalView != nil, controller.session != nil else {
            controller.terminateSessions()
            controller.window?.close()
            throw XCTSkip("no Metal device (CI virtual display): the controller has no TerminalView / session")
        }
        defer {
            controller.terminateSessions()
            if !controller.isClosing { controller.window?.close() }
        }
        try body(controller)
    }

    // MARK: - Raw pty byte capture

    /// Accumulates every byte the tab's child writes to the pty.
    private final class ByteCapture {
        private let lock = NSLock()
        private var bytes = Data()
        func append(_ data: Data) {
            lock.lock()
            bytes.append(data)
            lock.unlock()
        }
        var text: String {
            lock.lock()
            defer { lock.unlock() }
            return String(decoding: bytes, as: UTF8.self)
        }
        var byteCount: Int {
            lock.lock()
            defer { lock.unlock() }
            return bytes.count
        }
    }

    /// Passwd login shell of the current user (`getpwuid().pw_shell`).
    private static func passwdLoginShell() -> String? {
        guard let entry = getpwuid(getuid()), let shell = entry.pointee.pw_shell else { return nil }
        let path = String(cString: shell)
        return path.isEmpty ? nil : path
    }

    // MARK: - Tests

    /// Settings > Shell names a shell that differs from the launcher's
    /// `SHELL` (Finder / Dock launch: `SHELL=/bin/zsh`). The tab runs the
    /// configured shell, so that is what the tab's `$SHELL` must say.
    func testSettingsShellPreferenceIsExportedAsSHELLWhenLauncherHasADifferentSHELL() throws {
        let outputPath = try makeScratchDirectory().appendingPathComponent("recorded-shell.txt").path
        let shellPath = try makeRecorderShell(outputPath: outputPath)
        try assertRecorderSeesItsOwnPathAsSHELL(
            shellPath: shellPath, outputPath: outputPath,
            launcherSHELL: "/bin/zsh", label: "launcher SHELL=/bin/zsh")
    }

    /// Same, when the launcher exported no `SHELL` at all. `login(1)` sets
    /// `SHELL` unconditionally, so a tab running the configured shell must
    /// have `$SHELL` pointing at it rather than no `$SHELL`.
    func testSettingsShellPreferenceIsExportedAsSHELLWhenLauncherHasNoSHELL() throws {
        let outputPath = try makeScratchDirectory().appendingPathComponent("recorded-shell.txt").path
        let shellPath = try makeRecorderShell(outputPath: outputPath)
        try assertRecorderSeesItsOwnPathAsSHELL(
            shellPath: shellPath, outputPath: outputPath,
            launcherSHELL: nil, label: "launcher has no SHELL")
    }

    /// Runs the recorder as a plain child (stdin at EOF so `cat` ends), waits
    /// for it, returns what it recorded and removes the record.
    private func runRecorderDirectly(
        shellPath: String, outputPath: String, environment: [String: String]
    ) throws -> String? {
        try? FileManager.default.removeItem(atPath: outputPath)
        let probe = Process()
        probe.executableURL = URL(fileURLWithPath: shellPath)
        probe.environment = environment
        probe.standardInput = FileHandle.nullDevice
        probe.standardOutput = FileHandle.nullDevice
        probe.standardError = FileHandle.nullDevice
        try probe.run()
        let started = Date()
        while probe.isRunning && Date().timeIntervalSince(started) < 5.0 {
            Thread.sleep(forTimeInterval: 0.005)
        }
        if probe.isRunning { probe.terminate() }
        let recorded = try? String(contentsOfFile: outputPath, encoding: .utf8)
        try? FileManager.default.removeItem(atPath: outputPath)
        return recorded
    }

    private func assertRecorderSeesItsOwnPathAsSHELL(
        shellPath: String,
        outputPath: String,
        launcherSHELL: String?,
        label: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        // Rig precondition 1: the recorder is an executable regular file
        // Settings will accept as a Shell.
        XCTAssertTrue(ShellResolver.isExecutableFile(shellPath),
                      "[\(label)] rig precondition: \(shellPath) must be an executable regular file",
                      file: file, line: line)

        // Rig precondition 2: run on its own, the recorder faithfully writes
        // the SHELL it was handed, and a distinct marker when it was handed
        // none (so a mismatch later is the app's doing, not the recorder's).
        let withSentinel = try runRecorderDirectly(
            shellPath: shellPath, outputPath: outputPath, environment: ["SHELL": "/probe/sentinel-shell"])
        XCTAssertEqual(withSentinel, "/probe/sentinel-shell",
                       "[\(label)] rig precondition: running the recorder directly must record the SHELL it was given",
                       file: file, line: line)
        let withoutShell = try runRecorderDirectly(
            shellPath: shellPath, outputPath: outputPath, environment: [:])
        XCTAssertEqual(withoutShell, Self.unsetMarker,
                       "[\(label)] rig precondition: running the recorder with no SHELL must record the unset marker, not an invented value",
                       file: file, line: line)

        // The launcher's SHELL (what Blackbird "inherited"), then the preference.
        setLauncherSHELL(launcherSHELL)
        overrideShellPreference(with: shellPath)
        XCTAssertEqual(Preferences.shared.shellPath, shellPath,
                       "[\(label)] rig precondition: Preferences.shared.shellPath must read the injected value",
                       file: file, line: line)

        try withLiveController { (_: MainWindowController) throws -> Void in
            pumpRunLoop(for: Self.observationSeconds) { () -> Bool in
                return FileManager.default.fileExists(atPath: outputPath)
            }
            let recorderRan = FileManager.default.fileExists(atPath: outputPath)
            XCTAssertTrue(recorderRan,
                          "[\(label)] the configured Shell \(shellPath) never ran inside the tab within "
                              + "\(Int(Self.observationSeconds)) s, so its environment could not be observed",
                          file: file, line: line)
            let recorded = try? String(contentsOfFile: outputPath, encoding: .utf8)
            XCTAssertEqual(
                recorded, shellPath,
                "[\(label)] the tab ran Settings > Shell = \(shellPath), but that process's $SHELL is "
                    + "\(recorded.map { "'\($0)'" } ?? "nil") (launcher's own SHELL was "
                    + "\(launcherSHELL.map { "'\($0)'" } ?? "unset")). tmux default-shell, vim 'shell' and "
                    + "`sudo -s` read $SHELL, so they would start a different shell than the tab runs; "
                    + "login(1) / Terminal.app export SHELL=<the shell it execs>.",
                file: file, line: line)
        }
    }

    /// Settings > Shell empty: the tab runs the passwd login shell. The
    /// launcher's `SHELL` is stale (Finder launch before `chsh -s`, or a
    /// different shell exported where Blackbird was started). The login
    /// shell is what the tab runs, so the `$SHELL` it reports must be its
    /// own path, not the stale one.
    func testPasswdLoginShellIsExportedAsSHELLWhenPreferenceIsEmptyAndLauncherSHELLIsStale() throws {
        // Rig precondition: the passwd login shell is a usable absolute program.
        let loginShell = try XCTUnwrap(Self.passwdLoginShell(),
                                       "rig precondition: getpwuid().pw_shell must be non-empty")
        guard loginShell.hasPrefix("/"), ShellResolver.isExecutableFile(loginShell) else {
            throw XCTSkip("passwd login shell '\(loginShell)' is not an absolute executable; empty-preference path would not use it")
        }
        // The probe line (`printf` with a quoted variable) is understood by the
        // mainstream login shells; skip the exotic ones (nu, xonsh, elvish, ...).
        let shellName = (loginShell as NSString).lastPathComponent
        let supportedNames: Set<String> = ["zsh", "bash", "sh", "dash", "ksh", "fish", "tcsh", "csh"]
        guard supportedNames.contains(shellName) else {
            throw XCTSkip("login shell '\(shellName)' does not take a POSIX printf probe line")
        }
        let staleCandidates = ["/bin/sh", "/bin/bash", "/bin/dash", "/bin/ksh", "/bin/tcsh", "/bin/zsh"]
        let stale = try XCTUnwrap(
            staleCandidates.first(where: { (candidate: String) -> Bool in
                candidate != loginShell && ShellResolver.isExecutableFile(candidate)
            }),
            "rig precondition: need an executable shell different from the login shell \(loginShell) to play the stale launcher SHELL")

        setLauncherSHELL(stale)
        overrideShellPreference(with: "")
        XCTAssertEqual(Preferences.shared.shellPath, "",
                       "rig precondition: the Shell preference must read empty (= login shell)")

        try withLiveController { (controller: MainWindowController) throws -> Void in
            let session = try XCTUnwrap(controller.session, "controller must own a session")
            let pty = try XCTUnwrap(session.pty, "session must own a pty")

            // Tap the raw pty bytes without disturbing the session's own feed.
            let capture = ByteCapture()
            let original = pty.onBytes
            pty.setOnBytes { (data: Data) -> Void in
                capture.append(data)
                original?(data)
            }

            // The nonce is passed as an argument so the tty's echo of the typed
            // line ("BBSH%s:%s") can never be mistaken for the answer ("BBSH7421:...").
            let nonce = "7421"
            let probeLine = "printf 'BBSH%s:%s\\n' \(nonce) \"$SHELL\"\r"
            let answerPrefix = "BBSH\(nonce):"
            func answer() -> String? {
                let text = capture.text
                guard let r = text.range(of: answerPrefix) else { return nil }
                // Scalars, not Characters: "\r\n" is ONE Character.
                let rest: Substring.UnicodeScalarView = text[r.upperBound...].unicodeScalars
                let line: Substring.UnicodeScalarView = rest.prefix(while: { (u: Unicode.Scalar) -> Bool in
                    u != "\r" && u != "\n" && u != "\u{1B}"
                })
                // No terminator yet: the answer is still arriving.
                guard line.count < rest.count else { return nil }
                return String(Substring(line))
            }

            // Type-ahead is kept by the tty until the shell reads it; resend
            // every ~4 s in case a slow rc file swallowed the first attempt.
            var sends = 0
            var lastSend = Date.distantPast
            let deadline = Date().addingTimeInterval(Self.loginShellSeconds)
            while Date() < deadline && answer() == nil {
                if Date().timeIntervalSince(lastSend) > 4.0 {
                    session.send(Data(probeLine.utf8))
                    sends += 1
                    lastSend = Date()
                }
                RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
            }

            let reported = answer()
            let tail = String(capture.text.suffix(300))
            XCTAssertTrue(reported != nil,
                          "the login shell \(loginShell) never answered the `$SHELL` probe within "
                              + "\(Int(Self.loginShellSeconds)) s (\(sends) probe(s) sent, \(capture.byteCount) pty bytes seen); "
                              + "output tail: \(tail.debugDescription)")
            XCTAssertEqual(
                reported, loginShell,
                "Settings > Shell is empty, so the tab runs the passwd login shell \(loginShell), "
                    + "but `echo $SHELL` in that tab prints \(reported.map { "'\($0)'" } ?? "nothing") "
                    + "(launcher's own SHELL was '\(stale)'). tmux default-shell, vim 'shell' and `sudo -s` "
                    + "read $SHELL; login(1) / Terminal.app export SHELL=<the shell it execs>.")
        }
    }
}
