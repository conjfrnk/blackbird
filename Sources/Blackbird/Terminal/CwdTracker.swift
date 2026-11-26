import Foundation
import os

final class CwdTracker {

    private unowned let session: TerminalSession

    var loggedUnknownNamespaceDrop = false

    init(session: TerminalSession) {
        self.session = session
    }

    /// Main thread only. Fail closed: trust OSC 7 only when the foreground process tree classifies `.local`
    /// (a `.remote` path describes the remote fs); a dropped report marks the cwd stale so ⌘T asks the kernel.
    func handleCwdChanged(_ path: String) {
        let classification = session.classifyForegroundNamespace()
        switch classification {
        case .local:
            session.lastKnownCwd = path
            session.lastKnownCwdIsStale = false
            loggedUnknownNamespaceDrop = false
        case .remote:
            session.lastKnownCwdIsStale = true
        case .unknown(let reason):
            session.lastKnownCwdIsStale = true
            if !loggedUnknownNamespaceDrop {
                loggedUnknownNamespaceDrop = true
                TerminalSession.sessionLogger.notice(
                    "OSC 7 dropped: foreground namespace classified .unknown (\(reason, privacy: .public)); report ignored, ⌘T reads the shell's live cwd until classification recovers"
                )
            }
        }
    }
}
