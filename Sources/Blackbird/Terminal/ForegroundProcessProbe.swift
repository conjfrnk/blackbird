import Foundation
import Darwin
import os

/// Verdict from the foreground process-tree walk. Three states — `Bool` would
/// conflate "definitely local" with "couldn't tell" and the security gate's
/// posture differs sharply between them. Forced destructuring at the call site
/// keeps the fail-closed posture honest: callers must explicitly decide what to
/// do with `.unknown`, not silently trip into the `false` branch.
public enum ForegroundNamespace: Equatable {
    /// Walk completed and found no remote-shell binary in the tree.
    case local
    /// Walk found a binary in `ForegroundProcessProbe.remoteShellBinaryBasenames`
    /// — the user is SSH'd / inside `docker exec` / etc. The associated values
    /// let a future caller (titlebar "remote" indicator) avoid re-walking.
    case remote(basename: String, pid: pid_t)
    /// Walk could not complete: PTY not running, `tcgetpgrp ≤ 0`,
    /// `proc_listpids` failure, BFS cap hit. The OSC 7 gate treats this as
    /// remote (fail-closed).
    case unknown(reason: String)
}

/// Walks the foreground process tree to decide whether the terminal is showing
/// a LOCAL filesystem or a remote one (SSH / container). Lifted out of `PTY`
/// because classifying a process tree by BFS over `proc_listpids` is not a
/// PTY's job and needs no PTY instance — `PTY.classifyForegroundNamespace()`
/// resolves the foreground pgroup leader under its `masterFD` lock and hands
/// the root pid here. The OSC 7 ingest gate in `TerminalSession` trusts the
/// shell-reported cwd ONLY when the result is `.local`.
enum ForegroundProcessProbe {
    /// Shares `PTY`'s `os.Logger` subsystem/category so process-tree
    /// diagnostics keep landing under the same `pty` category they always have.
    private static let logger = Logger(subsystem: "dev.conjfrnk.blackbird",
                                       category: "pty")

    /// Basenames of binaries that, when present in the PTY's foreground
    /// process tree, mean "the user is looking at a different filesystem
    /// namespace than ours" — so the OSC 7 cwd they report is not a path on
    /// our local disk. Canonical SSH / container-entry wrappers (and their
    /// common aliases). False negatives (a wrapper we don't list fronting an
    /// actual remote shell) are the security risk we're guarding against, so
    /// when in doubt, add to the set.
    private static let remoteShellBinaryBasenames: Set<String> = [
        "ssh", "slogin", "mosh-client", "telnet",
        "docker", "podman", "nerdctl", "kubectl", "lima",
    ]

    #if DEBUG
    /// Test-only read-only view of the set. Lets a unit test pin the
    /// canonical wrappers without exposing a mutable knob to production.
    static var remoteShellBinaryBasenamesForTests: Set<String> {
        remoteShellBinaryBasenames
    }
    #endif

