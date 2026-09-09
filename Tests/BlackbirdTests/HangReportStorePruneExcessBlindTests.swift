import XCTest
import Foundation
@testable import Blackbird

/// Blind behaviour tests for `HangReportStore.pruneExcessReports(in:keep:)`
/// — the cap that stops `~/Library/Logs/Blackbird/` growing one `hang-*.txt`
/// per watchdog trip forever.
///
/// Contract under test:
///   - Only `hang-*.txt` files are candidates. `.partial` siblings and
///     unrelated files are never touched.
///   - The NEWEST `keep` reports (by modification date, NOT by name) survive;
///     everything older is removed.
///   - `keep: 0` removes every report; a negative `keep` is a no-op; a
///     missing directory is a no-op; fewer reports than `keep` ⇒ no removal.
///
/// Memory + time pre-flight (CLAUDE.md test-authoring rules): ≤ 28 one-byte
/// files per test in an isolated temp directory, one `setAttributes` per
/// file, one directory listing. < 200 KB peak, < 100 ms wall. No
/// subprocess, no `sample(1)`, no window, no PTY. Teardown removes the
/// directory even when an assertion fails.
final class HangReportStorePruneExcessBlindTests: XCTestCase {

    private var dir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("blackbird-prune-excess-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
        try super.tearDownWithError()
    }

    // MARK: - Fixture

    private static let reportCount = 25

    /// Age in minutes for report `n` (1-based). A permutation of 0..<25 that
    /// does NOT follow name order, so an implementation that sorts by
    /// filename instead of mtime keeps the wrong five.
    private static func ageMinutes(for n: Int) -> Int { (n * 7) % reportCount }

    /// Seeds 25 `hang-<n>.txt` with distinct back-dated mtimes plus three
    /// non-candidates. Returns the set of report names expected to survive
    /// `keep: 20` (the 20 youngest by mtime).
    @discardableResult
    private func seedReports() throws -> Set<String> {
        let base = Date(timeIntervalSinceNow: -3600)
        for n in 1...Self.reportCount {
            let name = "hang-\(n).txt"
            try plant(name, ageMinutes: Self.ageMinutes(for: n), base: base)
        }
        try plant("hang-x.txt.partial", ageMinutes: 24, base: base)  // as old as the oldest report
        try plant("other.txt", ageMinutes: 24, base: base)
        try plant("notes.log", ageMinutes: 24, base: base)

        let youngest20 = (1...Self.reportCount)
            .sorted { Self.ageMinutes(for: $0) < Self.ageMinutes(for: $1) }
            .prefix(20)
            .map { "hang-\($0).txt" }
        return Set(youngest20)
    }

    private func plant(_ name: String, ageMinutes: Int, base: Date) throws {
        let url = dir.appendingPathComponent(name)
        XCTAssertTrue(FileManager.default.createFile(atPath: url.path, contents: Data("x".utf8)),
                      "fixture plant of \(name) failed")
        let mtime = base.addingTimeInterval(TimeInterval(-60 * ageMinutes))
        try FileManager.default.setAttributes([.modificationDate: mtime], ofItemAtPath: url.path)
    }

    private func listing() -> Set<String> {
        Set((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
    }

    private func reports() -> Set<String> {
        listing().filter { $0.hasPrefix("hang-") && $0.hasSuffix(".txt") }
    }

    private static let nonCandidates: Set<String> = ["hang-x.txt.partial", "other.txt", "notes.log"]

    // MARK: - Tests

    func testKeep20RemovesTheFiveOldestByMtime() throws {
        let expectedSurvivors = try seedReports()
        XCTAssertEqual(reports().count, 25, "fixture sanity")

        HangReportStore.pruneExcessReports(in: dir.path, keep: 20)

        let survivors = reports()
        XCTAssertEqual(survivors.count, 20, "exactly `keep` reports must remain")
        XCTAssertEqual(survivors, expectedSurvivors,
                       "survivors must be the 20 NEWEST by modification date, not by filename. "
                       + "Unexpectedly removed: \(expectedSurvivors.subtracting(survivors).sorted()); "
                       + "unexpectedly kept: \(survivors.subtracting(expectedSurvivors).sorted())")
    }

    func testKeep20LeavesNonCandidatesUntouched() throws {
        try seedReports()
        HangReportStore.pruneExcessReports(in: dir.path, keep: 20)
        XCTAssertTrue(Self.nonCandidates.isSubset(of: listing()),
                      "`.partial`, other.txt and notes.log must never be pruned; missing: "
                      + "\(Self.nonCandidates.subtracting(listing()).sorted())")
    }

    func testKeepZeroRemovesEveryReportButNothingElse() throws {
        try seedReports()
        HangReportStore.pruneExcessReports(in: dir.path, keep: 0)
        XCTAssertEqual(reports(), [], "keep: 0 must remove every hang-*.txt")
        XCTAssertEqual(listing(), Self.nonCandidates, "only the non-candidates may remain")
    }

    func testNegativeKeepIsANoOp() throws {
        try seedReports()
        let before = listing()
        HangReportStore.pruneExcessReports(in: dir.path, keep: -1)
        XCTAssertEqual(listing(), before, "a negative keep must not remove anything")
        HangReportStore.pruneExcessReports(in: dir.path, keep: Int.min)
        XCTAssertEqual(listing(), before)
    }

    func testFewerReportsThanKeepRemovesNothing() throws {
        try seedReports()
        let before = listing()
        HangReportStore.pruneExcessReports(in: dir.path, keep: 30)
        XCTAssertEqual(listing(), before)
    }

    func testExactlyKeepReportsRemovesNothing() throws {
        try seedReports()
        let before = listing()
        HangReportStore.pruneExcessReports(in: dir.path, keep: 25)
        XCTAssertEqual(listing(), before)
    }

    func testNonexistentDirectoryIsANoOp() {
        let missing = dir.appendingPathComponent("does-not-exist-\(UUID().uuidString)").path
        HangReportStore.pruneExcessReports(in: missing, keep: 20)
        XCTAssertFalse(FileManager.default.fileExists(atPath: missing),
                       "prune must not create the directory it was asked to prune")
    }

    func testEmptyDirectoryIsANoOp() {
        HangReportStore.pruneExcessReports(in: dir.path, keep: 20)
        XCTAssertEqual(listing(), [])
        HangReportStore.pruneExcessReports(in: dir.path, keep: 0)
        XCTAssertEqual(listing(), [])
    }

    func testPruneIsIdempotent() throws {
        let expectedSurvivors = try seedReports()
        HangReportStore.pruneExcessReports(in: dir.path, keep: 20)
        HangReportStore.pruneExcessReports(in: dir.path, keep: 20)
        XCTAssertEqual(reports(), expectedSurvivors, "a second prune at the same cap changes nothing")
    }
}
