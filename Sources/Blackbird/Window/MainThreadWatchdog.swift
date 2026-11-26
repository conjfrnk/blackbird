import Foundation
import Darwin
import QuartzCore
import os

/// Main-thread hang detector: when main misses pings for `hangThreshold`, captures a `sample` trace.
enum MainThreadWatchdog {

    private static let logger = Logger(subsystem: "dev.conjfrnk.blackbird", category: "watchdog")

    private static var installed = false
    private static let installLock = NSLock()

    static let minHangThreshold: Double = 0.05

    /// `Thread.sleep(forTimeInterval: 0)` returns immediately on Darwin; the floor prevents a busy-wait.
    static let minPingInterval: Double = 0.01

    /// Written by the main-runloop timer, read by the watchdog thread.
    private static let lastMainHeartbeat = OSAllocatedUnfairLock<Double>(initialState: 0)

    static var installedPingInterval: Double? {
        installLock.lock()
        defer { installLock.unlock() }
        return _installedPingInterval
    }

    static var installedHangThreshold: Double? {
        installLock.lock()
        defer { installLock.unlock() }
        return _installedHangThreshold
    }

    private static var _installedPingInterval: Double?
    private static var _installedHangThreshold: Double?

    #if DEBUG
    private static var stopCurrent: OSAllocatedUnfairLock<Bool>?

    /// Once this returns no capture can start, so `HangReportStore.logDirectoryOverride` may be
    /// un-set afterwards. A capture already in flight is not waited for.
    internal static func _disarmForTesting() {
        installLock.lock()
        let stop = stopCurrent
        stopCurrent = nil
        installed = false
        _installedPingInterval = nil
        _installedHangThreshold = nil
        installLock.unlock()
        stop?.withLock { (stopped: inout Bool) -> Void in stopped = true }
    }
    #endif

    /// `isFinite` is checked first: `max(_:_:)` with NaN is argument-order dependent
    /// (`max(.nan, 0.05)` returns NaN).
    internal static func _clamp(hangThreshold: Double, pingInterval: Double) -> (hangThreshold: Double, pingInterval: Double) {
        let safeThreshold = hangThreshold.isFinite ? max(minHangThreshold, hangThreshold) : minHangThreshold
        let safePing = pingInterval.isFinite ? max(minPingInterval, pingInterval) : minPingInterval
        return (safeThreshold, safePing)
    }

    static func install(hangThreshold: Double = 0.5, pingInterval: Double = 0.1) {
        let (safeThreshold, safePing) = _clamp(hangThreshold: hangThreshold, pingInterval: pingInterval)

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

        let stopRequested = OSAllocatedUnfairLock<Bool>(initialState: false)
        #if DEBUG
        stopCurrent = stopRequested
        #endif

        let timer = Timer(timeInterval: safePing, repeats: true) { (fired: Timer) -> Void in
            // `invalidate` must be sent from the thread the timer was scheduled on.
            if stopRequested.withLock({ $0 }) {
                fired.invalidate()
                return
            }
            lastMainHeartbeat.withLock { $0 = CACurrentMediaTime() }
        }
        // `.common` so modal and tracking runloop modes (NSMenu popup, live resize) do not read as hangs.
        RunLoop.main.add(timer, forMode: .common)

        let t = Thread {
            while true {
                Thread.sleep(forTimeInterval: safePing)
                // Before the age check: a disarmed watchdog's heartbeat stops, which must not read as a hang.
                if stopRequested.withLock({ $0 }) { return }
                let now = CACurrentMediaTime()
                let age = now - lastMainHeartbeat.withLock { $0 }
                if age >= safeThreshold {
                    // The stop check and the directory resolution are one critical section:
                    // `_disarmForTesting` raises the flag under the same lock.
                    let directory: String? = stopRequested.withLock { (stopped: inout Bool) -> String? in
                        stopped ? nil : HangReportStore.logDirectory()
                    }
                    guard let directory else { return }
                    HangReportStore.captureHangReport(age: age, directory: directory)
                    // Wait for main to recover before capturing again.
                    while !stopRequested.withLock({ $0 }),
                          CACurrentMediaTime() - lastMainHeartbeat.withLock({ $0 }) >= safeThreshold {
                        Thread.sleep(forTimeInterval: safePing)
                    }
                }
            }
        }
        t.name = "blackbird.main-thread-watchdog"
        t.qualityOfService = .utility
        t.start()
    }

}
