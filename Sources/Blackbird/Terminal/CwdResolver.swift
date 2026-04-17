import Foundation

/// Pure resolver for the directory a newly-spawned shell should start in.
/// Lifted out of `AppDelegate` so ⌘T / ⌘N / tests share exactly one source
/// of truth for cwd-inheritance policy — if the priority ever changes
/// (e.g. a third signal lands above OSC 7), production and tests move in
/// lockstep because both call the same function.
///
/// See spec §4.4 (⌘T inherits) and §3 (⌘N is always a fresh start).
enum CwdResolver {
    /// ⌘T / tab-group "+": inherit the active session's current working
    /// directory. Priority:
    ///   1. `lastKnownCwd` — shell-reported via OSC 7, authoritative and
    ///      cheap.
    ///   2. `foregroundWorkingDirectory()` — proc_pidinfo on the fg pgroup.
    ///      Catches shells that don't emit OSC 7 (default bash on macOS,
    ///      custom shells).
    ///   3. `nil` — handing `nil` to `PTY.spawn(initialWorkingDirectory:)`
    ///      triggers its built-in `$HOME` / `getpwuid` fallback; callers
    ///      shouldn't rewrite that policy here.
    ///
    /// `source` is nil only when the user invokes ⌘T with no active
    /// Blackbird window — the very first window in that case. Returning
    /// nil is correct: `PTY.spawn` then lands in `$HOME`.
    static func forNewTab(source: TerminalSession?) -> String? {
        source?.lastKnownCwd ?? source?.foregroundWorkingDirectory()
    }

    /// ⌘N: always a fresh start. Never inherits the active tab's cwd —
    /// that's the behavioural contrast with ⌘T. Returning `nil` lets
    /// `PTY.spawn` apply its `$HOME` fallback; duplicating the lookup
    /// here would risk drifting from whatever PTY does (getpwuid vs.
    /// $HOME env vs. /).
    static func forNewWindow() -> String? { nil }
}
