import Foundation
import QuartzCore
import os

/// Input→pixel latency probe, off unless the process launched with `BB_LATENCY_PROBE=1`.
public final class LatencyProbe {
    public static let shared = LatencyProbe()

    private let log = os.Logger(subsystem: "dev.conjfrnk.blackbird", category: "latency")

    /// Zero means no keystroke pending. Guarded by `lock`: written on main, read and
    /// cleared on the MTKView draw thread.
    private var pendingKeystrokeAt: CFTimeInterval = 0

    private var samplesMs: [Double] = []
    private let lock = NSLock()

    private static let flushThreshold = 500

    private let envEnabled: Bool = {
        guard let cstr = getenv("BB_LATENCY_PROBE") else { return false }
        let raw = String(cString: cstr)
        return !raw.isEmpty && raw != "0"
    }()

    #if DEBUG
    private var forceEnabledForTests: Bool = false

    internal func _forceEnableForTests() { forceEnabledForTests = true }

    internal func _disableAfterTests() { forceEnabledForTests = false }
    #endif

    public var enabled: Bool {
        #if DEBUG
        return envEnabled || forceEnabledForTests
        #else
        return envEnabled
        #endif
    }

    init() {}

    public func markKeystroke() {
        guard enabled else { return }
        let now = CACurrentMediaTime()
        lock.lock()
        pendingKeystrokeAt = now
        lock.unlock()
    }

    public func markPresented() {
        guard enabled else { return }
        lock.lock()
        let pending = pendingKeystrokeAt
        pendingKeystrokeAt = 0
        lock.unlock()
        guard pending > 0 else { return }
        let dtMs = (CACurrentMediaTime() - pending) * 1000.0
        lock.lock()
        samplesMs.append(dtMs)
        let shouldFlush = samplesMs.count >= Self.flushThreshold
        lock.unlock()
        if shouldFlush { flush() }
    }

    private static func percentileIndex(count: Int, numerator: Int, denominator: Int) -> Int {
        min(count - 1, (count * numerator) / denominator)
    }

    public func flush() {
        lock.lock()
        guard !samplesMs.isEmpty else { lock.unlock(); return }
        let snapshot = samplesMs
        samplesMs.removeAll(keepingCapacity: true)
        lock.unlock()
        let sorted = snapshot.sorted()
        let p50Index = Self.percentileIndex(count: sorted.count, numerator: 50, denominator: 100)
        let p50 = sorted[p50Index]
        let p99Index = Self.percentileIndex(count: sorted.count, numerator: 99, denominator: 100)
        let p99 = sorted[p99Index]
        let p999Index = Self.percentileIndex(count: sorted.count, numerator: 999, denominator: 1000)
        let p999 = sorted[p999Index]
        let maxMs = sorted.last ?? p99
        // `.info` is not persisted to OSLogStore by default; `log` writes at `.default`, which is.
        log.log("latency n=\(snapshot.count, privacy: .public) p50=\(p50, format: .fixed(precision: 2), privacy: .public)ms p99=\(p99, format: .fixed(precision: 2), privacy: .public)ms p999=\(p999, format: .fixed(precision: 2), privacy: .public)ms max=\(maxMs, format: .fixed(precision: 2), privacy: .public)ms")
    }

    #if DEBUG
    internal func _injectSampleMs(_ ms: Double) {
        lock.lock()
        samplesMs.append(ms)
        lock.unlock()
    }

    internal var _sampleCountForTests: Int {
        lock.lock(); defer { lock.unlock() }
        return samplesMs.count
    }
    #endif
}