    /// Classify the process tree rooted at `rootPID` (the foreground pgroup
    /// leader). The OSC 7 ingest gate in `TerminalSession` trusts the
    /// shell-reported cwd ONLY when the result is `.local`; both `.remote` and
    /// `.unknown` cause the payload to be dropped. KNOWN_ISSUES.md "OSC 7 trust
    /// over SSH" / audit synthesis #4.
    ///
    /// Walks via BFS rooted at `rootPID`. Each node:
    ///   - basename(`proc_pidpath(pid)`) → check membership
    ///   - children = `proc_listpids(PROC_PPID_ONLY, pid, ...)`
    /// Bounded: a deep tree is capped at 256 nodes to keep this from becoming a
    /// slow path. OSC 7 fires at most once per shell `cd`, so total cost is a
    /// handful of syscalls per `cd` — well below the frame budget even on the
    /// main queue (the OSC event sink runs there). Audit synthesis #4.
    ///
    /// On any error the function returns `.unknown` rather than silently
    /// trusting the shell — opposite of `hasForegroundChild` /
    /// `foregroundWorkingDirectory` which fail-open because they're advisory UI
    /// features, not security gates. The public API still goes through the
    /// `masterFD`-locked `PTY.classifyForegroundNamespace()` so the fd
    /// lifecycle gate fires; this static is also the test entry point that
    /// pins the BFS without driving a real PTY.
    static func classify(rootPID: pid_t) -> ForegroundNamespace {
        // BFS through the process tree. `seen` guards against cycles —
        // shouldn't happen in a well-formed UNIX process graph, but a
        // bug in `proc_listpids` returning stale data could otherwise
        // loop us. Cap traversal at 256 nodes; on overflow we treat the
        // result as `.unknown` (fail-closed) rather than silently
        // returning `.local`.
        //
        // Audit fix-#01 (2026-05-11): probe rootPID with the strict
        // variants (didFail-out) BEFORE entering the BFS body. The
        // lenient executableBasename / childPIDs helpers used inside
        // the walk collapse syscall failure into nil / [] —
        // indistinguishable from "no match" / "no children", which is
        // correct semantics for DESCENDANT nodes (an ESRCH on a sibling
        // that exited mid-walk shouldn't break the whole classification)
        // but wrong for the ROOT, where syscall failure means we cannot
        // classify at all. The docstring at "On any error the function
        // returns `.unknown`" used to be aspirational: classify
        // would fall through to `return .local` when proc_pidpath /
        // proc_listpids failed at the root (e.g. TCC restricted target,
        // ESRCH race with foreground-process exit, sandbox profile
        // change). The OSC 7 trust gate then accepted a remote shell's
        // cwd as `.local`. Now the root probes return `.unknown` on
        // failure; the BFS walk continues to use the lenient helpers
        // for descendants where best-effort is the right posture.
        var rootBasenameFailed = false
        let rootBasename = Self.executableBasename(pid: rootPID, didFail: &rootBasenameFailed)
        if rootBasenameFailed {
            Self.logger.warning(
                "ForegroundProcessProbe.classify: proc_pidpath failed on rootPID \(rootPID, privacy: .public); returning .unknown (fail-closed)"
            )
            return .unknown(reason: "proc_pidpath failed on rootPID \(rootPID)")
        }
        // Match the root before any further syscalls — if root is itself
        // a remote-shell binary (e.g. a user whose foreground process IS
        // ssh, not its child), we want .remote not .local.
        if let basename = rootBasename, Self.remoteShellBinaryBasenames.contains(basename) {
            return .remote(basename: basename, pid: rootPID)
        }
        var rootChildrenFailed = false
        let rootChildren = Self.childPIDs(parent: rootPID, didFail: &rootChildrenFailed)
        if rootChildrenFailed {
            Self.logger.warning(
                "ForegroundProcessProbe.classify: proc_listpids failed on rootPID \(rootPID, privacy: .public); returning .unknown (fail-closed)"
            )
            return .unknown(reason: "proc_listpids failed on rootPID \(rootPID)")
        }

        var seen: Set<pid_t> = [rootPID]
        var queue: [pid_t] = []
        for child in rootChildren where !seen.contains(child) {
            seen.insert(child)
            queue.append(child)
        }
        var examined = 1  // we already examined rootPID via the strict probes above
        let cap = 256

        while let pid = queue.popLast() {
            examined += 1
            if examined > cap {
                Self.logger.warning("ForegroundProcessProbe.classify: BFS hit cap=\(cap, privacy: .public) at pid=\(pid, privacy: .public); returning .unknown (fail-closed)")
                return .unknown(reason: "BFS cap (\(cap)) exceeded")
            }
            // Lenient walk for descendants — nil-on-failure here is the
            // correct posture (sibling processes legitimately exit mid-BFS).
            if let basename = Self.executableBasename(pid: pid),
               Self.remoteShellBinaryBasenames.contains(basename) {
                return .remote(basename: basename, pid: pid)
            }
            for child in Self.childPIDs(parent: pid) where !seen.contains(child) {
                seen.insert(child)
                queue.append(child)
            }
        }
        return .local
    }

    /// `proc_pidpath` → last path component. Returns nil if the pid is
    /// gone or the syscall fails.
    ///
    /// Buffer is sized to `4 * MAXPATHLEN` per `<sys/proc_info.h>`'s
    /// `PROC_PIDPATHINFO_MAXSIZE` (that constant lives in an internal
    /// header not surfaced through `Darwin`, so we compute the same
    /// value inline). Apple uses 4× headroom because exec'd binaries
    /// can have long paths after symlink resolution.
    private static func executableBasename(pid: pid_t) -> String? {
        var ignored = false
        return executableBasename(pid: pid, didFail: &ignored)
    }

