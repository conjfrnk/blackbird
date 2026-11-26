import AppKit
import Combine

/// Session creation and deferred teardown for a `MainWindowController`.
/// The controller owns this; no method here may run from the controller's `deinit`.
final class SessionLifecycle {
    unowned let controller: MainWindowController

    init(controller: MainWindowController) {
        self.controller = controller
    }

    private var cwdCancellable: AnyCancellable?

    var systemLocale: () -> Locale = { LocaleEnvironment.currentSystemLocale() }

    /// Uses the same `usableViewSize` formula as `TerminalView.propagateResize`, so the start
    /// size and the first SIGWINCH cannot disagree.
    func startGridSize(for view: TerminalView) -> (cols: UInt16, rows: UInt16) {
        let usable = TerminalView.usableViewSize(
            forBounds: view.bounds.size,
            titlebarTopInset: view.titlebarOnlyTopInset,
            metrics: view.metrics
        )
        let grid = view.metrics.grid(forPixelSize: usable)
        return (UInt16(clamping: grid.cols), UInt16(clamping: grid.rows))
    }

    func makeSession(shell: String, size: (cols: UInt16, rows: UInt16)) throws -> TerminalSession {
        #if DEBUG
        if let testFactory = MainWindowController.sessionFactoryForTests {
            return testFactory()
        }
        #endif
        let parentEnv = ProcessInfo.processInfo.environment
        var env = ShellIntegration.envOverrides(
            shellPath: shell,
            integrationDir: Bundle.main.resourcePath,
            materializedRoot: ShellIntegration.currentRoot(),
            parentEnv: parentEnv,
            enabled: Preferences.shared.automaticShellIntegration
        )
        // A Finder-launched app inherits no LANG. Never overrides a parent value.
        env.merge(
            LocaleEnvironment.overrides(
                enabled: Preferences.shared.setLocaleEnvironment,
                parentEnv: parentEnv,
                locale: systemLocale(),
                isAvailable: LocaleEnvironment.localeDefinitionExists
            ),
            uniquingKeysWith: { current, _ in current }
        )
        env.merge(
            ShellResolver.environmentOverrides(for: shell, loginShell: ShellResolver.loginShellFromPasswd()),
            uniquingKeysWith: { current, _ in current }
        )
        return try TerminalSession.start(
            shell: shell,
            arguments: ShellResolver.launchArguments(for: shell),
            size: .init(cols: size.cols, rows: size.rows),
            initialWorkingDirectory: controller.initialWorkingDirectory,
            envOverrides: env
        )
    }

    /// A nil or empty cwd leaves the title bar without a proxy icon.
    func bindSessionProxyIcon(_ s: TerminalSession) {
        cwdCancellable = s.$lastKnownCwd
            .receive(on: DispatchQueue.main)
            .sink { [weak self] path in
                guard let win = self?.controller.window else { return }
                if let path, !path.isEmpty {
                    win.representedURL = URL(fileURLWithPath: path, isDirectory: true)
                } else {
                    win.representedURL = nil
                }
            }
    }

    func presentShellStartFailureAlert(error: Error, inView view: TerminalView) {
        guard let window = controller.window else { return }
        let alert = NSAlert()
        alert.messageText = "Couldn't start shell"
        alert.informativeText = """
            Blackbird couldn't launch the shell:
            \(error.localizedDescription)

            Try again, or close this window.
            """
        alert.addButton(withTitle: "Retry")
        alert.addButton(withTitle: "Close Window")
        alert.alertStyle = .warning
        // A sheet keeps the runloop serviceable; a modal could trap the user if it races another close path.
        alert.beginSheetModal(for: window) { [weak self, weak view] response in
            guard let self, let view else { return }
            switch response {
            case .alertFirstButtonReturn:
                self.controller.startSession(inView: view)
            default:
                self.controller.window?.performClose(nil)
            }
        }
    }

    /// Closes the window once no modal or sheet is blocking it; `performClose` during a modal
    /// is queued or routed at the modal itself.
    func deferredAutoCloseIfNeeded() {
        // Guard on `isClosing`, not `isVisible`: `isVisible` is also false for a miniaturized window.
        guard let win = controller.window, !controller.isClosing else { return }
        let appHasModal = NSApp.modalWindow != nil
        if appHasModal || win.attachedSheet != nil {
            // `NSApp.modalWindow` is app-global, so another window's modal blocks this one;
            // poll at ~20 Hz because a bare `main.async` would spin a core for its lifetime.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                self?.deferredAutoCloseIfNeeded()
            }
            return
        }
        // Deminiaturize first, or the close leaves a dead Dock thumbnail.
        if win.isMiniaturized {
            win.deminiaturize(nil)
        }
        win.performClose(nil)
    }
}
