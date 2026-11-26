import Foundation
import os

/// Gate for the new-tab startup latency log; Release opts in with `BLACKBIRD_STARTUP_LOG=1`.
enum StartupTelemetry {
    static let logger = Logger(
        subsystem: "dev.conjfrnk.blackbird",
        category: "startup"
    )

    static let isEnabled: Bool = {
        #if DEBUG
        return true
        #else
        return ProcessInfo.processInfo.environment["BLACKBIRD_STARTUP_LOG"] == "1"
        #endif
    }()
}