    /// Audit fix-#01: same as `executableBasename(pid:)` but reports
    /// whether the nil result came from a syscall failure (`didFail = true`)
    /// or a legitimate non-nil return that the caller never reads.
    /// The lenient caller (BFS descendant walk) ignores `didFail`; the
    /// strict caller (classify's root probe) treats
    /// `didFail == true` as fail-CLOSED `.unknown` per the docstring
    /// contract.
    ///
    /// `proc_pidpath` on Darwin returns the number of bytes written on
    /// success (positive). It returns 0 OR -1 on various failure modes —
    /// observed in practice: 0 for unallocated pids (kernel rejects
    /// without errno), -1 with errno ∈ {ESRCH, EPERM, EINVAL} for
    /// permission / sandbox / "no such proc" failures. For the strict-
    /// probe contract we collapse both into `didFail = true` because the
    /// caller has just obtained the pid from `tcgetpgrp(masterFD)` — the
    /// process existed when we asked for it, so any failure to introspect
    /// it now is a fail-CLOSED situation. A running Mach-O / script has
    /// a non-empty exec path; n == 0 for a known-live process means the
    /// kernel won't talk to us.
    private static func executableBasename(pid: pid_t, didFail: inout Bool) -> String? {
        let bufSize = 4 * Int(MAXPATHLEN)
        var buf = [CChar](repeating: 0, count: bufSize)
        let n = proc_pidpath(pid, &buf, UInt32(bufSize))
        if n <= 0 {
            didFail = true
            return nil
        }
        didFail = false
        let path = String(cString: buf)
        guard !path.isEmpty else { return nil }
        return (path as NSString).lastPathComponent
    }

    /// Children of `parent` via `proc_listpids(PROC_PPID_ONLY, ...)`.
    /// Two-call pattern: probe size first, then fill.
    ///
    /// TOCTOU note: between probe and fill, `parent` may gain new
    /// children. The fill call is bounded by the byte length we pass
    /// (`buf.count * stride`), so the kernel truncates rather than
    /// overflows — `prefix(cap)` clamps the resulting slice. Truncation
    /// causes us to miss new children, which is a fail-closed outcome
    /// at the BFS level (we don't see the new branch, but the BFS still
    /// completes; the caller's `.local` result for a fork-bombing
    /// process is suspect, but the gate caller treats `.local` as the
    /// "trusted" verdict only — a missed remote-binary descendant in a
    /// fork-bombing tree is the exact case where the gate's BFS cap
    /// also fires and forces `.unknown`.
    ///
    /// Returns an empty array on syscall failure (which is
    /// indistinguishable from "no children"). Callers reaching this
    /// path with a parent they expected to have children should treat
    /// the whole walk as suspect.
    private static func childPIDs(parent: pid_t) -> [pid_t] {
        var ignored = false
        return childPIDs(parent: parent, didFail: &ignored)
    }

    /// Audit fix-#01: same as `childPIDs(parent:)` but reports whether
    /// the empty-array result came from a syscall failure
    /// (`didFail = true`) or a legitimate "no children" outcome.
    ///
    /// `proc_listpids` returns negative values on syscall failure (ESRCH,
    /// EPERM, sandbox); 0 means "no children" (or empty result), which
    /// is not an error. Distinguishing them lets the root probe in
    /// classify fail-CLOSED on failure while the descendant
    /// walk continues to use the lenient empty-on-anything semantics
    /// (sibling-exit races during BFS are benign).
    private static func childPIDs(parent: pid_t, didFail: inout Bool) -> [pid_t] {
        let probe = proc_listpids(UInt32(PROC_PPID_ONLY), UInt32(parent), nil, 0)
        if probe < 0 {
            didFail = true
            return []
        }
        didFail = false
        guard probe > 0 else { return [] }
        let cap = Int(probe) / MemoryLayout<pid_t>.stride
        guard cap > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: cap)
        let written = pids.withUnsafeMutableBufferPointer { buf -> Int32 in
            proc_listpids(UInt32(PROC_PPID_ONLY), UInt32(parent), buf.baseAddress, Int32(buf.count * MemoryLayout<pid_t>.stride))
        }
        if written < 0 {
            didFail = true
            return []
        }
        guard written > 0 else { return [] }
        // Clamp to the buffer we allocated; the syscall is byte-bounded
        // by the size we passed, so `count` cannot exceed `cap` in
        // practice — but `prefix(cap)` makes that invariant local.
        let count = min(Int(written) / MemoryLayout<pid_t>.stride, cap)
        return Array(pids.prefix(count)).filter { $0 > 0 }
    }
}
