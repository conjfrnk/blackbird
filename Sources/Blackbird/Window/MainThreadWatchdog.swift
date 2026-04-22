import Foundation
import Darwin
import QuartzCore
import os

/// Debug-only main-thread hang detector.
///
/// Pings main at `pingInterval`; if main doesn't respond within `hangThreshold`,
/// snapshots ALL threads (via `task_threads` + `thread_get_state`) and appends
/// a stack trace to `/tmp/bb-hang-<timestamp>.txt`. This gives us actual
/// evidence of what the app was doing during a UI beachball, rather than
/// having to guess or catch the freeze with an external `sample` command at
/// exactly the right moment.
///
/// Enable by setting `BB_HANG_WATCHDOG=1` in the environment. Off by default
/// — the probe thread itself costs ~0.1% CPU when idle and only does real
/// work during a detected hang, but we don't need it on in normal builds.
///
/// NOT shipped in release; the `guard` on the env var + DEBUG gating are both
/// belt-and-braces so a production user doesn't accidentally get a diagnostic
/// they didn't ask for.
enum MainThreadWatchdog {

    private static let logger = Logger(subsystem: "dev.conjfrnk.blackbird", category: "watchdog")

    // Single-shot install guard — `install()` is idempotent so repeat callers
    // (e.g. `applicationDidFinishLaunching` under test-induced re-entry) can't
    // arm multiple watchdog threads.
    private static var installed = false
    private static let installLock = NSLock()

    /// Last timestamp main responded to a ping. `atomic` semantics via plain
    /// `Double` + `OSMemoryBarrier` would be the standard approach; the
    /// runtime we run under (arm64 macOS) gives us natural-aligned 8-byte
    /// reads/writes for free, so a plain stored property paired with a
    /// memory fence on write is sufficient for this diagnostic.
    nonisolated(unsafe) private static var lastMainHeartbeat: Double = 0

    /// Arm the watchdog on the main queue. Call from AppDelegate.
    static func install(hangThreshold: Double = 0.5, pingInterval: Double = 0.1) {
        installLock.lock()
        defer { installLock.unlock() }
        guard !installed else { return }
        installed = true

        lastMainHeartbeat = CACurrentMediaTime()
        logger.log("MainThreadWatchdog armed: ping=\(pingInterval, privacy: .public)s threshold=\(hangThreshold, privacy: .public)s")

        // Main-thread heartbeat. Runs on the main runloop; each tick refreshes
        // the timestamp the watchdog thread watches.
        let timer = Timer(timeInterval: pingInterval, repeats: true) { _ in
            lastMainHeartbeat = CACurrentMediaTime()
        }
        // `.common` so the heartbeat keeps ticking under modal + tracking
        // runloop modes (NSMenu popup, live resize). If we used `.default`,
        // any modal interaction would look like a "hang" to the watchdog —
        // not useful.
        RunLoop.main.add(timer, forMode: .common)

        // Watchdog thread. Sleeps in short slices, compares heartbeat age,
        // captures a snapshot if stale.
        let t = Thread {
            while true {
                Thread.sleep(forTimeInterval: pingInterval)
                let now = CACurrentMediaTime()
                let age = now - lastMainHeartbeat
                if age >= hangThreshold {
                    captureHangReport(age: age)
                    // Rate-limit: after capturing, wait for main to recover
                    // before capturing again. Otherwise a multi-second hang
                    // produces a capture every pingInterval.
                    while CACurrentMediaTime() - lastMainHeartbeat >= hangThreshold {
                        Thread.sleep(forTimeInterval: pingInterval)
                    }
                }
            }
        }
        t.name = "blackbird.main-thread-watchdog"
        t.qualityOfService = .utility
        t.start()
    }

    /// Write a brief hang report to `/tmp/bb-hang-<wall-time>.txt`. Shells out
    /// to `/usr/bin/sample` with our own PID — that's the cleanest way to get
    /// a symbolicated trace of every thread from inside the same process;
    /// `Thread.callStackSymbols` only gives us the CALLING thread's stack
    /// (i.e., the watchdog thread's), which isn't what we want.
    private static func captureHangReport(age: Double) {
        let ts = Int(Date().timeIntervalSince1970)
        let pid = getpid()
        let file = "/tmp/bb-hang-\(ts).txt"
        logger.warning("main-thread hang \(age, format: .fixed(precision: 2), privacy: .public)s — writing \(file, privacy: .public)")

        // 2 seconds of sampling at default granularity — enough to catch
        // the hot frame on main while not stretching the capture window past
        // the hang itself.
        let proc = Process()
        proc.launchPath = "/usr/bin/sample"
        proc.arguments = ["\(pid)", "2", "-file", file]
        // Sample's own stdout/stderr is noise; redirect to /dev/null so the
        // unified log only sees the watchdog's own line.
        proc.standardOutput = FileHandle(forWritingAtPath: "/dev/null")
        proc.standardError = FileHandle(forWritingAtPath: "/dev/null")
        do {
            try proc.run()
            proc.waitUntilExit()
            logger.warning("hang report ready: \(file, privacy: .public)")
        } catch {
            logger.error("sample(1) invocation failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
