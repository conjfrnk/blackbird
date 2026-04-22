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
    ///   1. `foregroundWorkingDirectory()` — proc_pidinfo on the fg pgroup —
    ///      but *only* when a foreground child exists (shell has launched a
    ///      subshell/ssh/docker-exec/etc.). The live fg-cwd is what the user
    ///      is visually working in; a stale OSC 7 would point at the outer
    ///      shell's cwd which isn't where "new tab here" belongs.
    ///      Audit cwd-hyperlink F4.
    ///   2. `lastKnownCwd` — shell-reported via OSC 7, authoritative and
    ///      cheap. Preferred at the shell prompt (no fg child) because it
    ///      requires no syscalls.
    ///   3. `foregroundWorkingDirectory()` fallback — catches shells that
    ///      don't emit OSC 7 (default bash on macOS, custom shells).
    ///   4. `nil` — handing `nil` to `PTY.spawn(initialWorkingDirectory:)`
    ///      triggers its built-in `$HOME` / `getpwuid` fallback (see
    ///      `PTY.spawn` in Sources/Blackbird/Terminal/PTY.swift — spec §3).
    ///      Callers shouldn't rewrite that policy here.
    ///
    /// `source` is nil only when the user invokes ⌘T with no active
    /// Blackbird window — the very first window in that case. Returning
    /// nil is correct: `PTY.spawn` then lands in `$HOME`.
    static func forNewTab(source: TerminalSession?) -> String? {
        // `foregroundWorkingDirectory()` dereferences `PTY.masterFD`. If the
        // session already exited, the fd has been closed and the OS may have
        // handed the same integer to an unrelated caller within this process
        // (low probability but real). `tcgetpgrp` on a reused fd would point
        // at a foreign pgroup's cwd. Gate on `exitCode == nil` so we only
        // consult the PTY while it's still live; otherwise return nil and
        // let `PTY.spawn` apply its `$HOME` fallback.
        guard let src = source, src.exitCode == nil else {
            return source?.lastKnownCwd
        }
        // A foreground child means the user has `cd`'d inside a subshell,
        // ssh'd, or docker-exec'd — those contexts don't always forward OSC
        // 7, so `lastKnownCwd` would be the *outer* shell's last-known cwd
        // (stale). `proc_pidinfo` on the fg pgroup reports that child's
        // live cwd, matching iTerm2's "prefer fg pgroup cwd when fg pgroup
        // ≠ shell" rule. Audit cwd-hyperlink F4.
        if src.hasForegroundChild(), let fgCwd = src.foregroundWorkingDirectory() {
            return fgCwd
        }
        if let cwd = src.lastKnownCwd { return cwd }
        return src.foregroundWorkingDirectory()
    }

    /// ⌘N: always a fresh start. Never inherits the active tab's cwd —
    /// that's the behavioural contrast with ⌘T. Returning `nil` lets
    /// `PTY.spawn(initialWorkingDirectory:)` apply its `$HOME` /
    /// `getpwuid` fallback (see `PTY.spawn` in
    /// Sources/Blackbird/Terminal/PTY.swift — spec §3). Duplicating the
    /// lookup here would risk drifting from whatever PTY does (getpwuid
    /// vs. $HOME env vs. /). Audit cwd-hyperlink F5.
    static func forNewWindow() -> String? { nil }
}
