import Foundation
import Combine

/// Owns a PTY and a BBTerm. Wires PTY output into the VT parser, publishes
/// snapshots of the grid to observers.
///
/// Thread model:
/// - PTY output arrives on PTY's read queue; we dispatch into `coreQueue`.
/// - `coreQueue` is the single owner of `bbterm`.
/// - After feeding bytes, a new snapshot is taken and published on `main`.
/// - Input via `send(_:)` hops to PTY's write queue (PTY handles its own serialization).
public final class TerminalSession: ObservableObject {

    public typealias Size = PTY.Size

    @Published public private(set) var snapshot: BBSnapshot?
    @Published public private(set) var title: String?
    @Published public private(set) var bellCounter: UInt64 = 0
    /// Set once after the shell process has exited. The value is the child's
    /// exit code (-1 for abnormal termination). Observers (e.g. the window
    /// controller) close the window in response.
    @Published public private(set) var exitCode: Int32?

    private let bbterm: BBTerm
    private let pty: PTY
    private let coreQueue = DispatchQueue(label: "blackbird.core")

    public static func start(
        shell: String,
        arguments: [String],
        size: Size
    ) throws -> TerminalSession {
        guard let bb = BBTerm(size: .init(cols: size.cols, rows: size.rows)) else {
            throw SessionError.coreInitFailed
        }
        let pty = try PTY.spawn(
            executable: shell,
            arguments: arguments,
            envOverrides: [:],
            size: size
        )
        return TerminalSession(bbterm: bb, pty: pty)
    }

    public enum SessionError: Error {
        case coreInitFailed
    }

    private init(bbterm: BBTerm, pty: PTY) {
        self.bbterm = bbterm
        self.pty = pty
        wire()
    }

    deinit {
        terminate()
    }

    // MARK: - Public API

    public func send(_ data: Data) {
        pty.write(data)
    }

    public func resize(to size: Size) {
        // Serialize PTY + BBTerm resize on the core queue. Calling pty.resize
        // before bbterm.resize creates a window where bytes from a SIGWINCH-
        // reactive shell feed into bbterm at the old dimensions. The core
        // queue is already the single-writer for bbterm, so doing PTY resize
        // there too closes the window (PTY writes are serialized internally).
        coreQueue.async { [weak self, bbterm] in
            self?.pty.resize(to: size)
            bbterm.resize(to: .init(cols: size.cols, rows: size.rows))
            if let snap = bbterm.snapshot() {
                DispatchQueue.main.async {
                    self?.snapshot = snap
                }
            }
        }
    }

    public func terminate() {
        pty.terminate()
    }

    // MARK: - Wiring

    private func wire() {
        // Route PTY bytes -> core queue -> bbterm -> publish snapshot.
        pty.onBytes = { [weak self] data in
            guard let self else { return }
            self.coreQueue.async {
                self.feed(data)
            }
        }

        // When the child exits (natural or SIGHUP), publish the exit code.
        pty.onExit = { [weak self] code in
            self?.exitCode = code
        }

        // Route bbterm events (title/bell/fatal) to published properties.
        bbterm.onEvent { [weak self] event in
            guard let self else { return }
            DispatchQueue.main.async {
                switch event {
                case .title(let t):
                    self.title = t
                case .bell:
                    self.bellCounter &+= 1
                case .osc52Clipboard:
                    break  // Plan 6 wires this.
                case .cursorShape:
                    break  // Plan 5/3 will surface cursor shape.
                case .fatal(let msg):
                    // Surface as a title prefix for visibility; Plan 7 adds a
                    // dedicated diagnostics channel.
                    self.title = "[fatal] core panic: \(msg)"
                }
            }
        }

        // Take an initial snapshot so observers have something on screen.
        coreQueue.async { [weak self] in
            guard let self else { return }
            if let snap = self.bbterm.snapshot() {
                DispatchQueue.main.async {
                    self.snapshot = snap
                }
            }
        }
    }

    /// Called on `coreQueue`.
    private func feed(_ data: Data) {
        let bytes = [UInt8](data)
        bbterm.input(bytes)
        if let snap = bbterm.snapshot() {
            DispatchQueue.main.async { [weak self] in
                self?.snapshot = snap
            }
        }
    }
}
