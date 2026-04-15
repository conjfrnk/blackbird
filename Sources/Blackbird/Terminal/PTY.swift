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
        case pathTooLong
        case execFailed(errno: Int32)
    }

    /// Invoked with raw output bytes from the child. Called on the read queue.
    public var onBytes: ((Data) -> Void)?

    private let masterFD: Int32
    private let childPID: pid_t
    private let readQueue = DispatchQueue(label: "blackbird.pty.read", qos: .userInitiated)
    private let writeQueue = DispatchQueue(label: "blackbird.pty.write", qos: .userInitiated)
    private var isRunning = true
    private let readBufferSize = 16 * 1024

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
            // Child: set env, then exec.
            for (k, v) in envOverrides {
                setenv(k, v, 1)
            }
            setenv("TERM", "xterm-256color", 1)
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
            while self.isRunning {
                let n = buffer.withUnsafeMutableBufferPointer { buf -> Int in
                    read(self.masterFD, buf.baseAddress, buf.count)
                }
                if n <= 0 {
                    // EOF or error.
                    self.isRunning = false
                    break
                }
                let data = Data(buffer[0..<n])
                self.onBytes?(data)
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
        guard isRunning else { return }
        isRunning = false
        // Close master fd; the child sees SIGHUP and exits.
        close(masterFD)
        // Reap the child so we don't leave a zombie.
        var status: Int32 = 0
        _ = waitpid(childPID, &status, WNOHANG)
    }
}
