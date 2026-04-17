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

    private let masterFD: Int32
    private let childPID: pid_t
    private let readQueue = DispatchQueue(label: "blackbird.pty.read", qos: .userInitiated)
    private let writeQueue = DispatchQueue(label: "blackbird.pty.write", qos: .userInitiated)
    private let stateQueue = DispatchQueue(label: "blackbird.pty.state")
    private var _isRunning = true
    private let readBufferSize = 16 * 1024

    private func shouldKeepRunning() -> Bool {
        stateQueue.sync { _isRunning }
    }

    private func markStopped() {
        stateQueue.sync { _isRunning = false }
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

        if pid < 0 { throw Error.forkFailed(errno: errno) }

        if pid == 0 {
            // Child: set env, chdir to home, then exec.
            for (k, v) in envOverrides {
                setenv(k, v, 1)
            }
            setenv("TERM", "xterm-256color", 1)
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
            // calling close() on another thread.
            close(self.masterFD)
            // Blocking waitpid is safe here: the read loop exited because
            // the child closed the slave end, so it has exited or is about to.
            var status: Int32 = 0
            _ = waitpid(self.childPID, &status, 0)
            // Extract the exit code if the child exited normally; else -1.
            let exitCode: Int32 = (status & 0x7f == 0) ? ((status >> 8) & 0xff) : -1
            DispatchQueue.main.async { [weak self] in
                self?.onExit?(exitCode)
            }
        }
    }

    // MARK: - Writing

    public func write(_ data: Data) {
        writeQueue.async { [weak self] in
            guard let self, self.shouldKeepRunning() else { return }
            let fd = self.masterFD
            data.withUnsafeBytes { rawBuf -> Void in
                guard let base = rawBuf.baseAddress else { return }
                var remaining = rawBuf.count
                var offset = 0
                while remaining > 0 {
                    let written = Darwin.write(fd, base.advanced(by: offset), remaining)
                    if written > 0 {
                        remaining -= written
                        offset += written
                        continue
                    }
                    // EINTR / EAGAIN: retry. The master-side pipe can
                    // legitimately report "try again" under back-pressure
                    // (slow consumer). Previously we swallowed the whole
                    // remaining payload on any non-positive return — silent
                    // data loss on paste.
                    if errno == EINTR || errno == EAGAIN { continue }
                    #if DEBUG
                    NSLog("[Blackbird] PTY.write FAILED after %d/%d bytes errno=%d fd=%d",
                          offset, rawBuf.count, errno, fd)
                    #endif
                    break
                }
            }
        }
    }

    /// Write bytes synchronously on the caller's thread, bypassing writeQueue.
    /// Use for urgent control bytes (SIGINT, SIGTSTP) where async dispatch
    /// latency is perceptible. Safe for single-byte writes — the kernel write
    /// is atomic at that size.
    public func writeImmediate(_ data: Data) {
        // Skip once terminate() has set us stopped: after markStopped the
        // read queue's tail is going to close masterFD, and a concurrent
        // Darwin.write from here would race into either a closed fd (harmless,
        // just EBADF) or — worse — a reused fd owned by something else.
        guard shouldKeepRunning() else { return }
        data.withUnsafeBytes { rawBuf in
            guard let base = rawBuf.baseAddress else { return }
            let n = Darwin.write(masterFD, base, rawBuf.count)
            #if DEBUG
            if n != rawBuf.count {
                NSLog("[Blackbird] writeImmediate FAILED: wanted %d, got %d, errno=%d fd=%d",
                      rawBuf.count, n, errno, masterFD)
            } else {
                NSLog("[Blackbird] writeImmediate OK: %d bytes to fd %d", n, masterFD)
            }
            #endif
        }
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
