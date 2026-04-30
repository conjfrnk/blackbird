import XCTest
@testable import Blackbird

/// Pin the contract of `DiagnosticReportStore` — the model behind the v0.2
/// Settings → Diagnostics tab.
///
/// Memory pre-flight: each test writes ≤ 4 small text files (a few hundred
/// bytes each) into `mktemp`-style temp directories. < 1 MB peak RSS,
/// < 200 ms wall per test. The store doesn't touch `~/Library/Logs/...` —
/// the init takes injected URLs, so production data is never read or
/// written.
@MainActor
final class DiagnosticReportStoreTests: XCTestCase {

    private var hangDir: URL!
    private var crashDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        hangDir = try makeTempDirectory()
        crashDir = try makeTempDirectory()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: hangDir)
        try? FileManager.default.removeItem(at: crashDir)
        try super.tearDownWithError()
    }

    // MARK: - Empty state

    func testEmptyDirectoriesReturnsEmpty() {
        // Memory: <1 KB. Wall: ~5 ms.
        let store = DiagnosticReportStore(hangDirectory: hangDir, crashDirectory: crashDir)
        store.reload()
        XCTAssertEqual(store.reports.count, 0)
    }

    func testMissingDirectoriesReturnEmpty() {
        // Memory: <1 KB. Wall: ~5 ms.
        // A user's first-ever launch has no Logs dir at all — this must
        // resolve to "no reports", not a fatal.
        let nonexistentHang = hangDir.appendingPathComponent("does-not-exist")
        let nonexistentCrash = crashDir.appendingPathComponent("does-not-exist")
        let store = DiagnosticReportStore(hangDirectory: nonexistentHang, crashDirectory: nonexistentCrash)
        store.reload()
        XCTAssertEqual(store.reports.count, 0)
    }

    // MARK: - File detection

    func testHangFilesAreDetected() throws {
        // Memory: <1 KB. Wall: ~10 ms.
        try writeFile("hang-1234.txt", in: hangDir, contents: "trace A")
        try writeFile("hang-5678.txt", in: hangDir, contents: "trace B")
        let store = DiagnosticReportStore(hangDirectory: hangDir, crashDirectory: crashDir)
        store.reload()
        XCTAssertEqual(store.reports.count, 2)
        XCTAssertTrue(store.reports.allSatisfy { $0.kind == .hang })
    }

    func testCrashFilesAreDetected() throws {
        // Memory: <1 KB. Wall: ~10 ms.
        try writeFile("Blackbird-2026-04-30.ips", in: crashDir, contents: "{}")
        try writeFile("Blackbird-2026-04-29.crash", in: crashDir, contents: "Process: Blackbird")
        let store = DiagnosticReportStore(hangDirectory: hangDir, crashDirectory: crashDir)
        store.reload()
        XCTAssertEqual(store.reports.count, 2)
        XCTAssertTrue(store.reports.allSatisfy { $0.kind == .crash })
    }

    func testNonBlackbirdCrashesIgnored() throws {
        // Memory: <1 KB. Wall: ~10 ms.
        // The DiagnosticReports dir contains crashes for every app on the
        // system. Only ours should surface.
        try writeFile("OtherApp-2026-04-30.ips", in: crashDir, contents: "{}")
        try writeFile("Safari-2026-04-30.ips", in: crashDir, contents: "{}")
        try writeFile("Blackbird-2026-04-30.ips", in: crashDir, contents: "{}")
        let store = DiagnosticReportStore(hangDirectory: hangDir, crashDirectory: crashDir)
        store.reload()
        XCTAssertEqual(store.reports.count, 1)
        XCTAssertTrue(store.reports[0].url.lastPathComponent.hasPrefix("Blackbird-"))
    }

    func testNonHangFilesIgnored() throws {
        // Memory: <1 KB. Wall: ~10 ms.
        // The Logs/Blackbird dir might also contain ad-hoc Logger
        // dumps or watchdog metadata in the future. Stick to the
        // hang-*.txt convention.
        try writeFile("hang-1.txt", in: hangDir, contents: "ok")
        try writeFile("watchdog-config.json", in: hangDir, contents: "{}")
        try writeFile("hang-2.log", in: hangDir, contents: "wrong-suffix")
        let store = DiagnosticReportStore(hangDirectory: hangDir, crashDirectory: crashDir)
        store.reload()
        XCTAssertEqual(store.reports.count, 1)
        XCTAssertEqual(store.reports[0].url.lastPathComponent, "hang-1.txt")
    }

    // MARK: - Sort order

    func testSortedByMtimeDescending() throws {
        // Memory: <1 KB. Wall: ~50 ms (sleeps to differentiate mtimes).
        try writeFile("hang-old.txt", in: hangDir, contents: "old")
        Thread.sleep(forTimeInterval: 0.02)
        try writeFile("hang-mid.txt", in: hangDir, contents: "mid")
        Thread.sleep(forTimeInterval: 0.02)
        try writeFile("hang-new.txt", in: hangDir, contents: "new")
        // Touch the middle file so its mtime is the newest.
        let midURL = hangDir.appendingPathComponent("hang-mid.txt")
        try FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: midURL.path)
        let store = DiagnosticReportStore(hangDirectory: hangDir, crashDirectory: crashDir)
        store.reload()
        XCTAssertEqual(store.reports.count, 3)
        XCTAssertEqual(store.reports[0].url.lastPathComponent, "hang-mid.txt",
                       "newest-touched file must come first")
        // The remaining two should be sorted by their original creation
        // order: new before old.
        XCTAssertEqual(store.reports[1].url.lastPathComponent, "hang-new.txt")
        XCTAssertEqual(store.reports[2].url.lastPathComponent, "hang-old.txt")
    }

    // MARK: - Metadata

    func testFileSizeIsRecorded() throws {
        // Memory: <1 KB. Wall: ~10 ms.
        let payload = String(repeating: "x", count: 1234)
        try writeFile("hang-size.txt", in: hangDir, contents: payload)
        let store = DiagnosticReportStore(hangDirectory: hangDir, crashDirectory: crashDir)
        store.reload()
        XCTAssertEqual(store.reports.count, 1)
        XCTAssertEqual(store.reports[0].byteSize, 1234)
    }

    // MARK: - Reload semantics

    func testReloadReplacesContents() throws {
        // Memory: <1 KB. Wall: ~20 ms.
        let store = DiagnosticReportStore(hangDirectory: hangDir, crashDirectory: crashDir)
        store.reload()
        XCTAssertEqual(store.reports.count, 0)

        try writeFile("hang-1.txt", in: hangDir, contents: "first")
        store.reload()
        XCTAssertEqual(store.reports.count, 1)

        try FileManager.default.removeItem(at: hangDir.appendingPathComponent("hang-1.txt"))
        store.reload()
        XCTAssertEqual(store.reports.count, 0,
                       "reload must reflect deletions, not retain stale entries")
    }

    func testMixedHangAndCrashReportsAreInterleavedByDate() throws {
        // Memory: <1 KB. Wall: ~30 ms.
        try writeFile("hang-old.txt", in: hangDir, contents: "old hang")
        Thread.sleep(forTimeInterval: 0.02)
        try writeFile("Blackbird-mid.ips", in: crashDir, contents: "{}")
        Thread.sleep(forTimeInterval: 0.02)
        try writeFile("hang-new.txt", in: hangDir, contents: "new hang")
        let store = DiagnosticReportStore(hangDirectory: hangDir, crashDirectory: crashDir)
        store.reload()
        XCTAssertEqual(store.reports.count, 3)
        // Newest first (hang-new), then crash (Blackbird-mid), then oldest hang.
        XCTAssertEqual(store.reports[0].url.lastPathComponent, "hang-new.txt")
        XCTAssertEqual(store.reports[1].url.lastPathComponent, "Blackbird-mid.ips")
        XCTAssertEqual(store.reports[2].url.lastPathComponent, "hang-old.txt")
        // Kinds are tagged correctly across the interleaving.
        XCTAssertEqual(store.reports[0].kind, .hang)
        XCTAssertEqual(store.reports[1].kind, .crash)
        XCTAssertEqual(store.reports[2].kind, .hang)
    }

    // MARK: - Helpers

    private func makeTempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("blackbird-diagnostic-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func writeFile(_ name: String, in directory: URL, contents: String) throws {
        let url = directory.appendingPathComponent(name)
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }
}
