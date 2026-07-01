import Foundation
import os

/// Single gate for the "⌘T → shell-spawn → first-byte → first-snapshot"
/// latency log. Off by default in Release — a shipping build shouldn't
/// write diagnostic chatter to the unified log on every new tab. Opt in
/// with `BLACKBIRD_STARTUP_LOG=1` when investigating a slow-prompt
/// report in the field.
///
/// Why a central gate (vs. sprinkling `#if DEBUG` at call sites):
///   - one source of truth for "is this on"; the four emit sites stay
///     identical regardless of build flavour.
///   - `isEnabled` is an immutable gate, not a mutable flag: tests run in
///     DEBUG (so it's on); Release behaviour is env-driven via
///     `BLACKBIRD_STARTUP_LOG`. Computed once, read identically everywhere.
///   - the `os.Logger` itself is reused, not re-created per call.
///
/// Readable via:
///   log stream --predicate 'subsystem == "dev.conjfrnk.blackbird" AND category == "startup"'
enum StartupTelemetry {
    /// Backing logger — shared across call sites so the `startup`
    /// category stays a single thread in the unified log.
    static let logger = Logger(
        subsystem: "dev.conjfrnk.blackbird",
        category: "startup"
    )

    /// Runtime gate. DEBUG builds: always on (developers want the
    /// latency signal). Release builds: opt-in via
    /// `BLACKBIRD_STARTUP_LOG=1`. Computed once at first access to keep
    /// per-call overhead near zero when disabled.
    static let isEnabled: Bool = {
        #if DEBUG
        return true
        #else
        return ProcessInfo.processInfo.environment["BLACKBIRD_STARTUP_LOG"] == "1"
        #endif
    }()
}
