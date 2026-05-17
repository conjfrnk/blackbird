import XCTest
@testable import Blackbird
import BBCore

/// Cross-language contract pins for the Rust ⇄ Swift FFI boundary.
/// Tests here catch silent drift between the Rust source-of-truth and
/// the Swift wrappers that mirror it — situations where renaming /
/// renumbering on one side compiles cleanly but the runtime semantics
/// drift.
///
/// Memory pre-flight: pure-Swift constant comparisons, no allocations
/// beyond a few `XCTAssertEqual` calls. <1 KB, <10 ms per test.
final class FFIContractTests: XCTestCase {

    /// S6-001: BBPromptMarkKind was previously omitted from cbindgen's
    /// `[export].include` list, so the generated C header carried no
    /// reference to the Rust enum. Swift redeclared a parallel
    /// `PromptMarkKind` whose raw values had to match Rust's
    /// (1=PromptStart, 2=CommandStart, 3=CommandOutput, 4=CommandEnd) —
    /// but with no header binding, a future Rust renumber compiled
    /// cleanly on both sides and silently misrouted prompt events.
    ///
    /// Now `BBPromptMarkKind` IS exported. cbindgen emits constants of
    /// the form `BB_PROMPT_MARK_KIND_<VARIANT>` per the
    /// `prefix_with_name = true` + `ScreamingSnakeCase` rules in
    /// cbindgen.toml. This test pins each Swift case's raw value
    /// against the imported C constant. Any future Rust renumber
    /// breaks compilation here (if the C constant disappears) or
    /// trips the assertion (if Rust and Swift drift).
    func testPromptMarkKind_rawValuesMatchExportedC() {
        XCTAssertEqual(BBTerm.PromptMarkKind.promptStart.rawValue,
                       UInt8(BB_PROMPT_MARK_KIND_A.rawValue),
                       "Swift .promptStart must equal Rust BB_PROMPT_MARK_KIND_A")
        XCTAssertEqual(BBTerm.PromptMarkKind.commandStart.rawValue,
                       UInt8(BB_PROMPT_MARK_KIND_B.rawValue),
                       "Swift .commandStart must equal Rust BB_PROMPT_MARK_KIND_B")
        XCTAssertEqual(BBTerm.PromptMarkKind.commandOutput.rawValue,
                       UInt8(BB_PROMPT_MARK_KIND_C.rawValue),
                       "Swift .commandOutput must equal Rust BB_PROMPT_MARK_KIND_C")
        XCTAssertEqual(BBTerm.PromptMarkKind.commandEnd.rawValue,
                       UInt8(BB_PROMPT_MARK_KIND_D.rawValue),
                       "Swift .commandEnd must equal Rust BB_PROMPT_MARK_KIND_D")
    }
}
