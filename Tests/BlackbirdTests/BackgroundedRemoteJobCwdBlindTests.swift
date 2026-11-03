import XCTest
import Combine
import Darwin
@testable import Blackbird

/// Blind regression tests for bug pty-3: a backgrounded `ssh` / `kubectl` /
/// `docker` job (started with `&`, so it stays a child of the shell) makes the
/// OSC 7 trust gate drop every cwd update the shell reports at its prompt.
/// New tabs then open in the directory the shell was in before the job
/// started, and the title-bar proxy icon points at that stale directory.
///
/// Contract under test (observable), as corrected by bug pty-3b. The terminal
/// cannot tell which process wrote an OSC 7 to the tty, and a background job
/// can write there (`tostop` is off by default), so the gate stays strict: a
/// remote-shell binary anywhere in the tree, background jobs included, makes
/// the namespace `.remote` and the reported cwd is dropped (the "background
/// job is trusted" half of the original pty-3 fix was reverted; see
/// `OSC7BackgroundJobTrustBlindTests`). What must NOT go stale is Cmd-T: the
/// shell is idle at its prompt, so while such a job is alive
///   1. the foreground namespace of the session is `.remote` (fail-closed);
///   2. `CwdResolver.forNewTab` (Cmd-T) yields the directory the shell is in
///      now, read from the kernel, not the pre-job one.
/// The counterpart must keep holding: when the same binary IS the foreground
/// job, the namespace is `.remote` and a reported cwd is still dropped.
///
/// Rig. One real `TerminalSession` runs `/bin/sh -c <script>` with job control
/// on (`set -m`), exactly what an interactive shell does for `cmd &`: the job
/// gets its own process group and the shell's group stays the terminal's
/// foreground group. The "remote" binary is a copy of `/bin/sleep` placed in a
/// temp directory under the wrapper's name, re-signed ad hoc (`proc_pidpath`
/// reports the real image path, so a symlink or a renamed argv[0] would not be
/// classified; a file copy is, but an unsigned-by-us copy of a platform binary
/// is killed by the kernel). The script is a state machine stepped from the test through
/// `read` on the tty, so the order is deterministic:
///   step 0: report the "before" directory with OSC 7   (no job yet)
///   step 1: start the job in the background             (test waits for exec)
///   step 2: `cd` to "after" and report it with OSC 7   (the prompt hook)
/// Every precondition (job exec'd, child of the shell, in a different process
/// group, shell group is the tty's foreground group, "before" was accepted)
/// is asserted from kernel state before the behaviour is judged, so a rig
/// that silently failed to build the scenario cannot pass vacuously.
///
/// Pre-flight cost (project rule): one live `/bin/sh` plus one `sleep` per
/// session, torn down (and the sleep SIGKILLed) before the test returns;
/// never two sessions at once. A few KB of temp files, no window, no
/// `MainWindowController`, no Metal. Wall time is about a second per session;
/// the failing path ends on explicit timeouts (<= ~10 s).
final class BackgroundedRemoteJobCwdBlindTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        TestHostTermination.shared.register()
    }

    /// Real-shell tests: same gate as the other PTY shell-spawn suites. On the
    /// macOS 15 CI image the rig's backgrounded fake `ssh` is never exec'd
    /// ("precondition: background job ... must have exec'd the fake 'ssh'")
    /// and the PTY reports not running, so the suite is opt-in
    /// (`BB_RUN_FLAKY_PTY_TESTS=1`) until the rig is made CI-proof.
    override func setUpWithError() throws {
        try super.setUpWithError()
        try PTYTests.skipIfFlakyOnCI()
    }

    // MARK: - Rig

    private struct Workspace {
        let root: String
        let bin: String          // directory holding the fake wrapper binary
        let before: String       // cwd before the job starts
        let after: String        // cwd the shell `cd`s to while the job runs
        let state: String        // pid / marker files written by the script
        let tool: String         // wrapper basename, e.g. "ssh"
        var toolPath: String { bin + "/" + tool }
    }

    /// Script arguments: $1 tool path, $2 before, $3 after, $4 state dir.
    /// Raw string so the printf escapes reach the shell untouched
    /// (`\033` = ESC, `\\` = backslash, together the ST terminator ESC \).
    private static let backgroundScript = #"""
    set -m
    echo $$ > "$4/shell.pid"
    printf '\033]7;file://%s\033\\' "$2"
    : > "$4/step0-done"
    read -r _step1
    "$1" 120 &
    echo $! > "$4/job.pid"
    : > "$4/step1-done"
    read -r _step2
    cd "$3" || exit 3
    printf '\033]7;file://%s\033\\' "$3"
    : > "$4/step2-done"
    read -r _hold
    """#

    private static let foregroundScript = #"""
    set -m
    echo $$ > "$4/shell.pid"
    : > "$4/step0-done"
    "$1" 120
    """#

    private var cleanupDirectories: [URL] = []
    private var pidsToKill: [pid_t] = []
    private var sessionsToTerminate: [TerminalSession] = []

    override func tearDown() {
        for pid in pidsToKill where pid > 1 { kill(pid, SIGKILL) }
        pidsToKill.removeAll()
        for s in sessionsToTerminate { s.terminate() }
        sessionsToTerminate.removeAll()
        for dir in cleanupDirectories { try? FileManager.default.removeItem(at: dir) }
        cleanupDirectories.removeAll()
        super.tearDown()
    }

    private func physicalPath(_ path: String) -> String {
        var buf = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard realpath(path, &buf) != nil else { return path }
        return String(cString: buf)
    }

    private func makeWorkspace(tool: String) throws -> Workspace {
        let fm = FileManager.default
        let rootURL = fm.temporaryDirectory
            .appendingPathComponent("bb-bgjobcwd-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: rootURL, withIntermediateDirectories: true)
        cleanupDirectories.append(rootURL)
        let root = physicalPath(rootURL.path)
        let ws = Workspace(root: root, bin: root + "/bin", before: root + "/before",
                           after: root + "/after", state: root + "/state", tool: tool)
        for dir in [ws.bin, ws.before, ws.after, ws.state] {
            try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        }
        try fm.copyItem(atPath: "/bin/sleep", toPath: ws.toolPath)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: ws.toolPath)
        // A bare copy of an Apple platform binary is SIGKILLed by the kernel
        // when it runs outside the system volume; re-sign it ad hoc so it is
        // an ordinary local executable that keeps running.
        let codesign = Process()
        codesign.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        codesign.arguments = ["--force", "--sign", "-", ws.toolPath]
        codesign.standardOutput = FileHandle.nullDevice
        codesign.standardError = FileHandle.nullDevice
        try codesign.run()
        codesign.waitUntilExit()
        XCTAssertEqual(codesign.terminationStatus, 0,
                       "precondition: ad-hoc re-signing the fake '\(tool)' binary must succeed")
        return ws
    }

    private func startSession(_ ws: Workspace, script: String) throws -> TerminalSession {
        let session = try TerminalSession.start(
            shell: "/bin/sh",
            arguments: ["-c", script, "sh", ws.toolPath, ws.before, ws.after, ws.state],
            size: .init(cols: 100, rows: 24),
            initialWorkingDirectory: ws.before
        )
        sessionsToTerminate.append(session)
        return session
    }

    // MARK: - Helpers

    /// Polls (without needing the main run loop) until `condition` holds.
    private func poll(timeout: TimeInterval, until condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.01)
        }
        return condition()
    }

    private func exists(_ path: String) -> Bool { FileManager.default.fileExists(atPath: path) }

    private func readPID(_ path: String) -> pid_t? {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        return pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func executableBasename(of pid: pid_t) -> String? {
        var buf = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let n = proc_pidpath(pid, &buf, UInt32(buf.count))
        guard n > 0 else { return nil }
        return (String(cString: buf) as NSString).lastPathComponent
    }

    private func bsdInfo(of pid: pid_t) -> proc_bsdinfo? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.stride)
        let n = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size)
        return n == size ? info : nil
    }

    /// The foreground process group of the controlling terminal of `pid`.
    private func terminalForegroundPGID(of pid: pid_t) -> pid_t? {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        guard sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0) == 0, size > 0 else { return nil }
        return info.kp_eproc.e_tpgid
    }

    /// Waits (pumping the main run loop, which the session needs to publish
    /// `lastKnownCwd`) until the published cwd equals `expected`, then returns
    /// what the session actually holds.
    private func cwd(of session: TerminalSession, afterWaitingFor expected: String,
                     timeout: TimeInterval) -> String? {
        let exp = expectation(description: "lastKnownCwd == \(expected)")
        var cancellable: AnyCancellable?
        cancellable = session.$lastKnownCwd.sink { value in
            if value == expected { exp.fulfill() }
        }
        _ = XCTWaiter().wait(for: [exp], timeout: timeout)
        cancellable?.cancel()
        return session.lastKnownCwd
    }

    /// Drives the background-job scenario up to the point where the job is
    /// running in the background of an idle shell, asserting every
    /// precondition from kernel state. Returns nil (after recording a
    /// failure) if the rig did not build the scenario.
    private struct BackgroundScenario {
        let session: TerminalSession
        let workspace: Workspace
        let shellPID: pid_t
        let jobPID: pid_t
    }

    private func buildBackgroundScenario(tool: String,
                                         file: StaticString = #filePath,
                                         line: UInt = #line) throws -> BackgroundScenario? {
        let ws = try makeWorkspace(tool: tool)
        let session = try startSession(ws, script: Self.backgroundScript)

        // Step 0: the shell reports "before" while no job exists. This both
        // starts the scenario at the stale directory and proves the OSC 7
        // pipeline delivers updates in this rig at all.
        XCTAssertTrue(poll(timeout: 15) { self.exists(ws.state + "/step0-done") },
                      "precondition: script never reached step 0 (shell did not start)",
                      file: file, line: line)
        let seenBefore = cwd(of: session, afterWaitingFor: ws.before, timeout: 10)
        XCTAssertEqual(seenBefore, ws.before,
                       "precondition: the OSC 7 for the pre-job directory must be accepted while no job runs",
                       file: file, line: line)
        guard seenBefore == ws.before else { return nil }

        // Step 1: start the job in the background and wait for its exec.
        session.send(Data("\n".utf8))
        XCTAssertTrue(poll(timeout: 15) { self.exists(ws.state + "/step1-done") },
                      "precondition: script never started the background job",
                      file: file, line: line)
        guard let shellPID = readPID(ws.state + "/shell.pid"),
              let jobPID = readPID(ws.state + "/job.pid") else {
            XCTFail("precondition: shell.pid / job.pid missing or unparsable", file: file, line: line)
            return nil
        }
        pidsToKill.append(jobPID)
        let execed = poll(timeout: 10) { self.executableBasename(of: jobPID) == tool }
        XCTAssertEqual(executableBasename(of: jobPID), tool,
                       "precondition: background job pid \(jobPID) must have exec'd the fake '\(tool)' binary",
                       file: file, line: line)
        guard execed else { return nil }

        // Kernel-state preconditions: this is a BACKGROUND job of an idle shell.
        let shellInfo = bsdInfo(of: shellPID)
        let jobInfo = bsdInfo(of: jobPID)
        XCTAssertEqual(jobInfo.map { pid_t($0.pbi_ppid) }, shellPID,
                       "precondition: job must be a direct child of the shell (this is what `&` does)",
                       file: file, line: line)
        XCTAssertNotEqual(jobInfo.map { pid_t($0.pbi_pgid) }, shellInfo.map { pid_t($0.pbi_pgid) },
                          "precondition: job must be in its own process group (job control on)",
                          file: file, line: line)
        XCTAssertEqual(terminalForegroundPGID(of: shellPID), shellInfo.map { pid_t($0.pbi_pgid) },
                       "precondition: the shell's group must be the terminal's foreground group (job is in the background)",
                       file: file, line: line)
        guard jobInfo.map({ pid_t($0.pbi_ppid) }) == shellPID,
              jobInfo.map({ pid_t($0.pbi_pgid) }) != shellInfo.map({ pid_t($0.pbi_pgid) }),
              terminalForegroundPGID(of: shellPID) == shellInfo.map({ pid_t($0.pbi_pgid) }) else {
            return nil
        }
        return BackgroundScenario(session: session, workspace: ws, shellPID: shellPID, jobPID: jobPID)
    }

    // MARK: - Tests

    /// The namespace verdict itself. A backgrounded `ssh` / `kubectl` /
    /// `docker` job could be the process that wrote an OSC 7 to the tty, so
    /// the gate fails closed and reports `.remote` for it.
    func testBackgroundedRemoteWrapperJobStillClassifiesRemote() throws {
        for tool in ["ssh", "kubectl", "docker"] {
            guard let scenario = try buildBackgroundScenario(tool: tool) else { return }
            let verdict = scenario.session.classifyForegroundNamespace()
            guard case .remote(let basename, _) = verdict else {
                XCTFail("background `\(tool) ... &` job (pid \(scenario.jobPID), child of idle shell \(scenario.shellPID)) "
                        + "can write OSC 7 to the tty, so the gate must stay closed; classifier returned \(verdict)")
                return
            }
            XCTAssertEqual(basename, tool, "remote verdict must name the matched wrapper")
            // Strictly one live session at a time.
            pidsToKill.forEach { if $0 > 1 { kill($0, SIGKILL) } }
            pidsToKill.removeAll()
            scenario.session.terminate()
            sessionsToTerminate.removeAll { $0 === scenario.session }
        }
    }

    /// The user-visible symptom. With an `ssh -N -L ... &` tunnel alive, the
    /// shell `cd`s and reports the new directory at its prompt. The gate drops
    /// that report, but Cmd-T must still open in the shell's current
    /// directory (the kernel's live cwd) instead of the pre-tunnel one.
    func testNewTabFollowsShellCdWhileBackgroundedSSHJobRuns() throws {
        guard let scenario = try buildBackgroundScenario(tool: "ssh") else { return }
        let ws = scenario.workspace
        let session = scenario.session

        // Step 2: the shell cd's to "after" and reports it (prompt hook).
        session.send(Data("\n".utf8))
        XCTAssertTrue(poll(timeout: 15) { self.exists(ws.state + "/step2-done") },
                      "precondition: script never emitted the post-cd OSC 7")

        // The dropped OSC 7 is handled on main; pump it until Cmd-T settles.
        // Only the post-cd directory satisfies the condition, so this cannot
        // pass early on the pre-job one.
        let deadline = Date().addingTimeInterval(10)
        while CwdResolver.forNewTab(source: session) != ws.after, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertEqual(
            CwdResolver.forNewTab(source: session), ws.after,
            "Cmd-T must open in the directory the shell is in (\(ws.after)), not the pre-job one (\(ws.before))"
        )
    }

    /// Control, passes before and after the fix: when the same wrapper binary
    /// IS the foreground job (the user is actually inside `ssh host`), the
    /// namespace is `.remote` and a reported cwd is still not trusted. Keeps
    /// the fix from being "just stop looking for remote binaries".
    func testForegroundSSHJobStillClassifiesRemoteAndOSC7IsDropped() throws {
        let ws = try makeWorkspace(tool: "ssh")
        let session = try startSession(ws, script: Self.foregroundScript)
        XCTAssertTrue(poll(timeout: 15) { self.exists(ws.state + "/step0-done") },
                      "precondition: script never started")
        if let shellPID = readPID(ws.state + "/shell.pid") { pidsToKill.append(shellPID) }

        var verdict = session.classifyForegroundNamespace()
        let becameRemote = poll(timeout: 10) {
            verdict = session.classifyForegroundNamespace()
            if case .remote = verdict { return true }
            return false
        }
        guard becameRemote, case .remote(let basename, let pid) = verdict else {
            XCTFail("a foreground `ssh` job must classify as .remote; classifier returned \(verdict)")
            return
        }
        pidsToKill.append(pid)
        XCTAssertEqual(basename, "ssh", "remote verdict must name the matched wrapper")

        session.feedBytesForTests(Data("\u{1b}]7;file://\(ws.after)\u{1b}\\".utf8))
        let tracked = cwd(of: session, afterWaitingFor: ws.after, timeout: 1)
        XCTAssertNil(tracked,
                     "an OSC 7 reported while ssh is the foreground job must be dropped; lastKnownCwd is \(String(describing: tracked))")
    }
}
