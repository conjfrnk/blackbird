import Foundation
import Darwin
import QuartzCore
import os

/// Main-thread hang detector.
///
/// Pings main at `pingInterval`; if main doesn't respond within
/// `hangThreshold`, shells out to `/usr/bin/sample` with our own pid and
/// writes a symbolicated stack trace to
/// `~/Library/Logs/Blackbird/hang-<timestamp>.txt`. This gives us
/// actual evidence of what the app was doing during a UI beachball
/// rather than having to guess or catch the freeze with an external
/// `sample` run at exactly the right moment.
///
/// Default-on in Debug (set `BB_HANG_WATCHDOG=0` to suppress), off in
/// Release unless `BB_HANG_WATCHDOG=1` is set explicitly by someone
/// trying to repro a beachball. The probe thread costs ~0.1 % CPU when
/// idle; real work only happens on a detected hang. Production users
/// should not accumulate diagnostics they didn't ask for.
enum MainThreadWatchdog {

    private static let logger = Logger(subsystem: "dev.conjfrnk.blackbird", category: "watchdog")

    // Single-shot install guard — `install()` is idempotent so repeat callers
    // (e.g. `applicationDidFinishLaunching` under test-induced re-entry) can't
    // arm multiple watchdog threads.
    private static var installed = false
    private static let installLock = NSLock()

    /// Minimum hang threshold (50 ms). `install(hangThreshold:)` clamps any
    /// value below this floor up to the floor, so a bad caller can't arm a
    /// watchdog that fires on every runloop tick. Sub-50 ms hangs aren't
    /// actionable — sample(1) itself takes ~200 ms.
    static let minHangThreshold: Double = 0.05

    /// Minimum ping interval (10 ms). `install(pingInterval:)` clamps any
    /// value below this floor up to the floor, so
    /// `Thread.sleep(forTimeInterval: 0)` (which returns immediately on
    /// Darwin) can't put the watchdog thread into a tight busy-wait that
    /// pegs an efficiency core. Likewise prevents the main-thread Timer
    /// from being scheduled with `timeInterval: 0` (fires every runloop
    /// service iteration). Audit M-22.
    static let minPingInterval: Double = 0.01

    /// Last timestamp main responded to a ping. Written by the main-runloop
    /// timer (audit M-2 fixed: previously `nonisolated(unsafe) var Double`,
    /// read by the watchdog thread without synchronization). The lock
    /// matches the M-8 fix shape (`OSAllocatedUnfairLock<Bool>` for
    /// AtomicFlag.value); both are heap-resident, low-contention, and
    /// known memory-model-safe under TSan.
    private static let lastMainHeartbeat = OSAllocatedUnfairLock<Double>(initialState: 0)

    /// Last-installed ping interval after clamping. Exposed for tests so the
    /// M-22 clamp can be observed without touching the private internal
    /// timer/thread state. nil until first install.
    static var installedPingInterval: Double? {
        installLock.lock()
        defer { installLock.unlock() }
        return _installedPingInterval
    }

    /// Last-installed hang threshold after clamping. Exposed for tests.
    static var installedHangThreshold: Double? {
        installLock.lock()
        defer { installLock.unlock() }
        return _installedHangThreshold
    }

    private static var _installedPingInterval: Double?
    private static var _installedHangThreshold: Double?

    /// Pure-function clamp helper — extracted from `install(...)` so the
    /// M-22 clamp invariant is testable independently of the install
    /// idempotency latch. Tests assert `_clamp` directly: a clamp-revert
    /// regression flips this function's output even when the watchdog has
    /// already been installed by a prior test in the same xctest process.
    ///
    /// NaN never reaches `max` — `isFinite` short-circuits to the floor;
    /// this matters because Swift's `max(_:_:)` with NaN is argument-order-
    /// dependent and unsafe to rely on (`max(0.05, .nan)` returns 0.05 but
    /// `max(.nan, 0.05)` returns NaN).
    internal static func _clamp(hangThreshold: Double, pingInterval: Double) -> (hangThreshold: Double, pingInterval: Double) {
        let safeThreshold = hangThreshold.isFinite ? max(minHangThreshold, hangThreshold) : minHangThreshold
        let safePing = pingInterval.isFinite ? max(minPingInterval, pingInterval) : minPingInterval
        return (safeThreshold, safePing)
    }

