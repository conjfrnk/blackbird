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

    /// Spawn a child process attached to a new PTY.
    public static func spawn(
        executable: String,
        arguments: [String],
        envOverrides: [String: String],
        size: Size
    ) throws -> PTY {
        var master: Int32 = -1
        var winsize = Darwin.winsize(
            ws_row: size.rows, ws_col: size.cols,
            ws_xpixel: 0, ws_ypixel: 0
        )
        // termios with common defaults.
        var termios = Darwin.termios()
        cfmakeraw(&termios)
        termios.c_lflag |= UInt(ECHO | ICANON | ISIG | IEXTEN)
        termios.c_iflag |= UInt(ICRNL | IXON | BRKINT)
        termios.c_oflag |= UInt(OPOST | ONLCR)

        let pid = withUnsafeMutablePointer(to: &master) { masterPtr in
            withUnsafeMutablePointer(to: &termios) { tPtr in
                withUnsafeMutablePointer(to: &winsize) { wPtr in
                    forkpty(masterPtr, nil, tPtr, wPtr)
                }
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
            setenv("TERM_PROGRAM_VERSION", "0.1.0", 1)
            // Apps launched from Finder inherit cwd = `/` from launchd. Move
            // into the user's home directory so the shell starts where users
            // expect. `getpwuid(getuid())` is authoritative; fall back to
            // $HOME if the passwd lookup fails for any reason.
            if let pw = getpwuid(getuid()), pw.pointee.pw_dir != nil {
                _ = chdir(pw.pointee.pw_dir)
            } else if let home = getenv("HOME") {
                _ = chdir(home)
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
        writeQueue.async { [masterFD] in
            data.withUnsafeBytes { rawBuf -> Void in
                guard let base = rawBuf.baseAddress else { return }
                var remaining = rawBuf.count
                var offset = 0
                while remaining > 0 {
                    let written = Darwin.write(masterFD, base.advanced(by: offset), remaining)
                    if written <= 0 { break }
                    remaining -= written
                    offset += written
                }
            }
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
