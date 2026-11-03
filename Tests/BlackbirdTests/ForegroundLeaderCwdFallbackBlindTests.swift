import XCTest
import Darwin
@testable import Blackbird

/// Blind regression tests for bug settings-persistence-2: Cmd-T opens the new
/// tab in `$HOME` when the foreground process-group leader of the active tab
/// is privileged (`sudo ...`, `top`: setuid root, so the kernel refuses to
/// disclose its cwd to an unprivileged caller with EPERM) or already gone
/// (`ls | less`, `echo hi | sleep 20`: the pipeline's first process exited and
/// was reaped while the group lives on, so the leader pid no longer exists,
/// ESRCH). The user-visible contract is the one every terminal follows: the
/// new tab starts in the directory the user is working in. When the
/// foreground job's own cwd cannot be read, the shell's own cwd (always
/// readable, it is our own child) is the correct answer; `nil`, which
/// `PTY.spawn` turns into `$HOME`, is not.
///
/// Scenario (matches the report). Default-zsh-like session: the shell has
/// `cd`'d into a project directory and never emitted OSC 7, so
/// `lastKnownCwd` is nil and `CwdResolver.forNewTab(source:)` has to work from
/// process state alone. The session is started in a different directory than
/// the project, so "the directory the shell was spawned in" and "the
/// directory the shell is in now" cannot be confused.
///
/// Rig. One real `TerminalSession` runs `/bin/sh -c <script>` with job control
/// on (`set -m`), exactly what an interactive shell does for a foreground
/// command: the job gets its own process group and that group becomes the
/// terminal's foreground group. No OSC 7 is ever emitted. Every precondition
/// is asserted from kernel state (the shell's cwd as the shell itself reports
/// it, the tty's foreground group, and the errno `proc_pidinfo` returns for
/// the group leader) before the behaviour is judged, so a rig that failed to
/// build the scenario cannot pass vacuously.
///
/// Controls (these pass before and after any fix and pin the neighbouring
/// behaviour a fix must keep):
///   - bare prompt: shell cwd;
///   - live readable leader whose cwd differs from the shell's: the LEADER's
///     cwd wins (documented priority: the live foreground cwd is what the
///     user is looking at), so a fix must not blindly prefer the shell's.
///
/// Pre-flight cost (project rule): one live `/bin/sh` plus one short-lived
/// helper process per session (`sleep`, `top`), killed and torn down before
/// the test returns; never two sessions at once. A few KB of temp files, no
/// window, no `MainWindowController`, no Metal. About a second or two per
/// session; failing paths end on explicit timeouts (<= ~15 s).
final class ForegroundLeaderCwdFallbackBlindTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        TestHostTermination.shared.register()
    }

    // MARK: - Rig

    /// Script arguments: $1 project dir, $2 other dir, $3 state dir.
    /// Common prelude: record pid, `cd` into the project, record the shell's
    /// own physical cwd, signal readiness. No OSC 7 anywhere.
    private static let prelude = #"""
    set -m
    echo $$ > "$3/shell.pid"
    cd "$1" || exit 3
    pwd -P > "$3/shell.cwd"
    : > "$3/ready"
    """#

    /// `top` is setuid root: an unprivileged `proc_pidinfo` on it fails EPERM.
    /// Not the last command of the script, otherwise `sh -c` would exec it in
    /// place and there would be no shell left to ask.
    private static var privilegedScript: String {
        prelude + #"""

        /usr/bin/top -l 0 -s 5 -n 1 -stats pid
        : > "$3/job-returned"
        """#
    }

    /// First pipeline member exits at once and is reaped by the shell; the
    /// second keeps the foreground group alive. The group id is the pid of the
    /// already-reaped first member.
    private static var exitedLeaderScript: String {
        prelude + #"""

        /bin/echo hi | /bin/sleep 120
        : > "$3/job-returned"
        """#
    }

    /// Live, readable leader whose cwd (`$2`) differs from the shell's (`$1`).
    private static var liveLeaderScript: String {
        prelude + #"""

        ( cd "$2" || exit 4; pwd -P > "$3/leader.cwd"; : > "$3/leader-ready"; exec /bin/sleep 120 ) | /bin/cat
        : > "$3/job-returned"
        """#
    }

    /// The shell sits at its own prompt (a builtin `read` on the tty).
    private static var barePromptScript: String {
        prelude + #"""

        read -r _hold
        : > "$3/job-returned"
        """#
    }

    private struct Rig {
        let session: TerminalSession
        let startDir: String
        let projectDir: String
        let otherDir: String
        let stateDir: String
        let shellPID: pid_t
        let shellPGID: pid_t
    }

    private var cleanupDirectories: [URL] = []
    private var pgidsToKill: [pid_t] = []
    private var pidsToKill: [pid_t] = []
    private var sessionsToTerminate: [TerminalSession] = []

    override func tearDown() {
        for pgid in pgidsToKill where pgid > 1 { killpg(pgid, SIGKILL) }
        pgidsToKill.removeAll()
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

    /// Builds the session and asserts the scenario's common preconditions:
    /// shell alive in the project directory (as the shell itself reports it),
    /// started elsewhere, no OSC 7 ever delivered. Returns nil (after
    /// recording a failure) if the rig did not build it.
    private func buildRig(script: String,
                          file: StaticString = #filePath,
                          line: UInt = #line) throws -> Rig? {
        let fm = FileManager.default
        let rootURL = fm.temporaryDirectory
            .appendingPathComponent("bb-fgleadercwd-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: rootURL, withIntermediateDirectories: true)
        cleanupDirectories.append(rootURL)
        let root = physicalPath(rootURL.path)
        let startDir = root + "/start"
        let projectDir = root + "/project dir"
        let otherDir = root + "/other"
        let stateDir = root + "/state"
        for dir in [startDir, projectDir, otherDir, stateDir] {
            try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        }

        let session = try TerminalSession.start(
            shell: "/bin/sh",
            arguments: ["-c", script, "sh", projectDir, otherDir, stateDir],
            size: .init(cols: 100, rows: 24),
            initialWorkingDirectory: startDir
        )
        sessionsToTerminate.append(session)

        XCTAssertTrue(poll(timeout: 15) { self.exists(stateDir + "/ready") },
                      "precondition: script never reached its ready marker (shell did not start / cd failed)",
                      file: file, line: line)
        guard let shellPID = readPID(stateDir + "/shell.pid") else {
            XCTFail("precondition: shell.pid missing or unparsable", file: file, line: line)
            return nil
        }
        pidsToKill.append(shellPID)

        let shellCwd = readLine(stateDir + "/shell.cwd")
        XCTAssertEqual(shellCwd, projectDir,
                       "precondition: the shell must have cd'd into the project directory (its own `pwd -P`)",
                       file: file, line: line)
        XCTAssertNotEqual(projectDir, startDir,
                          "precondition: the project directory must differ from the spawn directory",
                          file: file, line: line)
        XCTAssertNotEqual(projectDir, NSHomeDirectory(),
                          "precondition: the project directory must not be $HOME, or the fallback is indistinguishable",
                          file: file, line: line)
        guard shellCwd == projectDir else { return nil }

        guard let shellPGID = processGroup(of: shellPID) else {
            XCTFail("precondition: could not read the shell's process group", file: file, line: line)
            return nil
        }
        // No OSC 7 was ever emitted: the resolver must work from process state.
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertNil(session.lastKnownCwd,
                     "precondition: no OSC 7 was emitted, so lastKnownCwd must still be nil (got \(String(describing: session.lastKnownCwd)))",
                     file: file, line: line)
        guard session.lastKnownCwd == nil else { return nil }

        return Rig(session: session, startDir: startDir, projectDir: projectDir,
                   otherDir: otherDir, stateDir: stateDir,
                   shellPID: shellPID, shellPGID: shellPGID)
    }

    // MARK: - Kernel-state helpers

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

    private func readLine(_ path: String) -> String? {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func readPID(_ path: String) -> pid_t? {
        guard let text = readLine(path) else { return nil }
        return pid_t(text)
    }

    private func executableBasename(of pid: pid_t) -> String? {
        var buf = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let n = proc_pidpath(pid, &buf, UInt32(buf.count))
        guard n > 0 else { return nil }
        return (String(cString: buf) as NSString).lastPathComponent
    }

    private func processGroup(of pid: pid_t) -> pid_t? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.stride)
        let n = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size)
        guard n == size else { return nil }
        return pid_t(info.pbi_pgid)
    }

    /// The foreground process group of the controlling terminal of `pid`.
    private func terminalForegroundPGID(of pid: pid_t) -> pid_t? {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        guard sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0) == 0, size > 0 else { return nil }
        return info.kp_eproc.e_tpgid
    }

    /// What an unprivileged caller gets when it asks the kernel for `pid`'s
    /// cwd: success, or the errno of the refusal (EPERM for a setuid-root
    /// target, ESRCH for a pid that no longer exists).
    private func cwdLookupOutcome(of pid: pid_t) -> (succeeded: Bool, errnoValue: Int32) {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.stride)
        errno = 0
        let n = proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size)
        let err = errno
        if n == size { return (true, 0) }
        return (false, err)
    }

    /// Waits until a job (anything other than the shell's own group) is the
    /// terminal's foreground group and returns its group id.
    private func waitForForegroundJob(_ rig: Rig, file: StaticString = #filePath,
                                      line: UInt = #line) -> pid_t? {
        var fg: pid_t = 0
        let found = poll(timeout: 15) { () -> Bool in
            guard let tp = self.terminalForegroundPGID(of: rig.shellPID) else { return false }
            fg = tp
            return tp > 1 && tp != rig.shellPGID
        }
        XCTAssertTrue(found,
                      "precondition: a foreground job (group != shell group \(rig.shellPGID)) never appeared; tty foreground group is \(fg)",
                      file: file, line: line)
        guard found else { return nil }
        pgidsToKill.append(fg)
        return fg
    }

    // MARK: - Tests

    /// `sudo ...` / `top`: the foreground leader is setuid root, the kernel
    /// refuses to reveal its cwd (EPERM). Cmd-T must still open in the
    /// directory the user is working in: the shell's.
    func testNewTabOpensInShellCwdWhenForegroundLeaderIsPrivileged() throws {
        try XCTSkipIf(geteuid() == 0,
                      "running as root: the kernel will not refuse the cwd lookup, so the privileged scenario cannot be built")
        guard let rig = try buildRig(script: Self.privilegedScript) else { return }
        guard let fg = waitForForegroundJob(rig) else { return }

        // Precondition: the leader's cwd really is unreadable, with EPERM.
        let settled = poll(timeout: 10) { !self.cwdLookupOutcome(of: fg).succeeded }
        let outcome = cwdLookupOutcome(of: fg)
        XCTAssertTrue(settled,
                      "precondition: foreground leader pid \(fg) (a setuid-root `top`) must refuse the cwd lookup")
        XCTAssertEqual(outcome.errnoValue, EPERM,
                       "precondition: the refusal must be EPERM (privileged leader), got errno \(outcome.errnoValue)")
        guard settled, outcome.errnoValue == EPERM else { return }

        let resolved = CwdResolver.forNewTab(source: rig.session)
        XCTAssertEqual(
            resolved, rig.projectDir,
            "Cmd-T with a privileged foreground leader (pid \(fg), EPERM) must open in the shell's cwd "
            + "\(rig.projectDir); got \(String(describing: resolved)) (nil means the new tab lands in $HOME = \(NSHomeDirectory()))"
        )
    }

    /// `ls | less`, `echo hi | sleep 20`: the first pipeline process, whose
    /// pid is the foreground group id, has exited and been reaped (ESRCH).
    /// Cmd-T must still open in the shell's cwd.
    func testNewTabOpensInShellCwdWhenForegroundLeaderAlreadyExited() throws {
        guard let rig = try buildRig(script: Self.exitedLeaderScript) else { return }
        guard let fg = waitForForegroundJob(rig) else { return }

        // Precondition: the leader pid is gone, but its group still lives.
        let gone = poll(timeout: 10) { () -> Bool in
            return kill(fg, 0) == -1 && errno == ESRCH
        }
        XCTAssertTrue(gone,
                      "precondition: the pipeline's first process (group id \(fg)) must have exited and been reaped")
        XCTAssertEqual(killpg(fg, 0), 0,
                       "precondition: the foreground group \(fg) must still have a live member (the `sleep`)")
        let outcome = cwdLookupOutcome(of: fg)
        XCTAssertEqual(outcome.errnoValue, ESRCH,
                       "precondition: the cwd lookup on the vanished leader must fail with ESRCH, got errno \(outcome.errnoValue)")
        guard gone, outcome.errnoValue == ESRCH else { return }

        let resolved = CwdResolver.forNewTab(source: rig.session)
        XCTAssertEqual(
            resolved, rig.projectDir,
            "Cmd-T with an already-exited foreground leader (pid \(fg), ESRCH) must open in the shell's cwd "
            + "\(rig.projectDir); got \(String(describing: resolved)) (nil means the new tab lands in $HOME = \(NSHomeDirectory()))"
        )
    }

    /// Control, passes before and after the fix: a live pipeline leader whose
    /// cwd differs from the shell's. The documented priority is the live
    /// foreground cwd, so the leader's directory wins. Keeps a fix from being
    /// "always answer with the shell's cwd".
    func testNewTabStillInheritsLiveReadableLeaderCwd() throws {
        guard let rig = try buildRig(script: Self.liveLeaderScript) else { return }
        guard let fg = waitForForegroundJob(rig) else { return }

        XCTAssertTrue(poll(timeout: 15) { self.exists(rig.stateDir + "/leader-ready") },
                      "precondition: the pipeline leader never reached its exec marker")
        let execed = poll(timeout: 10) { self.executableBasename(of: fg) == "sleep" }
        XCTAssertEqual(executableBasename(of: fg), "sleep",
                       "precondition: foreground leader pid \(fg) must have exec'd /bin/sleep")
        let outcome = cwdLookupOutcome(of: fg)
        XCTAssertEqual(outcome.errnoValue, 0,
                       "precondition: the live leader's cwd must be readable, got errno \(outcome.errnoValue)")
        let leaderCwd = readLine(rig.stateDir + "/leader.cwd")
        XCTAssertEqual(leaderCwd, rig.otherDir,
                       "precondition: the leader must be running in the other directory (its own `pwd -P`)")
        guard execed, outcome.errnoValue == 0, leaderCwd == rig.otherDir else { return }

        let resolved = CwdResolver.forNewTab(source: rig.session)
        XCTAssertEqual(
            resolved, rig.otherDir,
            "Cmd-T with a live, readable foreground leader (pid \(fg)) must open in the leader's cwd "
            + "\(rig.otherDir), not the shell's \(rig.projectDir); got \(String(describing: resolved))"
        )
    }

    /// Control, passes before and after the fix: shell at its own prompt, no
    /// foreground job. The shell's cwd, with no OSC 7 and no help from
    /// `lastKnownCwd`.
    func testNewTabAtBarePromptWithoutOSC7OpensInShellCwd() throws {
        guard let rig = try buildRig(script: Self.barePromptScript) else { return }

        let tpgid = terminalForegroundPGID(of: rig.shellPID)
        XCTAssertEqual(tpgid, rig.shellPGID,
                       "precondition: at the prompt the shell's own group (\(rig.shellPGID)) must be the tty foreground group")
        guard tpgid == rig.shellPGID else { return }

        let resolved = CwdResolver.forNewTab(source: rig.session)
        XCTAssertEqual(
            resolved, rig.projectDir,
            "Cmd-T at a bare prompt (no OSC 7) must open in the shell's cwd \(rig.projectDir); got \(String(describing: resolved))"
        )
    }
}
