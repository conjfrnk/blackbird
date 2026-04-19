import Foundation
import Darwin

/// Wraps a child process running behind a pseudo-terminal master fd.
///
/// Thread model:
/// - A dedicated background queue runs a blocking `read(2)` loop.
/// - Writes go through a serial queue so interleaved writes don't tear.
/// - `onBytes` is invoked on the read queue — callers that need to hand off
///   to another queue must dispatch explicitly.
public final class PTY {

    public struct Size: Equatable {
        public var cols: UInt16
        public var rows: UInt16
        public init(cols: UInt16, rows: UInt16) {
            self.cols = cols
            self.rows = rows
        }
    }

    public enum Error: Swift.Error {
        case forkFailed(errno: Int32)
    }

    /// Invoked with raw output bytes from the child. Called on the read queue.
    public var onBytes: ((Data) -> Void)?

    /// Invoked once after the child process has exited and been reaped.
    /// Fires whether the exit was natural (shell typed `exit`) or induced by
    /// `terminate()` (which sends SIGHUP). Called on the main queue exactly
    /// once. Nil by default; callers opt in to observe.
    public var onExit: ((Int32) -> Void)?

    /// Environment variables the GUI app inherits from launchd / XPC that
    /// we scrub before exec'ing the user's shell. Exposed as a static so
    /// a unit test can pin the list — shrinking it silently (a refactor
    /// that drops the fork-hygiene call altogether, or a "let's simplify
    /// this env cleanup" PR) would re-leak parent-process plumbing into
    /// child processes. iTerm2 and Terminal.app scrub the same set.
    public static let scrubbedParentEnvVars: [String] = [
        "XPC_SERVICE_NAME",
        "XPC_FLAGS",
        "__CF_USER_TEXT_ENCODING",
        "OS_ACTIVITY_DT_MODE",
        "__XCODE_BUILT_PRODUCTS_DIR_PATHS",
        "__XPC_DYLD_LIBRARY_PATH",
        "LaunchInstanceID",
        "SECURITYSESSIONID",
    ]

    private let masterFD: Int32
    private let childPID: pid_t
    private let readQueue = DispatchQueue(label: "blackbird.pty.read", qos: .userInitiated)
    private let writeQueue = DispatchQueue(label: "blackbird.pty.write", qos: .userInitiated)
    private let stateQueue = DispatchQueue(label: "blackbird.pty.state")
    private var _isRunning = true
    /// Per-`read(2)` buffer size. Darwin's PTY master delivers up to the
    /// kernel's pipe-buffer limit per syscall (typically 16 KiB), so a
    /// larger user-space buffer doesn't force larger reads — it just lets
    /// a very fast producer (build logs, `cat hugefile`, ANSI-art streams)
    /// drain more than one kernel buffer per syscall when several chunks
    /// are queued back-to-back. Benchmarks on comparable terminals show the
    /// throughput curve flattens around 64–256 KiB (see Evan Jones' PTY
    /// read/write buffer study). 128 KiB is the sweet spot: 8× the prior
    /// 16 KiB cap without burning meaningful memory (one allocation per
    /// tab, shared across all reads).
    private let readBufferSize = 128 * 1024

    private func shouldKeepRunning() -> Bool {
        stateQueue.sync { _isRunning }
    }

    private func markStopped() {
        stateQueue.sync { _isRunning = false }
    }

    /// Whether `xterm-kitty` is currently reachable via ncurses terminfo
    /// lookup. Computed once per process: we try to install the bundled
    /// kitty terminfo to ~/.terminfo if needed, then probe `infocmp`. When
    /// true, the child gets `TERM=xterm-kitty` so kitty-aware TUIs (Claude
    /// Code, nvim, tmux 3.3+) negotiate the keyboard protocol and Shift+Enter
    /// actually produces `ESC[13;2u` instead of bare `\r`. When false, we
    /// fall back to `xterm-256color` — legacy but universally understood.
    private static let kittyTerminfoAvailable: Bool = installKittyTerminfoIfNeeded()

