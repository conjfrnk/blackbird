import Foundation
import os

/// OSC 7 cwd ingest + SSH-trust classification for `TerminalSession`.
///
/// Pure extraction from `TerminalSession` (REFACTOR.md Part IV — the "OSC7
/// trust as collaborator" peel): the fail-closed namespace gate (Part I §18)
/// and the L3 one-shot drop-log latch moved out of the god-object **without
/// changing the queue confinement or the trust semantics by a single byte.**
///
/// ## Why the `@Published` store stays on the session
/// `session.lastKnownCwd` remains `@Published` on the `TerminalSession`
/// `ObservableObject` (the tracker drives it through the `unowned session`,
/// exactly as `SnapshotCoalescer` drives `@Published snapshot` via
/// `session.publish(_:)` and `PromptNavigator` drives `promptMarks`). Moving it
/// onto a plain collaborator would drop the `objectWillChange` /
/// projected-publisher surface (`SessionLifecycle` / `CwdTests` subscribe to
/// `$lastKnownCwd`) — a behavior change. This tracker owns the *latch* and the
/// *trust logic*; the observable store stays where the UI already reads it.
///
/// ## Queue confinement
/// `handleCwdChanged(_:)` is called from the session's event router
/// (`handleCoreEventOnMain`) on the **main thread**, exactly as the inline
/// `.cwdChanged` case ran before. `loggedUnknownNamespaceDrop` and the
/// `session.lastKnownCwd` write are therefore main-confined — the same
/// confinement the doc comments on the original fields asserted. No lock.
///
/// ## Lifetime
/// `handleCwdChanged` is synchronous and called only while the session is
/// provably alive (from the main-hop event switch), so it reads the
/// `unowned session` directly — mirroring the synchronous methods on
/// `PromptNavigator` / `PaletteApplier`. There are no deferred blocks here.
final class CwdTracker {

    /// The owning session. `unowned` because the session strongly owns this
    /// tracker for its whole lifetime; the only method is synchronous and runs
    /// while the session is alive, so it reads this directly (no deferred block
    /// that could outlive teardown).
    private unowned let session: TerminalSession

    /// One-shot latch for the OSC 7 `.unknown` drop log (L3). Per session — a
    /// hot-reconfigure that flips classification back to `.local` and then back
    /// to `.unknown` would otherwise miss the breadcrumb on the second
    /// `.unknown`. We accept that miss; the alternative (no latch at all) floods
    /// the log on every shell `cd`. Re-armed on each `.local` transition so a
    /// real-world ssh-disconnect → reconnect → disconnect logs each loss.
    /// Main-confined. Internal (not private) so the session's
    /// `_testLoggedUnknownNamespaceDrop` forwarder can read/reset it for the L3
    /// regression test.
    var loggedUnknownNamespaceDrop = false

    init(session: TerminalSession) {
        self.session = session
    }

    /// Apply an OSC 7 cwd change reported by the shell. Called on the **main
    /// thread** from `TerminalSession.handleCoreEventOnMain`.
    ///
    /// Rust core already gates on scheme=file and validates UTF-8; `path` is a
    /// ready-to-use filesystem path. Storing on the main thread keeps reads from
    /// ⌘T / ⌘N trivially race-free (those actions also run on main).
    ///
    /// SSH-trust gate (audit synthesis #4 / KNOWN_ISSUES "OSC 7 trust over
    /// SSH"): trust the shell-reported cwd ONLY when the foreground process tree
    /// classifies as `.local`. A `.remote` (ssh, mosh-client, docker exec,
    /// kubectl exec, …) means the path describes the remote fs; `.unknown` means
    /// we failed to classify (PTY closing, syscall error, BFS cap hit). Both
    /// cases drop the OSC 7 payload — fail-closed posture, opposite of the
    /// advisory `hasForegroundChild` / `foregroundWorkingDirectory` helpers.
    ///
    /// Cost: one syscall to read fg pgroup + at most ~256 node BFS (capped).
    /// Per `cd` only; well under the frame budget on main.
    func handleCwdChanged(_ path: String) {
        let classification = session.classifyForegroundNamespace()
        switch classification {
        case .local:
            session.lastKnownCwd = path
            // Re-arm the L3 latch on each .local transition so a subsequent
            // .local → .unknown cycle logs again. Without this, a real-world
            // ssh-disconnect-then-reconnect-then-disconnect-again leaves only
            // the first breadcrumb and support engineers see no log for the
            // second loss.
            loggedUnknownNamespaceDrop = false
        case .remote:
            break
        case .unknown(let reason):
            // Audit L3: dropping OSC 7 silently on every emit would leave a
            // support engineer with no breadcrumb when ⌘T inheritance "isn't
            // picking up the cwd". Surface the reason once per .local→.unknown
            // transition so unified-log readers see why without flooding on
            // every cd.
            if !loggedUnknownNamespaceDrop {
                loggedUnknownNamespaceDrop = true
                TerminalSession.sessionLogger.notice(
                    "OSC 7 dropped: foreground namespace classified .unknown (\(reason, privacy: .public)); ⌘T cwd inheritance disabled until classification recovers"
                )
            }
        }
    }
}
