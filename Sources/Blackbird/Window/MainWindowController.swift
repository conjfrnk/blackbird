import AppKit

final class MainWindowController: NSWindowController, NSWindowDelegate {

    private(set) var session: TerminalSession?
    private(set) var terminalView: TerminalView?

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

        let view = TerminalView(frame: rect)
        view.autoresizingMask = [.width, .height]
        window.contentView = view
        terminalView = view

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
