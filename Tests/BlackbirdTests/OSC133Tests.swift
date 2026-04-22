import XCTest
@testable import Blackbird
import BBCore

/// Swift-side tests for OSC 133 prompt/command marks. The Rust FFI is
/// exercised in core/tests/osc133.rs; here we pin that BBTerm's Swift
/// wrapper decodes the event's i32_arg into the expected PromptMarkKind
/// and that the payload arrives intact for kind D.
final class OSC133Tests: XCTestCase {

    override class func setUp() {
        super.setUp()
        // Regression for swift-tests-core F1: registering
        // TestHostTermination ensures solo `--filter OSC133Tests`
        // runs don't leave a zombie SwiftUI test host alive. The
        // singleton guard keeps the full-suite path idempotent.
        TestHostTermination.shared.register()
    }

    /// Helper: feed a sequence through BBTerm, capture the first
    /// `.promptMark(...)` event that fires synchronously on the core
    /// thread before `input(_:)` returns.
    private func captureFirstMark(_ bytes: [UInt8]) throws -> (kind: BBTerm.PromptMarkKind, exitCode: String)? {
        let term = try XCTUnwrap(BBTerm(size: .init(cols: 10, rows: 3)))
        var captured: (BBTerm.PromptMarkKind, String)?
        term.onEvent { event in
            if case .promptMark(let kind, let exit) = event, captured == nil {
                captured = (kind, exit)
            }
        }
        term.input(bytes)
        return captured
    }

    func test_csi133A_decodesToPromptStart() throws {
        let mark = try captureFirstMark([0x1b, 0x5d] + Array("133;A".utf8) + [0x1b, 0x5c])
        XCTAssertEqual(mark?.kind, .promptStart)
        XCTAssertEqual(mark?.exitCode, "")
    }

    func test_csi133B_decodesToCommandStart() throws {
        let mark = try captureFirstMark([0x1b, 0x5d] + Array("133;B".utf8) + [0x1b, 0x5c])
        XCTAssertEqual(mark?.kind, .commandStart)
    }

    func test_csi133C_decodesToCommandOutput() throws {
        let mark = try captureFirstMark([0x1b, 0x5d] + Array("133;C".utf8) + [0x1b, 0x5c])
        XCTAssertEqual(mark?.kind, .commandOutput)
    }

    func test_csi133D_decodesWithExitCode() throws {
        // `\e]133;D;137\e\\` — command killed (SIGKILL + 128).
        let mark = try captureFirstMark([0x1b, 0x5d] + Array("133;D;137".utf8) + [0x1b, 0x5c])
        XCTAssertEqual(mark?.kind, .commandEnd)
        XCTAssertEqual(mark?.exitCode, "137")
    }

    func test_csi133D_exitZero_fullPath() throws {
        // Verify `.commandEnd` with "0" exit code also flows through. Bug
        // regressions that set i32_arg to 0 instead of 4 would silently
        // drop this — XCTUnwrap below catches that.
        let mark = try XCTUnwrap(
            captureFirstMark([0x1b, 0x5d] + Array("133;D;0".utf8) + [0x1b, 0x5c])
        )
        XCTAssertEqual(mark.kind, .commandEnd)
        XCTAssertEqual(mark.exitCode, "0")
    }

    func test_unknownSubKind_emitsNoSwiftEvent() throws {
        // `\e]133;Z\e\\` — unknown sub-kind. The Rust scanner drops it;
        // Swift should therefore never observe an event. Captures a
        // potential future regression where PromptMarkKind gains a new
        // case without a Rust-side counterpart.
        let mark = try captureFirstMark([0x1b, 0x5d] + Array("133;Z".utf8) + [0x1b, 0x5c])
        XCTAssertNil(mark)
    }
}
