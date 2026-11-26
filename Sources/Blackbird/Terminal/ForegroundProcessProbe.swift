import Foundation
import Darwin
import os

public enum ForegroundNamespace: Equatable {
    case local
    case remote(basename: String, pid: pid_t)
    /// The walk could not complete; the OSC 7 gate treats this as remote (fail-closed).
    case unknown(reason: String)
}

enum ForegroundProcessProbe {
    private static let logger = Logger(subsystem: "dev.conjfrnk.blackbird",
                                       category: "pty")

    /// A false negative (an unlisted wrapper fronting a remote shell) is the security risk: when in doubt, add.
    private static let remoteShellBinaryBasenames: Set<String> = [
        "ssh", "slogin", "mosh-client", "telnet",
        "docker", "podman", "nerdctl", "kubectl", "lima",
    ]

    #if DEBUG
    static var remoteShellBinaryBasenamesForTests: Set<String> {
        remoteShellBinaryBasenames
    }
    #endif

    /// Fails closed: any error yields `.unknown`. Every descendant counts, background jobs included: a `&`
    /// job can still write to the tty (`tostop` is off by default).
    /// Walks one subtree; a job reparented to launchd (`ssh -f`, `(cmd &)`) is outside every walk.
    static func classify(rootPID: pid_t) -> ForegroundNamespace {
        // The root is probed with the strict (didFail) variants: a syscall failure there means the tree cannot
        // be classified, whereas a descendant that exits mid-walk is benign.
        var rootBasenameFailed = false
        let rootBasename = Self.executableBasename(pid: rootPID, didFail: &rootBasenameFailed)
        if rootBasenameFailed {
            Self.logger.warning(
                "ForegroundProcessProbe.classify: proc_pidpath failed on rootPID \(rootPID, privacy: .public); returning .unknown (fail-closed)"
            )
            return .unknown(reason: "proc_pidpath failed on rootPID \(rootPID)")
        }
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
        var examined = 1  // rootPID was examined above
        let cap = 256

        while let pid = queue.popLast() {
            examined += 1
            if examined > cap {
                Self.logger.warning("ForegroundProcessProbe.classify: BFS hit cap=\(cap, privacy: .public) at pid=\(pid, privacy: .public); returning .unknown (fail-closed)")
                return .unknown(reason: "BFS cap (\(cap)) exceeded")
            }
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

    static func classify(rootPIDs: [pid_t]) -> ForegroundNamespace {
        var seenRoots: Set<pid_t> = []
        var firstUnknown: ForegroundNamespace?
        for root in rootPIDs where seenRoots.insert(root).inserted {
            switch classify(rootPID: root) {
            case .remote(let basename, let pid):
                return .remote(basename: basename, pid: pid)
            case .unknown(let reason):
                if firstUnknown == nil { firstUnknown = .unknown(reason: reason) }
            case .local:
                break
            }
        }
        if let firstUnknown { return firstUnknown }
        return seenRoots.isEmpty ? .unknown(reason: "no root pids to classify") : .local
    }

    private static func executableBasename(pid: pid_t) -> String? {
        var ignored = false
        return executableBasename(pid: pid, didFail: &ignored)
    }

    /// `proc_pidpath` returns bytes written (> 0) on success and 0 or -1 on failure. The buffer is
    /// `PROC_PIDPATHINFO_MAXSIZE` (4 * MAXPATHLEN), which `Darwin` does not surface.
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

    private static func childPIDs(parent: pid_t) -> [pid_t] {
        var ignored = false
        return childPIDs(parent: parent, didFail: &ignored)
    }

    /// `proc_listpids` returns a negative value on failure and 0 for no children. Probe-then-fill: children
    /// gained between the two calls are truncated by the byte length passed, never overflowed.
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
        let count = min(Int(written) / MemoryLayout<pid_t>.stride, cap)
        return Array(pids.prefix(count)).filter { $0 > 0 }
    }
}
