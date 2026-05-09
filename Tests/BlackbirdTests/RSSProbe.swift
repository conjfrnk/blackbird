import Foundation
import Darwin.Mach

/// Shared resident-set-size probe for Blackbird soak tests.
///
/// Used by both the BBTerm Rust-FFI soak (`BBTermAdversarialTests`) and
/// the Swift retain-graph gate (`SwiftSessionRSSReturnsToBaselineTests`).
/// Both previously defined identical `task_info(MACH_TASK_BASIC_INFO)`
/// helpers at file scope; per Connor's DRY rule and the existing
/// shared-helper convention (`MemoryBudget.swift`,
/// `TestHostTermination.swift`), we centralise here.
///
/// CRITICAL: returns 0 on syscall failure rather than throwing. Callers
/// MUST guard with `XCTAssertGreaterThan(rss, 0, "...")` — otherwise a
/// Mach syscall failure (scheduler glitch, sandbox restriction, …) lets
/// the test pass silently with `delta = max(0, 0 - baseline) = 0`,
/// which is the failure mode the BBTerm soak's 4× headroom tolerates
/// but the Swift RSS-returns-to-baseline gate must NOT tolerate (the
/// whole point is detecting a leak — a 0-RSS reading masks it).

/// Best-effort current-process resident set size in bytes via Mach
/// `task_info(MACH_TASK_BASIC_INFO)`. Returns 0 if the syscall fails;
/// callers should `XCTAssertGreaterThan(_, 0, ...)` to catch silent
/// measurement failures.
internal func currentResidentSetSize() -> UInt64 {
    var info = mach_task_basic_info()
    var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<integer_t>.size)
    let kr: kern_return_t = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
        }
    }
    return kr == KERN_SUCCESS ? UInt64(info.resident_size) : 0
}
