import Foundation

enum CwdResolver {
    static func forNewTab(source: TerminalSession?) -> String? {
        // Consult the PTY only while the session is live: after exit the closed `masterFD` integer may be reused.
        guard let src = source, src.exitCode == nil else {
            return source?.lastKnownCwd
        }
        // A foreground child (subshell, ssh, docker exec) may not forward OSC 7; its live cwd beats `lastKnownCwd`.
        if src.hasForegroundChild(), let fgCwd = src.foregroundWorkingDirectory() {
            return fgCwd
        }
        if !src.lastKnownCwdIsStale, let cwd = src.lastKnownCwd { return cwd }
        return src.foregroundWorkingDirectory()
            ?? src.shellWorkingDirectory()
            ?? src.lastKnownCwd
    }

    /// `nil` makes `PTY.spawn(initialWorkingDirectory:)` apply its `$HOME` / `getpwuid` fallback.
    static func forNewWindow() -> String? { nil }
}
