import Foundation
import os

/// kitty terminfo provisioning — lifted out of `PTY` because installing an
/// ncurses terminfo entry (shelling out to `/usr/bin/tic` + `/usr/bin/infocmp`)
/// is not a PTY's job and needs no PTY instance. `PTY.spawn` consults
/// `KittyTerminfo.available` to decide the child's `TERM`.
///
/// Whether `xterm-kitty` is reachable via ncurses terminfo lookup is computed
/// once per process: we try to install the bundled kitty terminfo to
/// `~/.terminfo` if needed, then probe `infocmp`. When `available` is true the
/// child gets `TERM=xterm-kitty` so kitty-aware TUIs (Claude Code, nvim,
/// tmux 3.3+) negotiate the keyboard protocol and Shift+Enter actually produces
/// `ESC[13;2u` instead of bare `\r`. When false we fall back to
/// `xterm-256color` — legacy but universally understood.
enum KittyTerminfo {
    /// Shares `PTY`'s `os.Logger` subsystem/category so terminfo diagnostics
    /// keep landing under the same `pty` category they always have.
    private static let logger = Logger(subsystem: "dev.conjfrnk.blackbird",
                                       category: "pty")

    /// Whether `xterm-kitty` is currently reachable via ncurses terminfo
    /// lookup. Computed once per process (Swift `static let` → `swift_once`).
    static let available: Bool = installIfNeeded()

    /// Install the bundled kitty terminfo to `~/.terminfo/x/xterm-kitty`.
    /// Runs *every* launch — an opportunistic `tic -x` overwrites the
    /// target, which is what we want: the bundled source is authoritative.
    /// If an attacker pre-planted a malicious `xterm-kitty` entry (with a
    /// hostile `reset=` capability that runs arbitrary bytes on shell
    /// `reset`/`clear`), the re-install wipes it. Prior behaviour only
    /// installed when `infocmp xterm-kitty` failed, which meant a planted
    /// entry survived because the probe succeeded against it.
    /// Returns true iff ncurses can resolve `xterm-kitty` afterwards —
    /// which is what the child really needs before we hand it
    /// `TERM=xterm-kitty`.
    private static func installIfNeeded() -> Bool {
        guard
            let src = Bundle.main.url(forResource: "kitty", withExtension: "terminfo"),
            FileManager.default.fileExists(atPath: src.path)
        else {
            return false
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        let dst = home.appendingPathComponent(".terminfo")
        // tic with -o writes <dst>/x/xterm-kitty. The directory is created
        // for us. Swallow stderr — this is opportunistic; any failure just
        // means we fall back to xterm-256color.
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/tic")
        task.arguments = ["-x", "-o", dst.path, src.path]
        task.standardOutput = Pipe()
        task.standardError = Pipe()
        let ticStatus: Int32
        do {
            try task.run()
            task.waitUntilExit()
            ticStatus = task.terminationStatus
        } catch {
            return false
        }
        return decideAvailability(
            ticExit: ticStatus,
            probe: { infocmpSucceeds(term: "xterm-kitty") }
        )
    }

    /// Kick the one-shot `available` resolution onto a background thread so the
    /// two synchronous child-process round-trips it performs (`/usr/bin/tic`
    /// then `/usr/bin/infocmp`, `installIfNeeded` above) don't block the FIRST
    /// `PTY.spawn` on the main thread — which sits squarely on the cold-launch
    /// critical path (`applicationDidFinishLaunching` →
    /// `MainWindowController.init` → `startSession` → `TerminalSession.start`
    /// → `PTY.spawn`), delaying the first window's appearance by however long
    /// `tic`+`infocmp` take (tens to >100 ms on a cold filesystem).
    ///
    /// Mechanism — and why this is strictly safe: `available` is a Swift
    /// `static let`, so its initializer runs **exactly once** under
    /// `swift_once` (dispatch_once semantics), on whichever thread touches it
    /// first. Forcing that touch here on a background queue means:
    ///   - race won  (warm-up finishes before the first spawn): `spawn`'s
    ///     read of `available` returns the memoized value with zero blocking.
    ///   - race lost (first spawn arrives mid-warm-up): `swift_once` blocks
    ///     the reader only for the REMAINING work — never re-runs `tic`,
    ///     never hands the child a downgraded `TERM`. Worst case is exactly
    ///     today's synchronous behaviour; there is no regression and no new
    ///     `tic` concurrency. The L1 security gate (`decideAvailability`) is
    ///     on the unchanged init path, so it still governs the result.
    ///
    /// Idempotent and cheap to call more than once (subsequent calls just
    /// re-read an already-resolved static). Call once, early, from
    /// `applicationDidFinishLaunching` on the normal (non-test) launch.
    static func prewarm() {
        DispatchQueue.global(qos: .userInitiated).async {
            _ = available
        }
    }

    /// Decision helper for L1: given a `tic` exit status and a callable
    /// `infocmp` probe, determine whether the child should be told
    /// `TERM=xterm-kitty`. Surfaced as a static so the audit's mock-the-
    /// Task test can drive it without running `tic`. The caller is
    /// responsible for actually running `tic` and providing the probe;
    /// this function only owns the policy.
    static func decideAvailability(
        ticExit: Int32,
        probe: () -> Bool
    ) -> Bool {
        // Audit L1: a non-zero `tic` exit means the install didn't land
        // (TCC denial, ENOSPC, malformed source). DON'T fall through to
        // the `infocmp` probe — a hostile pre-planted `xterm-kitty`
        // entry would otherwise let the probe succeed and we'd hand the
        // child `TERM=xterm-kitty` against an attacker-controlled
        // terminfo. Bail out and the caller falls back to xterm-256color.
        if ticExit != 0 {
            logger.error(
                "KittyTerminfo.installIfNeeded: tic exit=\(ticExit, privacy: .public) — falling back to xterm-256color (will not trust pre-existing terminfo)"
            )
            return false
        }
        return probe()
    }

    /// True when `infocmp <term>` exits 0 — i.e. ncurses can find the entry.
    /// Uses /usr/bin/infocmp directly so we don't depend on $PATH being
    /// sane at this point in app startup.
    private static func infocmpSucceeds(term: String) -> Bool {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/infocmp")
        task.arguments = [term]
        task.standardOutput = Pipe()
        task.standardError = Pipe()
        do {
            try task.run()
            task.waitUntilExit()
        } catch {
            return false
        }
        return task.terminationStatus == 0
    }
}