    /// Install the bundled kitty terminfo to `~/.terminfo/x/xterm-kitty`.
    /// Runs *every* launch — an opportunistic `tic -x` overwrites the
    /// target, which is what we want: the bundled source is authoritative.
    /// If an attacker pre-planted a malicious `xterm-kitty` entry (with a
    /// hostile `reset=` capability that runs arbitrary bytes on shell
    /// `reset`/`clear`), the re-install wipes it. Prior behaviour only
    /// installed when `infocmp xterm-kitty` failed, which meant a planted
    /// entry survived because the probe succeeded against it.
    /// Returns true iff ncurses can resolve `xterm-kitty` afterwards —
    /// which is what the child really needs before we hand it
    /// `TERM=xterm-kitty`.
    private static func installKittyTerminfoIfNeeded() -> Bool {
        guard
            let src = Bundle.main.url(forResource: "kitty", withExtension: "terminfo"),
            FileManager.default.fileExists(atPath: src.path)
        else {
            return false
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        let dst = home.appendingPathComponent(".terminfo")
        // tic with -o writes <dst>/x/xterm-kitty. The directory is created
        // for us. Swallow stderr — this is opportunistic; any failure just
        // means we fall back to xterm-256color.
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/tic")
        task.arguments = ["-x", "-o", dst.path, src.path]
        task.standardOutput = Pipe()
        task.standardError = Pipe()
        do {
            try task.run()
            task.waitUntilExit()
        } catch {
            return false
        }
        return infocmpSucceeds(term: "xterm-kitty")
    }

    /// True when `infocmp <term>` exits 0 — i.e. ncurses can find the entry.
    /// Uses /usr/bin/infocmp directly so we don't depend on $PATH being
    /// sane at this point in app startup.
    private static func infocmpSucceeds(term: String) -> Bool {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/infocmp")
        task.arguments = [term]
        task.standardOutput = Pipe()
        task.standardError = Pipe()
        do {
            try task.run()
            task.waitUntilExit()
        } catch {
            return false
        }
        return task.terminationStatus == 0
    }

    /// Spawn a child process attached to a new PTY. `initialWorkingDirectory`
    /// (when provided and existent) is chdir'd before exec — used to inherit
    /// the previous tab's cwd for ⌘T / ⌘N. Falls back to the user's home
    /// directory if the value is nil, empty, or not a valid directory.
    public static func spawn(
        executable: String,
        arguments: [String],
        envOverrides: [String: String],
        size: Size,
        initialWorkingDirectory: String? = nil
    ) throws -> PTY {
        // Resolve TERM before fork. kittyTerminfoAvailable is evaluated once
        // per process so this is cheap on subsequent spawns.
        let termValue = kittyTerminfoAvailable ? "xterm-kitty" : "xterm-256color"
        let termCStr = strdup(termValue)
        defer { free(termCStr) }
        var master: Int32 = -1
        var winsize = Darwin.winsize(
            ws_row: size.rows, ws_col: size.cols,
            ws_xpixel: 0, ws_ypixel: 0
        )
        // Read the bundle version BEFORE fork — after fork we're in a
        // post-fork-pre-exec no-man's-land where complex Foundation calls
        // aren't async-signal-safe. setenv / getenv / chdir are fine.
        let versionStr = (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "0.0.0"
        let versionCStr = strdup(versionStr)
        defer { free(versionCStr) }
        // Pass nil for termios so forkpty uses the kernel's TTYDEF_* defaults
        // from <sys/ttydefaults.h>. That gives us correct c_cc values:
        // VINTR=3, VQUIT=28, VSUSP=26, VEOF=4, VERASE=0x7F, VKILL=21, plus
        // flags = (BRKINT|ICRNL|IMAXBEL|IXON|IXANY) | (OPOST|ONLCR) |
        // (ECHO|ICANON|ISIG|IEXTEN|ECHOE|ECHOKE|ECHOCTL) | (CS8|CREAD|HUPCL).
        //
        // Building these ourselves from cfmakeraw() + |= flag fixups produced
        // a broken termios: Darwin.termios() zero-inits c_cc, cfmakeraw only
        // touches VMIN/VTIME, and we never set VINTR. VINTR=0 meant Ctrl+C
        // wasn't recognized as the interrupt character at all — the line
        // discipline neither SIGINT'd the foreground pgroup nor echoed `^C`,
        // forcing a workaround of kill(-pgrp, SIGINT) that raced ahead of the
        // echo path and drew the new shell prompt before `^C\n` landed.
        let pid = withUnsafeMutablePointer(to: &master) { masterPtr in
            withUnsafeMutablePointer(to: &winsize) { wPtr in
                forkpty(masterPtr, nil, nil, wPtr)
            }
        }

        if pid < 0 {
            // On macOS forkpty closes both fds when fork itself fails, but the
            // BSD contract isn't uniform — some derivatives leave the master
            // open. Belt-and-braces: close if we hold a valid fd, so a
            // Blackbird that keeps retrying shell spawns under resource
            // pressure (hit RLIMIT_NPROC once) can't run the descriptor table
            // dry from leaked PTY masters. errno is preserved across close.
            if master >= 0 {
                let savedErrno = errno
                _ = Darwin.close(master)
                errno = savedErrno
            }
            throw Error.forkFailed(errno: errno)
        }

        if pid == 0 {
            // Child: scrub inherited app env, set shell env, chdir, exec.
            //
            // Scrub launchd / XPC / CoreFoundation plumbing variables
            // that leak from the GUI app into the child shell. These
            // confuse locale detection (__CF_USER_TEXT_ENCODING), make
            // `ps` / `env` output noisy, can cause the shell's children
            // to try to talk to the wrong XPC service (XPC_SERVICE_NAME),
            // and occasionally trigger debugging modes in downstream tools
            // (OS_ACTIVITY_DT_MODE). iTerm2 and Terminal.app strip the
            // same set. unsetenv is async-signal-safe on Darwin.
            for key in Self.scrubbedParentEnvVars {
                unsetenv(key)
            }
            // Reset signal disposition. The GUI app can install handlers
            // (Sparkle, GrandCentralDispatch, CoreFoundation) and mask
            // signals the child needs delivered at default. A shell that
            // inherits a blocked SIGINT can't be Ctrl+C'd, SIGPIPE blocked
            // makes pipelines hang, SIGCHLD blocked stalls job control.
            // Reset everything to SIG_DFL and drop the signal mask.
            var emptyMask = sigset_t()
            sigemptyset(&emptyMask)
            _ = sigprocmask(SIG_SETMASK, &emptyMask, nil)
            for sig in [SIGINT, SIGQUIT, SIGTERM, SIGHUP, SIGPIPE, SIGCHLD, SIGWINCH, SIGTSTP] {
                signal(sig, SIG_DFL)
            }
            // Close every inherited fd above stderr. forkpty has already
            // rebound stdin/stdout/stderr to the slave pty; anything else
            // the parent app had open (Metal device libraries, font files,
            // XPC mach ports backed by fds, log streams) is leaked into
            // the shell otherwise. Darwin lacks `closefrom(3)` so loop to
            // the soft open-file limit. Typically 256 fds on macOS; each
            // close of an unopened slot returns EBADF in <1µs, so the whole
            // sweep is well under a millisecond — paid once per spawn.
            //
            // Clamp the bound. `sysconf(_SC_OPEN_MAX)` returns the soft
            // `RLIMIT_NOFILE`, which a user with `ulimit -Sn unlimited`
            // inflates to effectively LONG_MAX. Unclamped, the `Int32()`
            // cast later traps on overflow and SIGILLs the child after
            // fork, leaving the master fd stranded in the parent. 65536
            // is plenty: we only need to cover every fd the GUI app has
            // opened, and apps that legitimately hold >65k fds aren't
            // spawning shells.
            let rawMax = sysconf(Int32(_SC_OPEN_MAX))
            let openMax: Int = rawMax > 65_536 || rawMax <= 0 ? 65_536 : Int(rawMax)
            if openMax > 3 {
                for fd in Int32(3)..<Int32(openMax) {
                    _ = Darwin.close(fd)
                }
            }
            for (k, v) in envOverrides {
                setenv(k, v, 1)
            }
            // TERM resolved in the parent so we don't call Foundation /
            // Process APIs between fork and exec (not async-signal-safe).
            setenv("TERM", termCStr, 1)
            setenv("COLORTERM", "truecolor", 1)   // tells modern TUIs (nvim, tmux, claude-code) 24-bit color is safe
            setenv("TERM_PROGRAM", "Blackbird", 1)
            if let v = versionCStr {
                setenv("TERM_PROGRAM_VERSION", v, 1)
            } else {
                setenv("TERM_PROGRAM_VERSION", "0.0.0", 1)
            }
            // Pick the child's starting directory:
            //  1. Explicit `initialWorkingDirectory` (from ⌘T / ⌘N inherit)
            //     if it still resolves to a real directory.
            //  2. The user's home via getpwuid — authoritative.
            //  3. $HOME fallback if passwd lookup somehow fails.
            // Apps launched from Finder inherit cwd=`/` from launchd, which
            // would otherwise start the shell in /.
            var chdired = false
            if let cwd = initialWorkingDirectory, !cwd.isEmpty {
                var st = stat()
                if stat(cwd, &st) == 0 && (st.st_mode & S_IFDIR) != 0 {
                    if chdir(cwd) == 0 { chdired = true }
                }
            }
            if !chdired {
                if let pw = getpwuid(getuid()), pw.pointee.pw_dir != nil {
                    _ = chdir(pw.pointee.pw_dir)
                } else if let home = getenv("HOME") {
                    _ = chdir(home)
                }
            }
            // Build argv
            let cArgv: [UnsafeMutablePointer<CChar>?] =
                ([executable] + arguments).map { strdup($0) } + [nil]
            defer { cArgv.forEach { if let p = $0 { free(p) } } }
            execv(executable, cArgv)
            // If exec returns, it failed.
            _exit(127)
        }

        return PTY(masterFD: master, childPID: pid)
    }

    private init(masterFD: Int32, childPID: pid_t) {
        self.masterFD = masterFD
        self.childPID = childPID
        self.startReading()
    }

    deinit {
        terminate()
    }

    // MARK: - Reading

    private func startReading() {
        readQueue.async { [weak self] in
            guard let self else { return }
            var buffer = [UInt8](repeating: 0, count: self.readBufferSize)
            while self.shouldKeepRunning() {
                let n = buffer.withUnsafeMutableBufferPointer { buf -> Int in
                    read(self.masterFD, buf.baseAddress, buf.count)
                }
                if n <= 0 {
                    // EOF or error — child has closed its side, or terminate()
                    // sent SIGHUP which caused the child to hang up.
                    self.markStopped()
                    break
                }
                let data = Data(buffer[0..<n])
                self.onBytes?(data)
            }
            // Drain any pending writes before close so they don't land on a
            // closed-and-reused fd belonging to some unrelated part of the
            // process. The write-queue block checks shouldKeepRunning() at
            // entry — markStopped above guarantees every NOT-yet-started
            // write will short-circuit, so this sync just waits for an
            // in-flight Darwin.write (if any) to return.
            self.writeQueue.sync { }
            // The read queue is the sole owner of masterFD's close. Doing it
            // here avoids a double-close / fd-reuse race against terminate()
            // calling close() on another thread. The stateQueue sync serialises
            // with writeImmediate's Darwin.write so an urgent control byte
            // (Ctrl+C, Ctrl+D) in flight from the main thread can't land on a
            // freshly-closed — and potentially reused — fd.
            self.stateQueue.sync {
                close(self.masterFD)
            }
            // Reap the child. Usually the slave close that made read()
            // return 0 also means the child has exited; waitpid is just
            // collecting the zombie. But a shell that `trap 'exit' HUP`
            // ignored SIGHUP can linger — read() still returned 0 (slave
            // fd closed by our ioctl/signal side), yet the process is
            // alive and a blocking waitpid would wedge the read queue
            // indefinitely. Poll with WNOHANG first; if the child is
            // still alive, escalate to SIGKILL and wait the hard way.
            // 200 ms of grace is plenty for a well-behaved shell to clean
            // up while still giving the window a prompt teardown.
            var status: Int32 = 0
            let gracePeriod: useconds_t = 200_000  // 200 ms
            var reaped = false
            let waited = waitpid(self.childPID, &status, WNOHANG)
            if waited == self.childPID {
                reaped = true
            } else {
                usleep(gracePeriod)
                let retry = waitpid(self.childPID, &status, WNOHANG)
                if retry == self.childPID {
                    reaped = true
                } else {
                    // Still here — SIGHUP was ignored. Force the exit.
                    _ = kill(self.childPID, SIGKILL)
                    _ = waitpid(self.childPID, &status, 0)
                    reaped = true
                }
            }
            // Extract the exit code if the child exited normally; else -1.
            let exitCode: Int32 = reaped && (status & 0x7f == 0)
                ? ((status >> 8) & 0xff)
                : -1
            DispatchQueue.main.async { [weak self] in
                self?.onExit?(exitCode)
            }
        }
    }

    // MARK: - Writing

    public func write(_ data: Data) {
        writeQueue.async { [weak self] in
            guard let self, self.shouldKeepRunning() else { return }
            // Retry loop on EINTR / EAGAIN is shared with writeImmediate.
            _ = self.writeRawLocked(data)
        }
    }

    /// Write bytes synchronously on the caller's thread with low-latency
    /// delivery. Use for urgent control bytes (SIGINT, SIGTSTP) where
    /// async dispatch latency is perceptible. Safe for single-byte
    /// writes — the kernel write is atomic at that size.
    ///
    /// Ordering: serialised under stateQueue (for teardown safety — close
    /// also grabs stateQueue, so our write can't land on a freshly-closed
    /// fd) AND writeQueue (for paste-interleave safety — a mid-paste
    /// Ctrl+C would otherwise split the paste's bracketed-paste frame).
    /// Both queues are serial; nesting is safe because the read-queue
    /// teardown path releases stateQueue before taking writeQueue and
    /// vice-versa, so there's no circular wait.
    public func writeImmediate(_ data: Data) {
        stateQueue.sync {
            guard _isRunning else { return }
            writeQueue.sync {
                _ = self.writeRawLocked(data)
            }
        }
    }

    /// Private helper that performs the actual Darwin.write retry loop on
    /// the caller's current queue. Caller MUST hold writeQueue (either via
    /// `.async` in `write` or `.sync` in `writeImmediate`). Returns true
    /// when the whole payload was delivered.
    @discardableResult
    private func writeRawLocked(_ data: Data) -> Bool {
        let fd = self.masterFD
        var delivered = true
        data.withUnsafeBytes { rawBuf -> Void in
            guard let base = rawBuf.baseAddress else { delivered = false; return }
            var remaining = rawBuf.count
            var offset = 0
            while remaining > 0 {
                let written = Darwin.write(fd, base.advanced(by: offset), remaining)
                if written > 0 {
                    remaining -= written
                    offset += written
                    continue
                }
                if errno == EINTR || errno == EAGAIN { continue }
                #if DEBUG
                NSLog("[Blackbird] PTY.write FAILED after %d/%d bytes errno=%d fd=%d",
                      offset, rawBuf.count, errno, fd)
                #endif
                delivered = false
                break
            }
        }
        return delivered
    }


    /// True when the tty has a foreground process group distinct from our
    /// child (the shell). This means `command-running` — useful for the
    /// "Confirm close while running" prompt. When the shell is at its
    /// prompt, the fg pgroup equals the shell pgroup and this returns
    /// false.
    public func hasForegroundChild() -> Bool {
        let fg = tcgetpgrp(masterFD)
        guard fg > 0 else { return false }
        // pgid of the shell process = same as its pid unless something
        // weird is happening. getpgid(pid) returns the pgroup of pid.
        let shellPgid = getpgid(childPID)
        if shellPgid <= 0 { return false }
        return fg != shellPgid
    }

    /// Current working directory of the tty's foreground process. Reads via
    /// `proc_pidinfo(PROC_PIDVNODEPATHINFO)` on the foreground pgroup leader
    /// — that gives the "active" cwd: if the shell is at a prompt it's the
    /// shell's cwd, if a subshell/command is running it's that child's cwd.
    /// This matches what Terminal.app / iTerm2 inherit when you hit ⌘T.
    /// Returns nil on any syscall failure.
    public func foregroundWorkingDirectory() -> String? {
        let fg = tcgetpgrp(masterFD)
        let targetPID: pid_t = fg > 0 ? fg : childPID
        var info = proc_vnodepathinfo()
        let bytes = proc_pidinfo(
            targetPID,
            PROC_PIDVNODEPATHINFO,
            0,
            &info,
            Int32(MemoryLayout<proc_vnodepathinfo>.size)
        )
        guard bytes > 0 else { return nil }
        return withUnsafePointer(to: &info.pvi_cdir.vip_path) { tuple -> String? in
            tuple.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { cstr in
                let s = String(cString: cstr)
                return s.isEmpty ? nil : s
            }
        }
    }

    /// Send a signal directly to the foreground process group of the terminal.
    /// For SIGINT (Ctrl+C) this is more reliable than writing 0x03 to the
    /// master fd, because the shell may have turned off ISIG or changed VINTR
    /// in its termios settings. `tcgetpgrp` returns the foreground pgroup of
    /// the slave side; `kill(-pgrp, sig)` targets the whole group.
    public func sendSignalToForeground(_ sig: Int32) {
        let pgrp = tcgetpgrp(masterFD)
        if pgrp > 0 {
            kill(-pgrp, sig)
        }
    }

    // MARK: - Resize

    public func resize(to size: Size) {
        var winsize = Darwin.winsize(
            ws_row: size.rows, ws_col: size.cols,
            ws_xpixel: 0, ws_ypixel: 0
        )
        _ = withUnsafeMutablePointer(to: &winsize) { ptr in
            ioctl(masterFD, TIOCSWINSZ, ptr)
        }
    }

    // MARK: - Teardown

    public func terminate() {
        guard shouldKeepRunning() else { return }
        markStopped()
        // Send SIGHUP to the child to make the blocked read(2) in the read
        // queue return. The read queue is the sole owner of masterFD's close
        // and the child's reap — see startReading(). This avoids racing close()
        // against the read loop's read(), which could otherwise produce a
        // double-close or an fd-reuse bug under rapid session churn (Plan 4).
        kill(childPID, SIGHUP)
    }
}
