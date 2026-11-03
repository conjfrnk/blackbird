import XCTest
import Combine
import Darwin
@testable import Blackbird

/// Blind regression tests for bug pty-3b: the OSC 7 trust gate decides "is
/// this cwd report trustworthy?" from the SHAPE of the process tree (does a
/// remote-shell binary such as `ssh` / `kubectl` / `docker` appear among the
/// foreground group's processes?), but the terminal cannot tell WHICH process
/// wrote an OSC 7 to the tty. Two observable contracts follow.
///
/// Contract 1 (trust). A job running in the BACKGROUND of an idle local shell
/// (tty writes are allowed unless `stty tostop`) can print an OSC 7 too. A
/// backgrounded `ssh host` / `docker exec` / `kubectl exec` session whose
/// remote prompt emits OSC 7 names a path on a different machine, or one an
/// attacker chose. That path must not become the directory ⌘T opens a new tab
/// in. The only directory that is certainly right is the one the local shell
/// is actually in.
///
/// Contract 2 (stale cwd). An idle interactive shell with a backgrounded
/// remote-wrapper job that `cd`s and prints its own OSC 7 must still have ⌘T
/// open in its CURRENT directory, also when job control is off (so the
/// background job shares the shell's process group and the foreground-group
/// filter cannot tell it apart from the shell).
///
/// Contract 1 also holds while ANOTHER job is in the foreground: a background
/// `docker logs -f &` is then a sibling of the foreground `vim` / `make`, not
/// under it, so a gate that only walks the foreground leader's subtree never
/// sees it. After the foreground job exits the idle shell must still open new
/// tabs in its own directory, not the one the background job named.
///
/// Rig. One real `TerminalSession` runs `/bin/sh -c <script>`; the script is a
/// state machine stepped from the test through `read` on the tty, so the
/// order of events is deterministic. The fake "remote" binary is a copy of an
/// Apple platform binary placed in a temp directory under the wrapper's name
/// (`proc_pidpath` reports the real image path, so symlinks / argv[0] tricks
/// would not be classified) and re-signed ad hoc, otherwise the kernel kills
/// it. For the trust test the fake `ssh` is a copy of `/bin/dash` (not
/// `/bin/sh`, which is a launcher that re-execs `/bin/bash` and so would not
/// keep the wrapper's image name) that runs a small writer script: it waits for a go-file, prints the hostile OSC 7 plus
/// an OSC 2 title sentinel, then idles. Because the core delivers events in
/// order, observing the sentinel title proves the preceding OSC 7 has been
/// processed, so the verdict is read at a deterministic point and a correct
/// implementation does not need a timeout to pass.
///
/// Every precondition (job exec'd under the wrapper name, direct child of the
/// shell, process-group relationship, terminal foreground group, the hostile
/// bytes actually written, the sentinel seen) is asserted from kernel or
/// session state, so a rig that silently failed to build the scenario cannot
/// pass vacuously.
///
/// Pre-flight cost (project rule): one live `/bin/sh` plus one background job
/// (and its short-lived `sleep` children) per test, never two sessions at
/// once, all killed in tearDown. A few KB of temp files, no window, no
/// `MainWindowController`, no Metal. Wall time is about a second per test.
final class OSC7BackgroundJobTrustBlindTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        TestHostTermination.shared.register()
    }

    // MARK: - Rig

    private struct Workspace {
        let root: String
        let bin: String          // directory holding the fake wrapper binary
        let before: String       // cwd the shell is in when the scenario starts
        let after: String        // cwd the shell `cd`s to (contract 2)
        let hostile: String      // existing local dir the background job names
        let state: String        // pid / marker files written by the scripts
        let tool: String         // wrapper basename, e.g. "ssh"
        var toolPath: String { bin + "/" + tool }
    }

    /// Contract 1 shell script (job control ON, like an interactive shell).
    /// Arguments: $1 tool path, $2 before, $3 after, $4 state dir, $5 hostile.
    /// Raw string so the printf escapes reach the shell untouched
    /// (`\033` = ESC, `\\` = backslash; together the ST terminator ESC \).
    private static let trustShellScript = #"""
    set -m
    echo $$ > "$4/shell.pid"
    printf '\033]7;file://%s\033\\' "$2"
    : > "$4/step0-done"
    read -r _step1
    "$1" "$4/writer.sh" "$5" "$4" &
    echo $! > "$4/job.pid"
    : > "$4/step1-done"
    read -r _hold
    """#

    /// Contract 1 with a FOREGROUND job (job control ON): same as
    /// `trustShellScript`, but after the background job starts the shell runs
    /// `/bin/sleep` in the foreground (own process group, owns the tty) until
    /// the test kills it. The command after it keeps the shell from tail-exec'ing it.
    /// Arguments: $1 tool path, $2 before, $3 after, $4 state dir, $5 hostile.
    private static let trustForegroundJobScript = #"""
    set -m
    echo $$ > "$4/shell.pid"
    printf '\033]7;file://%s\033\\' "$2"
    : > "$4/step0-done"
    read -r _step1
    "$1" "$4/writer.sh" "$5" "$4" &
    echo $! > "$4/job.pid"
    : > "$4/step1-done"
    read -r _step2
    /bin/sleep 120
    : > "$4/fg-returned"
    read -r _hold
    """#

    /// Run by the fake `ssh` (a copy of /bin/dash) as a background job: it
    /// waits for the go-file, prints an OSC 7 naming `$1` plus an OSC 2 title
    /// sentinel to the controlling terminal, then idles under its own name.
    /// Trailing `:` so the shell cannot tail-exec `sleep` and change its
    /// image name away from the wrapper.
    private static let hostileWriterScript = #"""
    while [ ! -e "$2/go" ]; do sleep 0.05; done
    printf '\033]7;file://%s\033\\' "$1"
    printf '\033]2;bb-hostile-done\007'
    : > "$2/hostile-written"
    sleep 120
    :
    """#

    /// Contract 2 shell script (job control OFF: no `set -m`, the default for
    /// `sh -c`, so `&` jobs stay in the shell's own process group).
    /// Arguments: $1 tool path, $2 before, $3 after, $4 state dir.
    private static let jobControlOffScript = #"""
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
    printf '\033]2;bb-cd-done\007'
    : > "$4/step2-done"
    read -r _hold
    """#

    private var cleanupDirectories: [URL] = []
    private var pidsToKill: [pid_t] = []
    private var groupsToKill: [pid_t] = []
    private var sessionsToTerminate: [TerminalSession] = []

    override func tearDown() {
        for pgid in groupsToKill where pgid > 1 { kill(-pgid, SIGKILL) }
        groupsToKill.removeAll()
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

    /// Copies `source` to `<bin>/<tool>` and re-signs it ad hoc. A bare copy
    /// of an Apple platform binary is SIGKILLed by the kernel when it runs
    /// outside the system volume; once re-signed it is an ordinary local
    /// executable.
    private func makeWorkspace(tool: String, copying source: String) throws -> Workspace {
        let fm = FileManager.default
        let rootURL = fm.temporaryDirectory
            .appendingPathComponent("bb-osc7trust-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: rootURL, withIntermediateDirectories: true)
        cleanupDirectories.append(rootURL)
        let root = physicalPath(rootURL.path)
        let ws = Workspace(root: root, bin: root + "/bin", before: root + "/before",
                           after: root + "/after", hostile: root + "/hostile-dir",
                           state: root + "/state", tool: tool)
        for dir in [ws.bin, ws.before, ws.after, ws.hostile, ws.state] {
            try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        }
        try fm.copyItem(atPath: source, toPath: ws.toolPath)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: ws.toolPath)
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
            arguments: ["-c", script, "sh", ws.toolPath, ws.before, ws.after, ws.state, ws.hostile],
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
        exp.assertForOverFulfill = false
        var cancellable: AnyCancellable?
        cancellable = session.$lastKnownCwd.sink { (value: String?) in
            if value == expected { exp.fulfill() }
        }
        _ = XCTWaiter().wait(for: [exp], timeout: timeout)
        cancellable?.cancel()
        return session.lastKnownCwd
    }

    /// Waits (pumping the main run loop) until the session's title equals
    /// `sentinel`. The core delivers events in order, so once the sentinel
    /// title has been applied every OSC 7 written before it has been handled.
    private func waitForTitle(_ sentinel: String, in session: TerminalSession,
                              timeout: TimeInterval) -> Bool {
        let exp = expectation(description: "title == \(sentinel)")
        exp.assertForOverFulfill = false
        var cancellable: AnyCancellable?
        cancellable = session.titleState.$title.sink { (value: String?) in
            if value == sentinel { exp.fulfill() }
        }
        let result = XCTWaiter().wait(for: [exp], timeout: timeout)
        cancellable?.cancel()
        return result == .completed
    }

    /// Step 0 shared by both scenarios: the shell reports `before` while no
    /// job exists. Proves the OSC 7 pipeline works in this rig and starts the
    /// scenario at a known, correct directory.
    private func awaitStep0(_ ws: Workspace, session: TerminalSession,
                            file: StaticString = #filePath, line: UInt = #line) -> Bool {
        XCTAssertTrue(poll(timeout: 15) { self.exists(ws.state + "/step0-done") },
                      "precondition: script never reached step 0 (shell did not start)",
                      file: file, line: line)
        let seenBefore = cwd(of: session, afterWaitingFor: ws.before, timeout: 10)
        XCTAssertEqual(seenBefore, ws.before,
                       "precondition: the OSC 7 for the starting directory must be accepted while no job runs",
                       file: file, line: line)
        return seenBefore == ws.before
    }

    private struct JobScenario {
        let shellPID: pid_t
        let jobPID: pid_t
        let shellPGID: pid_t
        let jobPGID: pid_t
    }

    /// Starts the background job (`send` "\n" releases the script's `read`),
    /// waits for its exec under the wrapper name, and asserts the kernel-state
    /// preconditions. `jobControl` says whether the job must be in its own
    /// process group (true) or share the shell's (false). Returns nil after
    /// recording a failure if the rig did not build the scenario.
    private func startBackgroundJob(_ ws: Workspace, session: TerminalSession, jobControl: Bool,
                                    file: StaticString = #filePath,
                                    line: UInt = #line) -> JobScenario? {
        session.send(Data("\n".utf8))
        XCTAssertTrue(poll(timeout: 15) { self.exists(ws.state + "/step1-done") },
                      "precondition: script never started the background job",
                      file: file, line: line)
        guard let shellPID = readPID(ws.state + "/shell.pid"),
              let jobPID = readPID(ws.state + "/job.pid") else {
            XCTFail("precondition: shell.pid / job.pid missing or unparsable", file: file, line: line)
            return nil
        }
        pidsToKill.append(shellPID)
        pidsToKill.append(jobPID)
        let execed = poll(timeout: 10) { self.executableBasename(of: jobPID) == ws.tool }
        XCTAssertEqual(executableBasename(of: jobPID), ws.tool,
                       "precondition: background job pid \(jobPID) must have exec'd the fake '\(ws.tool)' binary",
                       file: file, line: line)
        guard execed, let shellInfo = bsdInfo(of: shellPID), let jobInfo = bsdInfo(of: jobPID) else {
            return nil
        }
        let shellPGID = pid_t(shellInfo.pbi_pgid)
        let jobPGID = pid_t(jobInfo.pbi_pgid)
        if jobControl { groupsToKill.append(jobPGID) }
        XCTAssertEqual(pid_t(jobInfo.pbi_ppid), shellPID,
                       "precondition: job must be a direct child of the shell (this is what `&` does)",
                       file: file, line: line)
        if jobControl {
            XCTAssertNotEqual(jobPGID, shellPGID,
                              "precondition: with job control on the job must be in its own process group",
                              file: file, line: line)
        } else {
            XCTAssertEqual(jobPGID, shellPGID,
                           "precondition: with job control off the job must share the shell's process group",
                           file: file, line: line)
        }
        XCTAssertEqual(terminalForegroundPGID(of: shellPID), shellPGID,
                       "precondition: the shell's group must be the terminal's foreground group (idle shell at its prompt)",
                       file: file, line: line)
        guard pid_t(jobInfo.pbi_ppid) == shellPID,
              (jobPGID != shellPGID) == jobControl,
              terminalForegroundPGID(of: shellPID) == shellPGID else {
            return nil
        }
        return JobScenario(shellPID: shellPID, jobPID: jobPID, shellPGID: shellPGID, jobPGID: jobPGID)
    }

    // MARK: - Tests

    /// Contract 1. The shell sits idle at its prompt with a backgrounded
    /// `ssh` job (own process group, so the shell's group is the terminal's
    /// foreground group). That job prints an OSC 7 naming a directory that is
    /// not the shell's. ⌘T must not follow it: the new tab belongs in the
    /// directory the local shell is actually in.
    func testBackgroundJobOSC7NamingForeignPathDoesNotSteerNewTab() throws {
        let ws = try makeWorkspace(tool: "ssh", copying: "/bin/dash")
        try Self.hostileWriterScript.write(toFile: ws.state + "/writer.sh", atomically: true, encoding: .utf8)
        let session = try startSession(ws, script: Self.trustShellScript)
        guard awaitStep0(ws, session: session) else { return }
        guard let job = startBackgroundJob(ws, session: session, jobControl: true) else { return }

        // Before anything hostile happens, ⌘T is correct. Keeps the later
        // failure attributable to the hostile OSC 7 and nothing else.
        XCTAssertEqual(CwdResolver.forNewTab(source: session), ws.before,
                       "precondition: before the job prints anything ⌘T must open in the shell's directory")

        // Release the job: it prints OSC 7 naming `hostile` plus the sentinel.
        XCTAssertTrue(FileManager.default.createFile(atPath: ws.state + "/go", contents: Data()),
                      "precondition: could not create the go-file that releases the hostile writer")
        XCTAssertTrue(poll(timeout: 15) { self.exists(ws.state + "/hostile-written") },
                      "precondition: the background job never wrote its OSC 7 to the tty "
                      + "(stopped by SIGTTOU or the writer script failed)")
        let sentinelSeen = waitForTitle("bb-hostile-done", in: session, timeout: 10)
        XCTAssertTrue(sentinelSeen,
                      "precondition: the sentinel title written right after the hostile OSC 7 was never applied, "
                      + "so the OSC 7 may not have been processed yet")
        guard sentinelSeen else { return }

        // The writer is still the live background `ssh`, the shell still idle.
        XCTAssertEqual(executableBasename(of: job.jobPID), ws.tool,
                       "precondition: the writer must still be the '\(ws.tool)' process")
        XCTAssertEqual(terminalForegroundPGID(of: job.shellPID), job.shellPGID,
                       "precondition: the shell's group must still be the terminal's foreground group")

        let newTabDir = CwdResolver.forNewTab(source: session)
        XCTAssertEqual(
            newTabDir, ws.before,
            "a background '\(ws.tool)' job (pid \(job.jobPID), pgid \(job.jobPGID)) printed an OSC 7 naming "
            + "\(ws.hostile); ⌘T must still open in the shell's real directory \(ws.before), "
            + "but the new tab would open in \(String(describing: newTabDir)) "
            + "(lastKnownCwd = \(String(describing: session.lastKnownCwd)))"
        )
    }

    /// Contract 1 with ANOTHER job in the foreground. The backgrounded `ssh`
    /// has its own process group and is a sibling of the foreground `sleep`
    /// (both children of the shell), so it is not in the foreground leader's
    /// subtree. While `sleep` holds the terminal the background job prints an
    /// OSC 7 naming a directory that is not the shell's; it must neither be
    /// stored as the shell's directory nor surface through ⌘T once `sleep`
    /// exits and the shell is idle again.
    func testBackgroundJobOSC7WhileAnotherJobHoldsTheTerminalDoesNotSteerNewTab() throws {
        let ws = try makeWorkspace(tool: "ssh", copying: "/bin/dash")
        try Self.hostileWriterScript.write(toFile: ws.state + "/writer.sh", atomically: true, encoding: .utf8)
        let session = try startSession(ws, script: Self.trustForegroundJobScript)
        guard awaitStep0(ws, session: session) else { return }
        guard let job = startBackgroundJob(ws, session: session, jobControl: true) else { return }

        // Release the shell into its foreground `sleep`, and wait until that
        // job (not the shell, not the ssh job) owns the terminal.
        session.send(Data("\n".utf8))
        var foreground: pid_t = job.shellPGID
        let handedOver = poll(timeout: 15) { () -> Bool in
            guard let tpgid = self.terminalForegroundPGID(of: job.shellPID) else { return false }
            foreground = tpgid
            return tpgid != job.shellPGID
        }
        XCTAssertTrue(handedOver, "precondition: the shell never handed the terminal to its foreground job")
        guard handedOver else { return }
        groupsToKill.append(foreground)
        XCTAssertNotEqual(foreground, job.jobPGID,
                          "precondition: the foreground group must not be the ssh job's group")
        let foregroundIsSleep = poll(timeout: 10) { () -> Bool in
            self.executableBasename(of: foreground) == "sleep"
        }
        XCTAssertEqual(executableBasename(of: foreground), "sleep",
                       "precondition: the foreground group leader must be the local `sleep`")
        guard foregroundIsSleep else { return }
        XCTAssertEqual(bsdInfo(of: foreground).map { (info: proc_bsdinfo) -> pid_t in pid_t(info.pbi_ppid) },
                       job.shellPID,
                       "precondition: the foreground job must be a direct child of the shell")
        XCTAssertEqual(executableBasename(of: job.jobPID), ws.tool,
                       "precondition: the background '\(ws.tool)' job must still be alive and a sibling of the foreground job")

        // Release the background job: OSC 7 naming `hostile` plus the sentinel.
        XCTAssertTrue(FileManager.default.createFile(atPath: ws.state + "/go", contents: Data()),
                      "precondition: could not create the go-file that releases the hostile writer")
        XCTAssertTrue(poll(timeout: 15) { self.exists(ws.state + "/hostile-written") },
                      "precondition: the background job never wrote its OSC 7 to the tty "
                      + "(stopped by SIGTTOU or the writer script failed)")
        let sentinelSeen = waitForTitle("bb-hostile-done", in: session, timeout: 10)
        XCTAssertTrue(sentinelSeen,
                      "precondition: the sentinel title written right after the hostile OSC 7 was never applied, "
                      + "so the OSC 7 may not have been processed yet")
        guard sentinelSeen else { return }
        XCTAssertEqual(terminalForegroundPGID(of: job.shellPID), foreground,
                       "precondition: `sleep` must have held the terminal while the OSC 7 was handled")

        XCTAssertEqual(
            session.lastKnownCwd, ws.before,
            "a background '\(ws.tool)' job (pid \(job.jobPID)) printed an OSC 7 naming \(ws.hostile) while "
            + "`sleep` (pgid \(foreground)) was in the foreground; the session must not record it as the shell's directory"
        )

        // The foreground job exits; the shell is idle at its prompt again.
        kill(-foreground, SIGKILL)
        XCTAssertTrue(poll(timeout: 15) { self.exists(ws.state + "/fg-returned") },
                      "precondition: the shell never resumed after the foreground job was killed")
        XCTAssertTrue(poll(timeout: 10) { self.terminalForegroundPGID(of: job.shellPID) == job.shellPGID },
                      "precondition: the shell's group must own the terminal again (idle shell)")
        XCTAssertEqual(executableBasename(of: job.jobPID), ws.tool,
                       "precondition: the background '\(ws.tool)' job must still be alive")

        let newTabDir = CwdResolver.forNewTab(source: session)
        XCTAssertEqual(
            newTabDir, ws.before,
            "the shell is idle in \(ws.before) with a background '\(ws.tool)' job that printed an OSC 7 naming "
            + "\(ws.hostile) during the foreground job; ⌘T must open in the shell's real directory, "
            + "but the new tab would open in \(String(describing: newTabDir)) "
            + "(lastKnownCwd = \(String(describing: session.lastKnownCwd)))"
        )
    }

    /// Contract 2, job control off. The backgrounded `ssh` shares the shell's
    /// process group (what `&` does in a shell without job control, e.g.
    /// `set +m`), the shell `cd`s and prints its own OSC 7. ⌘T must open in
    /// the directory the shell is in now, not the pre-job one.
    func testNewTabFollowsShellCdWhileBackgroundedSSHJobRunsWithJobControlOff() throws {
        let ws = try makeWorkspace(tool: "ssh", copying: "/bin/sleep")
        let session = try startSession(ws, script: Self.jobControlOffScript)
        guard awaitStep0(ws, session: session) else { return }
        guard let job = startBackgroundJob(ws, session: session, jobControl: false) else { return }

        // The shell cd's to `after` and reports it (the prompt hook).
        session.send(Data("\n".utf8))
        XCTAssertTrue(poll(timeout: 15) { self.exists(ws.state + "/step2-done") },
                      "precondition: script never emitted the post-cd OSC 7")
        let sentinelSeen = waitForTitle("bb-cd-done", in: session, timeout: 10)
        XCTAssertTrue(sentinelSeen,
                      "precondition: the sentinel title written right after the post-cd OSC 7 was never applied, "
                      + "so the OSC 7 may not have been processed yet")
        guard sentinelSeen else { return }

        XCTAssertEqual(executableBasename(of: job.jobPID), ws.tool,
                       "precondition: the background '\(ws.tool)' job must still be alive")

        let newTabDir = CwdResolver.forNewTab(source: session)
        XCTAssertEqual(
            newTabDir, ws.after,
            "with a backgrounded '\(ws.tool)' job (pid \(job.jobPID), same process group as shell \(job.shellPID)) "
            + "alive, ⌘T must open in the directory the shell cd'd to (\(ws.after)); "
            + "it would open in \(String(describing: newTabDir)) instead "
            + "(pre-job directory was \(ws.before), lastKnownCwd = \(String(describing: session.lastKnownCwd)))"
        )
    }
}
