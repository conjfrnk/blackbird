import AppKit
import Combine
import Metal

final class MainWindowController: NSWindowController, NSWindowDelegate {

    private(set) var session: TerminalSession?
    private(set) var terminalView: TerminalView?
    private var exitCancellable: AnyCancellable?

    init() {
        let style: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .resizable]
        let rect = NSRect(x: 0, y: 0, width: 800, height: 480)
        let window = NSWindow(
            contentRect: rect,
            styleMask: style,
            backing: .buffered,
            defer: false
        )
        window.title = "Blackbird"
        window.isReleasedWhenClosed = false
        window.center()
        window.setFrameAutosaveName("BlackbirdMainWindow")
        super.init(window: window)
        window.delegate = self

        guard let device = MTLCreateSystemDefaultDevice() else {
            window.title = "Blackbird — no Metal device available"
            return
        }
        let view = TerminalView(frame: rect, device: device)
        view.autoresizingMask = [.width, .height]
        window.contentView = view
        terminalView = view

        // Prevent the user from shrinking the window below a usable minimum.
        // 20 cols × 4 rows is plenty for interactive use; stops layout
        // degenerating into a single column where the shell becomes unusable.
        let m = view.metrics
        window.contentMinSize = NSSize(
            width: m.cellWidth * 20,
            height: m.cellHeight * 4
        )
        // Snap window size to whole-cell increments during drag. Eliminates
        // the transient blank-edge/clip effect you'd otherwise see while the
        // shell catches up with SIGWINCH after a sub-cell pointer movement.
        // Same approach Terminal.app and iTerm use.
        window.contentResizeIncrements = NSSize(
            width: m.cellWidth,
            height: m.cellHeight
        )

        // Keyboard input routes to the TerminalView.
        window.makeFirstResponder(view)

        startSession(inView: view)
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    // MARK: - Session lifecycle

    private func startSession(inView view: TerminalView) {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let metrics = view.metrics
        let grid = metrics.grid(forPixelSize: view.bounds.size)
        do {
            let s = try TerminalSession.start(
                shell: shell,
                arguments: ["-il"],  // interactive login shell
                size: .init(cols: UInt16(grid.cols), rows: UInt16(grid.rows))
            )
            view.session = s
            self.session = s
            // Close the window when the shell exits (typed `exit`, SIGHUP, etc).
            // applicationShouldTerminateAfterLastWindowClosed then quits the app.
            exitCancellable = s.$exitCode
                .compactMap { $0 }
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in
                    self?.window?.performClose(nil)
                }
        } catch {
            window?.title = "Blackbird — failed to start shell: \(error)"
        }
    }

    func terminateSessions() {
        session?.terminate()
        session = nil
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        terminateSessions()
    }
}
