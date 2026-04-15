// Force the linker to pull in libblackbird_core so Task 11's wiring is exercised.
// The actual use of BBCore types is in Task 13's BBTerm wrapper; this is a
// placeholder to make Task 11's pre-build + link path verifiable.
import Foundation

@_silgen_name("bb_term_new")
private func _bb_term_new(_ cols: UInt16, _ rows: UInt16, _ scrollback: UInt32) -> OpaquePointer?

@_silgen_name("bb_term_free")
private func _bb_term_free(_ term: OpaquePointer?)

enum FFILinkProbe {
    /// Called once during app startup so the symbols are referenced and the linker
    /// retains them. Returns true if BBCore linked correctly.
    static func probe() -> Bool {
        guard let t = _bb_term_new(80, 24, 1000) else { return false }
        _bb_term_free(t)
        return true
    }
}