    /// Arm the watchdog on the main queue. Call from AppDelegate.
    ///
    /// Both parameters are clamped to safety floors (`minHangThreshold`,
    /// `minPingInterval`). Passing 0 or negative values does NOT arm a
    /// tight-spinning thread — it arms a watchdog at the floor. Audit M-22.
    static func install(hangThreshold: Double = 0.5, pingInterval: Double = 0.1) {
        // Clamp before grabbing the lock so the values we record under the
        // lock are the safe ones.
        let (safeThreshold, safePing) = _clamp(hangThreshold: hangThreshold, pingInterval: pingInterval)

        // Per audit M-22 / SFH-005 / M-4 / M-5: when the clamp changes a
        // caller's input, log a warning so the substitution isn't silent.
        // `safeThreshold != hangThreshold` is true for NaN (NaN != anything),
        // so the NaN path also logs; the explicit `!isFinite` guard is for
        // clarity.
        if safeThreshold != hangThreshold || !hangThreshold.isFinite {
            logger.warning("hangThreshold \(hangThreshold, privacy: .public)s clamped to floor \(safeThreshold, privacy: .public)s — caller passed unsafe value (audit M-22)")
        }
        if safePing != pingInterval || !pingInterval.isFinite {
            logger.warning("pingInterval \(pingInterval, privacy: .public)s clamped to floor \(safePing, privacy: .public)s — caller passed unsafe value (audit M-22)")
        }

        installLock.lock()
        defer { installLock.unlock() }
        guard !installed else { return }
        installed = true
        _installedPingInterval = safePing
        _installedHangThreshold = safeThreshold

        lastMainHeartbeat.withLock { $0 = CACurrentMediaTime() }
        logger.log("MainThreadWatchdog armed: ping=\(safePing, privacy: .public)s threshold=\(safeThreshold, privacy: .public)s (requested ping=\(pingInterval, privacy: .public)s threshold=\(hangThreshold, privacy: .public)s)")

        // Main-thread heartbeat. Runs on the main runloop; each tick refreshes
        // the timestamp the watchdog thread watches.
        let timer = Timer(timeInterval: safePing, repeats: true) { _ in
            lastMainHeartbeat.withLock { $0 = CACurrentMediaTime() }
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
                Thread.sleep(forTimeInterval: safePing)
                let now = CACurrentMediaTime()
                let age = now - lastMainHeartbeat.withLock { $0 }
                if age >= safeThreshold {
                    captureHangReport(age: age)
                    // Rate-limit: after capturing, wait for main to recover
                    // before capturing again. Otherwise a multi-second hang
                    // produces a capture every pingInterval.
                    while CACurrentMediaTime() - lastMainHeartbeat.withLock({ $0 }) >= safeThreshold {
                        Thread.sleep(forTimeInterval: safePing)
                    }
                }
            }
        }
        t.name = "blackbird.main-thread-watchdog"
        t.qualityOfService = .utility
        t.start()
    }

    /// Write a brief hang report to `~/Library/Logs/Blackbird/hang-<wall-time>.txt`.
    /// Shells out to `/usr/bin/sample` with our own PID — that's the
    /// cleanest way to get a symbolicated trace of every thread from
    /// inside the same process; `Thread.callStackSymbols` only gives us
    /// the CALLING thread's stack (i.e., the watchdog thread's), which
    /// isn't what we want.
    ///
    /// `~/Library/Logs/Blackbird/` over `/tmp`: matches Apple's
    /// convention (Console.app reads this location automatically),
    /// survives reboots so post-hoc investigation works, and doesn't
    /// race with `/tmp` cleaners on very long sessions.
    private static func captureHangReport(age: Double) {
        // Audit fix-#21 (2026-05-11): the previous filename used 1-second
        // granularity (`Int(timeIntervalSince1970)`). Two hangs that recover
        // and re-stall within the same wall-clock second produce identical
        // paths; sample(1) -file opens with truncate semantics, silently
        // clobbering the first trace. Append a per-process UUID component
        // so each capture is unique even on collision and the first trace
        // survives to disk for post-hoc investigation.
        let now = Date().timeIntervalSince1970
        let tsMs = Int64(now * 1000.0)
        let unique = String(UUID().uuidString.prefix(8))
        let pid = getpid()
        let dir = logDirectory()
        let file = "\(dir)/hang-\(tsMs)-\(pid)-\(unique).txt"
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

    /// Return (and create on demand) `~/Library/Logs/Blackbird/`. Falls
    /// back to `/tmp` only if the real directory can't be created — a
    /// hang report in `/tmp` is still better than dropping the sample
    /// on the floor.
    private static func logDirectory() -> String {
        let fm = FileManager.default
        if let lib = fm.urls(for: .libraryDirectory, in: .userDomainMask).first {
            let dir = lib.appendingPathComponent("Logs/Blackbird", isDirectory: true)
            do {
                try fm.createDirectory(at: dir, withIntermediateDirectories: true)
                return dir.path
            } catch {
                logger.error("could not create \(dir.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
        return "/tmp"
    }
}
