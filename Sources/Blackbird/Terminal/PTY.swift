import Foundation
import Darwin
import os

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
        // Apple dyld injection surface. If Blackbird is ever run under
        // mitmproxy / SimulatorTrampoline / a debugging shim, any of these
        // leaking into the child shell means the first `sudo` / `curl`
        // inherits the injected library — a privilege-adjacent footgun.
        "DYLD_LIBRARY_PATH",
        "DYLD_INSERT_LIBRARIES",
        "DYLD_FRAMEWORK_PATH",
        "DYLD_FALLBACK_LIBRARY_PATH",
        "DYLD_FALLBACK_FRAMEWORK_PATH",
        "DYLD_PRINT_TO_FILE",
        "DYLD_PRINT_APIS",
        "DYLD_PRINT_STATISTICS",
        // Xcode / Instruments injection that changes libc allocator
        // behavior in child processes — surprising when it leaks.
        "MallocNanoZone",
        // Unified-logging silencing used outside Xcode proper. Distinct
        // from OS_ACTIVITY_DT_MODE above; both need scrubbing.
        "OS_ACTIVITY_MODE",
        // CoreAnimation debug flags. If the GUI inherited these from a
        // debug launch, they spam any child GUI / SwiftUI command with
        // transaction asserts unrelated to the user's session.
        "CA_DEBUG_TRANSACTIONS",
        "CA_ASSERT_MAIN_THREAD_TRANSACTIONS",
    ]

    private let masterFD: Int32
    private let childPID: pid_t
    /// BSD start time of `childPID` captured at spawn. Used by
    /// `terminate()` to detect PID reuse before escalating to SIGKILL.
    /// Format: (tv_sec, tv_usec) since the system epoch — uniquely
    /// identifies a process even if its pid is later recycled. Nil
    /// means the start-time read failed at spawn (rare on a healthy
    /// system); per audit H-1 the SIGKILL escalation now skips
    /// rather than firing unconditionally in that case, because
    /// without a baseline we cannot prove the pid still belongs
    /// to our child if the kernel has recycled it.
    ///
    /// Both fields are `UInt64` because that's what `proc_bsdinfo`'s
    /// `pbi_start_tvsec` / `pbi_start_tvusec` deliver on Darwin.
    private let childStartTime: (sec: UInt64, usec: UInt64)?
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

    /// Shared `os.Logger` for PTY diagnostics (read-loop errno, envOverride
    /// rejections). `os.Logger` — not `NSLog` — so messages appear in
    /// `log stream --predicate 'subsystem == "dev.conjfrnk.blackbird"'`
    /// instead of being redacted to `<private>`.
    private static let logger = Logger(subsystem: "dev.conjfrnk.blackbird",
                                       category: "pty")

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

    /// Read the BSD start time of `pid` via `proc_pidinfo` /
    /// `PROC_PIDTBSDINFO`. Returns the (sec, usec) pair from the
    /// process's `pbi_start_tvsec` / `pbi_start_tvusec` fields, which
    /// uniquely identify a process across PID reuse — kernel
    /// guarantees the start time is set at fork() and never modified.
    /// Returns nil if proc_pidinfo fails (process doesn't exist yet,
    /// permission denied, or kernel-info unavailable). Audit M9.
    private static func bsdProcessStartTime(pid: pid_t) -> (sec: UInt64, usec: UInt64)? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.stride)
        let n = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size)
        guard n == size else { return nil }
        return (sec: info.pbi_start_tvsec, usec: info.pbi_start_tvusec)
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
            // Validate envOverrides before handing them to `setenv`. Swift
            // String → C bridging truncates at the first NUL, so a key like
            // `"PATH\0.malicious"` would silently reach `setenv` as `PATH`
            // and an attacker-controlled value could be split on NUL. A
            // key containing `=` is outright rejected by POSIX setenv but
            // filtering it here keeps errno clean and the log readable.
            // Logging rather than crashing: this runs post-fork-pre-exec
            // where async-signal-safety matters and libc asserts aren't
            // safe. os.Logger's underlying `os_log` is documented as
            // async-signal-safe on Darwin.
            for (k, v) in envOverrides {
                if k.isEmpty || k.contains("\0") || k.contains("=") {
                    Self.logger.log(
                        "PTY.spawn rejecting envOverride: invalid key (empty / contains NUL or '=')"
                    )
                    continue
                }
                if v.contains("\0") {
                    // SEC-015: env-key NAMES can themselves be sensitive
                    // (`AWS_SECRET_ACCESS_KEY`, `OPENAI_API_KEY`). Hash
                    // the key so unified-log readers see a stable
                    // identifier without the literal name.
                    Self.logger.log(
                        "PTY.spawn rejecting envOverride for key=\(k, privacy: .private(mask: .hash)): value contains NUL"
                    )
                    continue
                }
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
            //
            // Triple-failure abort (audit M8): if every candidate fails
            // to chdir, exit 127 BEFORE execv runs. Otherwise the shell
            // starts at whatever cwd the post-fork inherited (typically
            // `/` under launchd, the working directory the user just
            // left under cmd-T), which is silently wrong and confuses
            // shell prompt / git / project tooling. _exit(127) matches
            // the execv-failed path below; the parent sees a child that
            // exited with 127 and surfaces the same UI as a missing
            // shell binary.
            var chdired = false
            if let cwd = initialWorkingDirectory, !cwd.isEmpty {
                var st = stat()
                if stat(cwd, &st) == 0 && (st.st_mode & S_IFDIR) != 0 {
                    if chdir(cwd) == 0 { chdired = true }
                }
            }
            if !chdired,
               let pw = getpwuid(getuid()), pw.pointee.pw_dir != nil,
               chdir(pw.pointee.pw_dir) == 0 {
                chdired = true
            }
            if !chdired,
               let home = getenv("HOME"),
               chdir(home) == 0 {
                chdired = true
            }
            if !chdired {
                // Final defense: try /tmp before giving up entirely. A
                // shell starting in /tmp is unusual but harmless; a
                // shell starting at `/` (launchd inheritance) is the
                // pre-M8 silent failure we're avoiding here.
                if chdir("/tmp") == 0 {
                    chdired = true
                }
            }
            if !chdired {
                _exit(127)
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
        // Capture the child's BSD start time at spawn so the SIGKILL
        // escalation in `terminate()` can detect PID reuse: if the
        // 200ms grace window outlives our child AND macOS recycles
        // the PID for an unrelated process, `kill(pid, 0)` returns
        // success on the recycled PID even though it isn't ours.
        // Comparing start times rules out that race. Audit M9.
        self.childStartTime = Self.bsdProcessStartTime(pid: childPID)
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
                if n > 0 {
                    let data = Data(buffer[0..<n])
                    self.onBytes?(data)
                    continue
                }
                if n == 0 {
                    // Genuine EOF — slave closed, child has exited.
                    self.markStopped()
                    break
                }
                // n < 0: inspect errno. EINTR is always safe to retry;
                // EAGAIN/EWOULDBLOCK shouldn't normally fire on a blocking
                // fd but retry defensively in case any subsystem toggles
                // O_NONBLOCK. Any other errno — EIO (slave gone), EBADF
                // (fd closed under us), ENXIO, etc. — means the session
                // is unrecoverable; log and tear down.
                let savedErrno = errno
                if savedErrno == EINTR { continue }
                if savedErrno == EAGAIN || savedErrno == EWOULDBLOCK { continue }
                Self.logger.log(
                    "PTY.read error errno=\(savedErrno, privacy: .public) fd=\(self.masterFD, privacy: .public) — tearing down"
                )
                self.markStopped()
                break
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
            // `reaped` guards against ever treating an un-reaped child as
            // having an exit status. Also serves as a structural barrier
            // to double-reap if this teardown block is ever re-entered
            // (it shouldn't be — the read loop runs once per PTY — but
            // the flag keeps the invariant explicit rather than implicit).
            var reaped = false
            let waited = waitpid(self.childPID, &status, WNOHANG)
            if waited == self.childPID {
                reaped = true
            } else if waited < 0 && errno == ECHILD {
                // Already reaped elsewhere (shouldn't happen — no one else
                // waits on childPID — but treat as "unknown" rather than
                // looping on a non-existent child).
                reaped = false
            } else {
                usleep(gracePeriod)
                let retry = waitpid(self.childPID, &status, WNOHANG)
                if retry == self.childPID {
                    reaped = true
                } else if retry < 0 && errno == ECHILD {
                    reaped = false
                } else {
                    // Still here — SIGHUP was ignored. Force the exit.
                    //
                    // Audit follow-up (2026-04-29): sibling of L-4
                    // SIGHUP rc/errno capture (commits d12d96e +
                    // 8a78a94). A failure here means SIGKILL didn't
                    // reach the child — useful to know. ESRCH (child
                    // already exited between the previous `waitpid`
                    // and this `kill`) is normal teardown; everything
                    // else is a real failure worth logging.
                    let killRC = kill(self.childPID, SIGKILL)
                    if killRC != 0 {
                        let savedErrno = errno
                        let level: OSLogType = (savedErrno == ESRCH) ? .info : .error
                        Self.logger.log(level: level, "PTY read-loop teardown: kill(\(self.childPID, privacy: .public), SIGKILL) failed errno=\(savedErrno, privacy: .public) (\(String(cString: strerror(savedErrno)), privacy: .public))")
                    }
                    let forced = waitpid(self.childPID, &status, 0)
                    reaped = (forced == self.childPID)
                }
            }
            // Decode the child's termination status per POSIX. Callers
            // historically treated -1 as "unknown / session torn down";
            // preserve that for timeout / un-reaped paths. Otherwise:
            //   - WIFEXITED: raw exit code 0..255
            //   - WIFSIGNALED: 128 + signum (standard shell convention so
            //     e.g. a SIGSEGV (11) surfaces as 139, SIGKILL (9) as 137,
            //     letting a future crash-reporter distinguish "shell
            //     exited cleanly" from "shell died of signal").
            let exitCode: Int32
            if !reaped {
                exitCode = -1
            } else if (status & 0x7f) == 0 {
                // WIFEXITED: low 7 bits clear means normal exit.
                exitCode = (status >> 8) & 0xff
            } else if (status & 0x7f) != 0x7f && (status & 0x7f) != 0 {
                // WIFSIGNALED: low 7 bits are the terminating signal,
                // and they're neither 0 (exited) nor 0x7f (stopped).
                let signum = status & 0x7f
                exitCode = 128 + signum
            } else {
                // WIFSTOPPED or otherwise unclassifiable — the child
                // wasn't actually terminated. Treat as unknown.
                exitCode = -1
            }
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
    /// Ordering: enters writeQueue under `.sync` so a pending paste can't
    /// interleave our bytes into its bracketed-paste frame. Then checks
    /// shouldKeepRunning (via stateQueue) to bail safely if teardown
    /// has already marked us stopped. Lock order is `writeQueue →
    /// stateQueue` — same as `write()` — so no circular wait with
    /// teardown's `markStopped; writeQueue.sync {}; close(fd)` sequence.
    public func writeImmediate(_ data: Data) {
        writeQueue.sync {
            guard self.shouldKeepRunning() else { return }
            _ = self.writeRawLocked(data)
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
                if errno == EINTR { continue }
                if errno == EAGAIN || errno == EWOULDBLOCK {
                    // EAGAIN doesn't normally fire on a blocking fd
                    // (which we open by default), but a future
                    // refactor could flip the master to O_NONBLOCK and
                    // a tight `continue` loop here would burn 100% CPU
                    // until the kernel buffer drains. Sleep briefly to
                    // yield back the scheduler on each retry. Audit
                    // pty F7.
                    usleep(200)
                    continue
                }
                // SFH-001: log in Release too. A PTY write that fails with
                // EPIPE / EIO / ENOSPC silently vanishes a user keystroke or
                // IME commit — the user sees no shell response and no
                // diagnostic trail. `log stream --predicate 'subsystem ==
                // "dev.conjfrnk.blackbird"'` now surfaces the errno in
                // production.
                let savedErrno = errno
                Self.logger.error(
                    "PTY.write FAILED after \(offset, privacy: .public)/\(rawBuf.count, privacy: .public) bytes errno=\(savedErrno, privacy: .public) fd=\(fd, privacy: .public)"
                )
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
        // F-S5-001: serialise the `masterFD` read against the read-loop's
        // close. Without this, a `tcgetpgrp` call that races a close can
        // hit a kernel-recycled fd belonging to another subsystem
        // (network socket, log fd, another PTY master) and return a
        // bogus pgroup. When the PTY is already stopped there's nothing
        // to report — skip the syscall entirely.
        return stateQueue.sync {
            guard _isRunning else { return false }
            let fg = tcgetpgrp(masterFD)
            guard fg > 0 else { return false }
            let shellPgid = getpgid(childPID)
            if shellPgid <= 0 {
                // ECHILD typically — means the shell process is gone. No
                // foreground child to report; return false so callers don't
                // block on a dead session. Audit pty F5.
                return false
            }
            // Normal case: the shell's pgid equals its pid, and
            // `fg != shellPgid` means some other process group is the
            // foreground (a command running under the shell). If the shell
            // has deliberately `setpgid`'d to a different pgroup — rare, but
            // legal — this comparison is the right one: we're asking "is
            // the FOREGROUND tty-reader different from the SHELL pgroup?",
            // which is what close-confirm and cwd-inheritance actually need.
            return fg != shellPgid
        }
    }

    /// Current working directory of the tty's foreground process. Reads via
    /// `proc_pidinfo(PROC_PIDVNODEPATHINFO)` on the foreground pgroup leader
    /// — that gives the "active" cwd: if the shell is at a prompt it's the
    /// shell's cwd, if a subshell/command is running it's that child's cwd.
    /// This matches what Terminal.app / iTerm2 inherit when you hit ⌘T.
    /// Returns nil on any syscall failure.
    public func foregroundWorkingDirectory() -> String? {
        // F-S5-001: same fd-close race as `hasForegroundChild`. Capture
        // the target PID under the state lock, then do the out-of-lock
        // `proc_pidinfo` syscall so we don't hold the lock across kernel
        // work.
        let targetPID: pid_t? = stateQueue.sync {
            guard _isRunning else { return nil }
            let fg = tcgetpgrp(masterFD)
            return fg > 0 ? fg : childPID
        }
        guard let pid = targetPID else { return nil }
        var info = proc_vnodepathinfo()
        let infoSize = Int32(MemoryLayout<proc_vnodepathinfo>.stride)
        let bytes = proc_pidinfo(
            pid,
            PROC_PIDVNODEPATHINFO,
            0,
            &info,
            infoSize
        )
        // Audit L-8: require a complete fill, matching sibling
        // `bsdProcessStartTime`'s `n == size` invariant. Darwin's
        // proc_pidinfo today returns the full struct or fails outright,
        // but the kernel contract permits a short return that leaves
        // the tail zero-filled — which would silently turn a partial
        // pvi_cdir into a blank or truncated path. Treat any short
        // return as failure rather than trusting a partially populated
        // struct. Sibling-symmetric with bsdProcessStartTime.
        //
        // Distinguish the two failure modes: bytes <= 0 is a legit
        // syscall failure (process exited, EPERM under sandbox, etc.)
        // and is expected; a short positive return is a kernel-contract
        // violation that today never fires but, if Darwin's behavior
        // ever changes (kernel update, new sandbox profile), would
        // otherwise silently break cwd inheritance with zero diagnostic
        // signal. Log the short-read case so a future debugger sees it.
        guard bytes > 0 else { return nil }
        guard bytes == infoSize else {
            Self.logger.error("foregroundWorkingDirectory: proc_pidinfo short read pid=\(pid, privacy: .public) got=\(bytes, privacy: .public) want=\(infoSize, privacy: .public) — kernel contract violation, returning nil")
            return nil
        }
        return withUnsafePointer(to: &info.pvi_cdir.vip_path) { tuple -> String? in
            tuple.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { cstr in
                let s = String(cString: cstr)
                return s.isEmpty ? nil : s
            }
        }
    }

    /// Basenames of binaries that, when present in the PTY's foreground
    /// process tree, mean "the user is looking at a different filesystem
    /// namespace right now." A shell running on the other side of any of
    /// these wrappers can still emit OSC 7 — but the path it reports
    /// doesn't exist on our local fs, so dereferencing it (titlebar proxy
    /// icon, "Open in Finder", new-tab cwd inheritance) is a security
    /// hazard. KNOWN_ISSUES.md "OSC 7 trust over SSH" / audit synthesis #4.
    ///
    /// Conservative set — `scp` / `rsync` / `git` are intentionally
    /// excluded because they don't run an interactive shell that can
    /// emit OSC 7. False positives (gate fires when the user *isn't*
    /// remote) are merely a correctness regression — `lastKnownCwd`
    /// stays at its last trusted value. False negatives (gate misses an
    /// actual remote shell) are the security risk we're guarding
    /// against, so when in doubt, add to the set.
    private static let remoteShellBinaryBasenames: Set<String> = [
        "ssh", "slogin", "mosh-client", "telnet",
        "docker", "podman", "nerdctl", "kubectl", "lima",
    ]

    #if DEBUG
    /// Test-only read-only view of the set. Lets a unit test pin the
    /// canonical wrappers without exposing a mutable knob to production.
    static var remoteShellBinaryBasenamesForTests: Set<String> {
        remoteShellBinaryBasenames
    }
    #endif

    /// Verdict from the foreground process-tree walk. Three states —
    /// `Bool` would conflate "definitely local" with "couldn't tell" and
    /// the security gate's posture differs sharply between them. Forced
    /// destructuring at the call site keeps the fail-closed posture
    /// honest: callers must explicitly decide what to do with `.unknown`,
    /// not silently trip into the `false` branch.
    public enum ForegroundNamespace: Equatable {
        /// Walk completed and found no remote-shell binary in the tree.
        case local
        /// Walk found a binary in `remoteShellBinaryBasenames` — the
        /// user is SSH'd / inside `docker exec` / etc. The associated
        /// values let a future caller (titlebar "remote" indicator)
        /// avoid re-walking.
        case remote(basename: String, pid: pid_t)
        /// Walk could not complete: PTY not running, `tcgetpgrp ≤ 0`,
        /// `proc_listpids` failure, BFS cap hit. The OSC 7 gate treats
        /// this as remote (fail-closed).
        case unknown(reason: String)
    }

    /// Classify the PTY's foreground process tree. The OSC 7 ingest gate
    /// in `TerminalSession` trusts the shell-reported cwd ONLY when the
    /// result is `.local`; both `.remote` and `.unknown` cause the
    /// payload to be dropped. KNOWN_ISSUES.md "OSC 7 trust over SSH" /
    /// audit synthesis #4.
    ///
    /// Walks via BFS rooted at the foreground pgroup leader. Each node:
    ///   - basename(`proc_pidpath(pid)`) → check membership
    ///   - children = `proc_listpids(PROC_PPID_ONLY, pid, ...)`
    /// Bounded: a deep tree is capped at 256 nodes to keep this from
    /// becoming a slow path. OSC 7 fires at most once per shell `cd`,
    /// so total cost is a handful of syscalls per `cd` — well below the
    /// frame budget even on the main queue (the OSC event sink runs
    /// there). Audit synthesis #4.
    ///
    /// On any error the function returns `.unknown` rather than
    /// silently trusting the shell — opposite of `hasForegroundChild` /
    /// `foregroundWorkingDirectory` which fail-open because they're
    /// advisory UI features, not security gates.
    public func classifyForegroundNamespace() -> ForegroundNamespace {
        // F-S5-001: serialise the masterFD read against the read-loop's
        // close, same as `hasForegroundChild` / `foregroundWorkingDirectory`.
        let rootPID: pid_t? = stateQueue.sync {
            guard _isRunning else { return nil }
            let fg = tcgetpgrp(masterFD)
            return fg > 0 ? fg : nil
        }
        guard let root = rootPID else {
            return .unknown(reason: "PTY not running or tcgetpgrp ≤ 0")
        }
        return Self.classifyProcessTree(rootPID: root)
    }

    /// Hoisted out as a static so unit tests covering the BFS itself
    /// can pin it without driving a real PTY. The public API still goes
    /// through the masterFD-locked entry point above. Test-only entry
    /// point — production callers must use `classifyForegroundNamespace()`
    /// so the masterFD lifecycle gate fires.
    static func classifyProcessTree(rootPID: pid_t) -> ForegroundNamespace {
        // BFS through the process tree. `seen` guards against cycles —
        // shouldn't happen in a well-formed UNIX process graph, but a
        // bug in `proc_listpids` returning stale data could otherwise
        // loop us. Cap traversal at 256 nodes; on overflow we treat the
        // result as `.unknown` (fail-closed) rather than silently
        // returning `.local`.
        var queue: [pid_t] = [rootPID]
        var seen: Set<pid_t> = [rootPID]
        var examined = 0
        let cap = 256

        while let pid = queue.popLast() {
            examined += 1
            if examined > cap {
                Self.logger.warning("classifyProcessTree: BFS hit cap=\(cap, privacy: .public) at pid=\(pid, privacy: .public); returning .unknown (fail-closed)")
                return .unknown(reason: "BFS cap (\(cap)) exceeded")
            }
            if let basename = Self.executableBasename(pid: pid),
               Self.remoteShellBinaryBasenames.contains(basename) {
                return .remote(basename: basename, pid: pid)
            }
            for child in Self.childPIDs(parent: pid) where !seen.contains(child) {
                seen.insert(child)
                queue.append(child)
            }
        }
        return .local
    }

    /// `proc_pidpath` → last path component. Returns nil if the pid is
    /// gone or the syscall fails.
    ///
    /// Buffer is sized to `4 * MAXPATHLEN` per `<sys/proc_info.h>`'s
    /// `PROC_PIDPATHINFO_MAXSIZE` (that constant lives in an internal
    /// header not surfaced through `Darwin`, so we compute the same
    /// value inline). Apple uses 4× headroom because exec'd binaries
    /// can have long paths after symlink resolution.
    private static func executableBasename(pid: pid_t) -> String? {
        let bufSize = 4 * Int(MAXPATHLEN)
        var buf = [CChar](repeating: 0, count: bufSize)
        let n = proc_pidpath(pid, &buf, UInt32(bufSize))
        guard n > 0 else { return nil }
        let path = String(cString: buf)
        guard !path.isEmpty else { return nil }
        return (path as NSString).lastPathComponent
    }

    /// Children of `parent` via `proc_listpids(PROC_PPID_ONLY, ...)`.
    /// Two-call pattern: probe size first, then fill.
    ///
    /// TOCTOU note: between probe and fill, `parent` may gain new
    /// children. The fill call is bounded by the byte length we pass
    /// (`buf.count * stride`), so the kernel truncates rather than
    /// overflows — `prefix(cap)` clamps the resulting slice. Truncation
    /// causes us to miss new children, which is a fail-closed outcome
    /// at the BFS level (we don't see the new branch, but the BFS still
    /// completes; the caller's `.local` result for a fork-bombing
    /// process is suspect, but the gate caller treats `.local` as the
    /// "trusted" verdict only — a missed remote-binary descendant in a
    /// fork-bombing tree is the exact case where the gate's BFS cap
    /// also fires and forces `.unknown`.
    ///
    /// Returns an empty array on syscall failure (which is
    /// indistinguishable from "no children"). Callers reaching this
    /// path with a parent they expected to have children should treat
    /// the whole walk as suspect.
    private static func childPIDs(parent: pid_t) -> [pid_t] {
        let probe = proc_listpids(UInt32(PROC_PPID_ONLY), UInt32(parent), nil, 0)
        guard probe > 0 else { return [] }
        let cap = Int(probe) / MemoryLayout<pid_t>.stride
        guard cap > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: cap)
        let written = pids.withUnsafeMutableBufferPointer { buf -> Int32 in
            proc_listpids(UInt32(PROC_PPID_ONLY), UInt32(parent), buf.baseAddress, Int32(buf.count * MemoryLayout<pid_t>.stride))
        }
        guard written > 0 else { return [] }
        // Clamp to the buffer we allocated; the syscall is byte-bounded
        // by the size we passed, so `count` cannot exceed `cap` in
        // practice — but `prefix(cap)` makes that invariant local.
        let count = min(Int(written) / MemoryLayout<pid_t>.stride, cap)
        return Array(pids.prefix(count)).filter { $0 > 0 }
    }

    /// Send a signal directly to the foreground process group of the terminal.
    /// For SIGINT (Ctrl+C) this is more reliable than writing 0x03 to the
    /// master fd, because the shell may have turned off ISIG or changed VINTR
    /// in its termios settings. `tcgetpgrp` returns the foreground pgroup of
    /// the slave side; `kill(-pgrp, sig)` targets the whole group.
    public func sendSignalToForeground(_ sig: Int32) {
        // F-S5-001: serialise against the read-loop close. `kill(-pgrp)`
        // stays outside the lock so we don't hold it across a signal-
        // delivery syscall.
        let pgrp: pid_t = stateQueue.sync {
            guard _isRunning else { return 0 }
            return tcgetpgrp(masterFD)
        }
        if pgrp > 0 {
            // Audit L-4: capture rc. ESRCH (the realistic case — a race
            // between tcgetpgrp returning the pgroup and that pgroup's
            // leader exiting) silently dropped the user's Ctrl+C before
            // this log fired. Production now surfaces the errno via
            // `log stream --predicate 'subsystem == "dev.conjfrnk.blackbird"'`.
            // ESRCH is the *expected* race when the foreground pgroup
            // leader has already exited — log at .info to avoid spam on
            // every shell-exit / Ctrl+C race. EINVAL/EPERM are real
            // failures and stay at .error.
            let rc = kill(-pgrp, sig)
            if rc < 0 {
                let savedErrno = errno
                let level: OSLogType = (savedErrno == ESRCH) ? .info : .error
                Self.logger.log(level: level, "sendSignalToForeground: kill(-\(pgrp, privacy: .public), \(sig, privacy: .public)) failed errno=\(savedErrno, privacy: .public) (\(String(cString: strerror(savedErrno)), privacy: .public))")
            }
        } else {
            let savedErrno = errno
            Self.logger.warning("sendSignalToForeground: tcgetpgrp returned \(pgrp, privacy: .public) errno=\(savedErrno, privacy: .public) (\(String(cString: strerror(savedErrno)), privacy: .public))")
        }
    }

    // MARK: - Resize

    public func resize(to size: Size) {
        // Reject zero / nonsense dims before touching the ioctl — a
        // degenerate winsize (cols=0 or rows=0) leaves the child's
        // termios in an unusable state and silently breaks anything
        // that queries terminal width. TerminalSession already clamps
        // for the BBTerm side, but PTY is a public class that a future
        // caller could exercise directly; defence in depth. Audit
        // pty F4.
        guard size.cols > 0, size.rows > 0 else {
            Self.logger.log(
                "PTY.resize refused degenerate dims cols=\(size.cols, privacy: .public) rows=\(size.rows, privacy: .public)"
            )
            return
        }
        var winsize = Darwin.winsize(
            ws_row: size.rows, ws_col: size.cols,
            ws_xpixel: 0, ws_ypixel: 0
        )
        // F-S5-001: serialise against the read-loop close. `ioctl` on a
        // freshly-recycled fd belonging to another subsystem is exactly
        // the TOCTOU the review flagged. When the PTY has stopped there
        // is no-one to send SIGWINCH to, so the ioctl is a no-op; skip.
        let result: Int32 = stateQueue.sync {
            guard _isRunning else { return 0 }
            return withUnsafeMutablePointer(to: &winsize) { ptr in
                ioctl(masterFD, TIOCSWINSZ, ptr)
            }
        }
        if result != 0 {
            let savedErrno = errno
            Self.logger.log(
                "PTY.resize TIOCSWINSZ failed errno=\(savedErrno, privacy: .public)"
            )
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
        //
        // Capture rc to complete the L-4 "all signals observable"
        // invariant. Today this is structurally safe (`childPID` cannot
        // be recycled mid-`terminate()`), but a failure here means
        // SIGHUP didn't reach the child — useful to know. ESRCH (child
        // already exited) is normal teardown; everything else is a
        // real failure.
        let hupRC = kill(childPID, SIGHUP)
        if hupRC < 0 {
            let savedErrno = errno
            let level: OSLogType = (savedErrno == ESRCH) ? .info : .error
            Self.logger.log(level: level, "terminate: kill(\(self.childPID, privacy: .public), SIGHUP) failed errno=\(savedErrno, privacy: .public) (\(String(cString: strerror(savedErrno)), privacy: .public))")
        }
        // Audit pty F3. A shell running `trap '' HUP` (or any other
        // HUP-ignoring init flow) won't close the slave fd in response
        // to the signal above, so the read loop stays blocked forever
        // and the child-process + master-fd never get cleaned up.
        // Schedule an asynchronous escalation to SIGKILL after a short
        // grace period — SIGKILL cannot be trapped, so the kernel
        // forces the child's exit, which closes the slave fd and the
        // read loop picks up EOF and runs its normal teardown path
        // (close + waitpid) from there.
        //
        // Use `asyncAfter` on a global concurrent queue so the
        // escalation work doesn't block the caller's thread (the
        // caller is usually main via `TerminalSession.terminate` /
        // deinit) and doesn't hold any of PTY's serial queues —
        // holding `stateQueue` for 200ms would stall the read loop's
        // close handshake, and holding `writeQueue` would stall any
        // in-flight `writeImmediate` that raced past the `markStopped`
        // early-return. The escalation block reads only the captured
        // `pid` (a value type) and calls `kill` directly; no shared
        // state is accessed.
        let pid = childPID
        let originalStartTime = childStartTime
        DispatchQueue.global(qos: .userInitiated).asyncAfter(
            deadline: .now() + .milliseconds(200)
        ) {
            // Poll for the child. `kill(pid, 0)` returns 0 iff the
            // process exists and we can signal it. A non-zero return
            // means ESRCH (already exited) or EPERM (impossible here
            // since we're the parent); either way, don't escalate.
            guard kill(pid, 0) == 0 else { return }
            // PID-reuse guard (audit M9 + PS-02): macOS may have
            // recycled the pid for an unrelated process if our
            // original child exited inside the 200ms grace window AND
            // another process spawned and got the same pid. Compare
            // the current process's BSD start time against the value
            // we captured at spawn — if they differ, OR if we cannot
            // read the start time at all, the kernel has handed this
            // pid to a different process (or is in the middle of
            // doing so, with proc_pidinfo racing the spawn) and we
            // MUST NOT SIGKILL it. The earlier shape (`if let original
            // = …, let current = …, current != original`) used
            // compound `if let` binding: if `current` was nil the
            // entire condition was false and execution fell through
            // to the unguarded `kill(pid, SIGKILL)` against the
            // recycled stranger. The guards below treat "can't
            // verify" as "skip", which is the safe direction.
            guard let original = originalStartTime else {
                // No start-time was captured at spawn (audit H-1).
                // `bsdProcessStartTime` can transiently fail at fork
                // for any kernel-info reason — proc_pidinfo races a
                // partially-set-up process, EPERM under sandbox, etc.
                // Without a baseline we cannot prove the pid still
                // belongs to our child, so we MUST NOT escalate: if
                // the child exited inside the 200ms grace window and
                // macOS recycled its pid, an unconditional SIGKILL
                // here would terminate the unrelated stranger. Skip
                // is the safe-by-default direction; the read loop's
                // SIGHUP will still tear down a well-behaved child,
                // and a HUP-ignoring child without a start-time
                // baseline is the rare-rare case we accept lingering
                // over killing the wrong process. The pre-M9
                // unconditional-kill comment that lived here was
                // wrong by today's standards.
                Self.logger.log(
                    "PTY.terminate skipping SIGKILL pid=\(pid, privacy: .public) (no start-time captured at spawn)"
                )
                return
            }
            guard let current = Self.bsdProcessStartTime(pid: pid) else {
                Self.logger.log(
                    "PTY.terminate skipped SIGKILL: pid=\(pid, privacy: .public) start-time unreadable, cannot verify identity"
                )
                return
            }
            guard current == original else {
                Self.logger.log(
                    "PTY.terminate skipped SIGKILL: pid=\(pid, privacy: .public) reused by another process"
                )
                return
            }
            // Audit follow-up (2026-04-29): sibling of L-4 SIGHUP
            // rc/errno capture (commits d12d96e + 8a78a94). Capture
            // rc/errno here too: ESRCH at this point means the child
            // exited between the `current == original` check above
            // and this `kill` — vanishingly rare, but still informational.
            // Anything else is a real failure (e.g. EPERM if we
            // somehow lost privilege to signal our own child).
            let killRC = kill(pid, SIGKILL)
            if killRC != 0 {
                let savedErrno = errno
                let level: OSLogType = (savedErrno == ESRCH) ? .info : .error
                Self.logger.log(level: level, "PTY.terminate escalation: kill(\(pid, privacy: .public), SIGKILL) failed errno=\(savedErrno, privacy: .public) (\(String(cString: strerror(savedErrno)), privacy: .public))")
            } else {
                Self.logger.log(
                    "PTY.terminate escalated to SIGKILL pid=\(pid, privacy: .public) (HUP-ignoring child)"
                )
            }
        }
    }
}
