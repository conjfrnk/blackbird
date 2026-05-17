import XCTest
import ObjectiveC.runtime
import Sparkle
@testable import Blackbird

/// Pin SparkleAlertOverride.install()'s F-S7-001 swizzle-leak fix.
///
/// Memory pre-flight: < 1 MB peak (no allocations beyond two block IMPs and
/// a couple of pointer comparisons), < 50 ms wall (no Sparkle UI, no I/O).
///
/// What we pin:
///  1. After the first `install()`, the override tracks a non-nil IMP.
///  2. After a second `install()`, the tracked IMP is different (a fresh
///     block was minted) — proving the install path is replace-not-skip.
///  3. The leak fix itself is observable indirectly via `_installedBlockIMPForTests`:
///     the previous IMP is replaced rather than retained alongside the new
///     one. We can't directly observe `imp_removeBlock` succeeded without
///     a sentinel object captured by the block (which would require widening
///     the test seam beyond the v0.2 scope), but the replacement contract
///     is what would have been violated by a missing-tracking bug.
@MainActor
final class SparkleAlertOverrideTests: XCTestCase {

    override func setUp() {
        super.setUp()
        // Reset the tracking state so each test method starts from a known
        // pre-install posture, regardless of test ordering.
        SparkleAlertOverride._resetForTests()
    }

    override func tearDown() {
        // Leave the override in a clean state for any other test that might
        // observe Sparkle alert behavior — DiagnosticReportStoreTests etc.
        // don't, but symmetry with setUp is cheap.
        SparkleAlertOverride._resetForTests()
        super.tearDown()
    }

    func testFirstInstallTracksOurIMP() {
        // Memory: < 64 KB (one block IMP, one pointer field). Wall: ~5 ms.
        XCTAssertNil(SparkleAlertOverride._installedBlockIMPForTests,
                     "after _resetForTests, tracking field must be nil")
        SparkleAlertOverride.install()
        XCTAssertNotNil(SparkleAlertOverride._installedBlockIMPForTests,
                        "after first install, our installed block IMP must be tracked so a re-install can free it (F-S7-001)")
    }

    func testRepeatedInstallReplacesTrackedIMP() {
        // Memory: < 128 KB (two block IMPs in flight; the first is freed by
        // the second install via imp_removeBlock). Wall: ~10 ms.
        SparkleAlertOverride.install()
        let firstTrackedIMP = SparkleAlertOverride._installedBlockIMPForTests
        XCTAssertNotNil(firstTrackedIMP, "first install must track an IMP")

        SparkleAlertOverride.install()
        let secondTrackedIMP = SparkleAlertOverride._installedBlockIMPForTests
        XCTAssertNotNil(secondTrackedIMP, "second install must track an IMP")

        // Compare as raw pointers — IMP is a function pointer typedef and
        // doesn't conform to Equatable directly.
        let first = unsafeBitCast(firstTrackedIMP!, to: UnsafeRawPointer.self)
        let second = unsafeBitCast(secondTrackedIMP!, to: UnsafeRawPointer.self)
        XCTAssertNotEqual(first, second,
                          "re-install must mint a fresh IMP and replace the tracking field; without this contract, every call leaks the prior block (F-S7-001)")
    }

    func testInstalledIMPMatchesClassMethodImpl() throws {
        // Memory: < 64 KB. Wall: ~5 ms.
        // The IMP we track must be the same one currently installed on the
        // class — not a stale reference from a previous override life.
        SparkleAlertOverride.install()
        let tracked = try XCTUnwrap(SparkleAlertOverride._installedBlockIMPForTests,
                                    "install() must populate the tracking field")

        let cls: AnyClass = SPUStandardUserDriver.self
        let sel = NSSelectorFromString("showUpdateNotFoundWithError:acknowledgement:")
        let live = class_getMethodImplementation(cls, sel)

        let trackedRaw = unsafeBitCast(tracked, to: UnsafeRawPointer.self)
        let liveRaw = unsafeBitCast(live, to: UnsafeRawPointer.self)
        XCTAssertEqual(trackedRaw, liveRaw,
                       "tracked IMP must match the live class IMP — divergence means a future re-install would free an IMP that's not actually installed")
    }

    // MARK: - upToDateMessage (S2-009)

    /// When CFBundleShortVersionString is missing/empty, the inline format
    /// `"\(name) \(version) is the latest version."` produced
    /// `"Blackbird  is the latest version."` — a double-space malformation
    /// the user sees instead of the intended diagnostic.
    func testUpToDateMessage_emptyVersion_doesNotProduceDoubleSpace() {
        let msg = SparkleAlertOverride.upToDateMessage(name: "Blackbird", version: "")
        XCTAssertFalse(msg.contains("  "),
                       "double-space malforms the alert text; got: \(msg)")
        XCTAssertTrue(msg.contains("Blackbird"), "app name preserved")
        XCTAssertTrue(msg.contains("latest"), "diagnostic shape preserved")
    }

    func testUpToDateMessage_normalVersion_includesIt() {
        let msg = SparkleAlertOverride.upToDateMessage(name: "Blackbird", version: "0.2.5")
        XCTAssertEqual(msg, "Blackbird 0.2.5 is the latest version.")
    }
}
