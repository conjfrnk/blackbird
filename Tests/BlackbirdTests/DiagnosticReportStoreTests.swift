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

    // MARK: - Security: reject symlinks

    func testPrefixOnlyFilenamesAreRejected() throws {
        // Memory: <1 KB. Wall: ~10 ms.
        // `Blackbird-.ips`, `Blackbird-.crash`, and `hang-.txt` match the
        // prefix+suffix gate but carry no timestamp content. They're
        // either accidental zero-byte files or planted noise — surfacing
        // them as legitimate rows would confuse the user. The length
        // check in reload() requires SOMETHING between the prefix and
        // suffix.
        try writeFile("Blackbird-.ips", in: crashDir, contents: "")
        try writeFile("Blackbird-.crash", in: crashDir, contents: "")
        try writeFile("hang-.txt", in: hangDir, contents: "")
        // A legitimate sibling so we know reload didn't bail entirely.
        try writeFile("hang-1234.txt", in: hangDir, contents: "real")
        let store = DiagnosticReportStore(hangDirectory: hangDir, crashDirectory: crashDir)
        store.reload()
        XCTAssertEqual(store.reports.count, 1,
                       "only the legitimate hang-1234.txt should surface; prefix-only filenames are rejected")
        XCTAssertEqual(store.reports[0].url.lastPathComponent, "hang-1234.txt")
    }

    func testSymlinkInCrashDirIsRejected() throws {
        // Memory: <1 KB. Wall: ~10 ms (one regular file, one symlink).
        // Security: a planted symlink at ~/Library/Logs/DiagnosticReports/
        // Blackbird-foo.ips → /etc/passwd would otherwise be surfaced as
        // a "crash report"; clicking Email Diagnostics would exfiltrate
        // its target to the support address.
        let target = crashDir.appendingPathComponent("Blackbird-target.ips")
        try "{\"real\":true}".write(to: target, atomically: true, encoding: .utf8)
        let symlink = crashDir.appendingPathComponent("Blackbird-symlink.ips")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: target)
        let store = DiagnosticReportStore(hangDirectory: hangDir, crashDirectory: crashDir)
        store.reload()
        XCTAssertEqual(store.reports.count, 1, "symlink must be filtered out")
        XCTAssertEqual(store.reports[0].url.lastPathComponent, "Blackbird-target.ips")
    }

    func testSymlinkInHangDirIsRejected() throws {
        // Memory: <1 KB. Wall: ~10 ms.
        let target = hangDir.appendingPathComponent("hang-real.txt")
        try "real hang".write(to: target, atomically: true, encoding: .utf8)
        let symlink = hangDir.appendingPathComponent("hang-symlink.txt")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: target)
        let store = DiagnosticReportStore(hangDirectory: hangDir, crashDirectory: crashDir)
        store.reload()
        XCTAssertEqual(store.reports.count, 1)
        XCTAssertEqual(store.reports[0].url.lastPathComponent, "hang-real.txt")
    }

    func testReloadIsRobustToHostileSibling() throws {
        // Memory: <1 KB. Wall: ~20 ms.
        // Scenario: a sibling with restrictive permissions next to legitimate
        // reports. URLResourceValues for `.fileSizeKey` / `.isRegularFileKey`
        // reads from the directory entry (st_size, st_mode in the inode),
        // which remains accessible to the owner even at mode 000 — so the
        // restricted file IS surfaced, just with byteSize visible. The
        // contract this test pins is "one weird sibling does not break the
        // whole list", not "permission-denied is filtered" (we cannot
        // distinguish that from "directory entry is canonical truth"
        // without opening the file).
        try writeFile("hang-1.txt", in: hangDir, contents: "first")
        try writeFile("hang-2.txt", in: hangDir, contents: "second")
        let restricted = hangDir.appendingPathComponent("hang-3.txt")
        try "third".write(to: restricted, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o000))],
            ofItemAtPath: restricted.path
        )
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: Int16(0o644))],
                ofItemAtPath: restricted.path
            )
        }
        let store = DiagnosticReportStore(hangDirectory: hangDir, crashDirectory: crashDir)
        store.reload()
        // The two readable files must still surface — reload doesn't
        // bail on the whole list because of one tricky sibling.
        let names = store.reports.map { $0.url.lastPathComponent }
        XCTAssertTrue(names.contains("hang-1.txt"))
        XCTAssertTrue(names.contains("hang-2.txt"))
        // Whether hang-3.txt surfaces depends on whether the directory-entry
        // stat path was sufficient — we don't constrain that here.
    }

    // MARK: - Mixed kinds

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

    // MARK: - DiagnosticsView.loadAndSanitize off-main dispatch (M6)

    /// `DiagnosticsView.copy` used to call `Data(contentsOf:)` synchronously
    /// on `@MainActor`. A 3 MB hang report on a network-mounted home would
    /// stall Settings UI for seconds. The fix routes the read + per-byte
    /// control-char scan through `Task.detached`. Round-trip a small
    /// file as the basic correctness pin.
    func testLoadAndSanitizeRoundtripsSmallFile() async throws {
        // Memory: ~4 KB on disk; <1 KB peak RSS. Wall: <50 ms.
        try writeFile("hang-tiny.txt", in: hangDir, contents: "hello world\n")
        let url = hangDir.appendingPathComponent("hang-tiny.txt")
        XCTAssertTrue(Thread.isMainThread,
            "test runs on @MainActor — pre-condition for the off-main check")
        let result = await DiagnosticsView.loadAndSanitize(
            url: url, cap: 16 * 1024 * 1024
        )
        guard case .success(let text) = result else {
            return XCTFail("expected sanitized success, got \(result)")
        }
        XCTAssertEqual(text, "hello world\n")
    }

    /// The worker must execute on a non-main thread. The previous
    /// implementation called `Data(contentsOf:)` synchronously on
    /// `@MainActor`, which beachballed Settings on a network-mounted
    /// home directory; M6 reroutes through `Task.detached`.
    func testLoadAndSanitizeRunsOffMainThread() async throws {
        // Memory: ~4 KB on disk; <1 KB peak RSS. Wall: <50 ms.
        try writeFile("hang-thread.txt", in: hangDir, contents: "main-thread probe")
        let url = hangDir.appendingPathComponent("hang-thread.txt")
        XCTAssertTrue(Thread.isMainThread,
            "test runs on @MainActor — pre-condition for the off-main check")
        let (result, ranOffMain) = await DiagnosticsView.loadAndSanitizeForTesting(
            url: url, cap: 16 * 1024 * 1024
        )
        guard case .success = result else {
            return XCTFail("expected sanitized success, got \(result)")
        }
        XCTAssertTrue(ranOffMain,
            "loadAndSanitize must dispatch the disk read + per-byte scan off the main thread")
    }

    /// A 4 MB synthetic report must round-trip via `loadAndSanitize`
    /// in well under a second. Catches a regression where the read or
    /// scan moves back onto the main thread (the `await` would still
    /// complete but RunLoop wouldn't process other main work concurrently;
    /// the proxy here is wall time).
    func testLoadAndSanitizeOnLargeFileReturnsQuickly() async throws {
        // Memory: ~4 MB on disk + ~4 MB Data peak in detached task ≈ 12 MB
        //         transient RSS (Data + UTF-8 String + sanitized scalar
        //         array). Well under our 256 MB per-test budget. Wall:
        //         50–500 ms locally, generous on CI.
        let payload = String(repeating: "a", count: 4 * 1024 * 1024)
        try writeFile("hang-bulk.txt", in: hangDir, contents: payload)
        let url = hangDir.appendingPathComponent("hang-bulk.txt")
        let start = Date()
        let result = await DiagnosticsView.loadAndSanitize(
            url: url, cap: 16 * 1024 * 1024
        )
        let elapsed = Date().timeIntervalSince(start)
        guard case .success(let text) = result else {
            return XCTFail("expected sanitized success, got \(result)")
        }
        XCTAssertEqual(text.count, 4 * 1024 * 1024)
        XCTAssertLessThan(elapsed, 5.0,
            "4 MB read+sanitize must not stall — the work must be dispatched off main")
    }

    /// Files larger than the inline cap must surface as a typed error.
    /// The cap bound is enforced inside the detached task as a TOCTOU
    /// guard (post-read size check); this pins that contract.
    func testLoadAndSanitizeRejectsOversizeAfterRead() async throws {
        // Memory: ~64 KB on disk; <100 KB transient. Wall: <50 ms.
        let payload = String(repeating: "b", count: 64 * 1024)
        try writeFile("hang-large.txt", in: hangDir, contents: payload)
        let url = hangDir.appendingPathComponent("hang-large.txt")
        // Set the cap below the actual file size so the post-read TOCTOU
        // branch fires inside the worker.
        let result = await DiagnosticsView.loadAndSanitize(url: url, cap: 32 * 1024)
        if case .failure(.grewDuringRead(let bytes)) = result {
            XCTAssertEqual(bytes, 64 * 1024)
        } else {
            XCTFail("expected .grewDuringRead, got \(result)")
        }
    }

    func testLoadAndSanitizeStripsControlBytes() async throws {
        // Memory: <1 KB. Wall: <20 ms.
        // Plant an OSC-introducer byte sequence; sanitiser should
        // collapse it to U+FFFD so a clipboard paste into another
        // terminal can't re-execute the escape.
        let raw = "before\u{1B}]52;c;abc\u{07}after"
        try writeFile("hang-bel.txt", in: hangDir, contents: raw)
        let url = hangDir.appendingPathComponent("hang-bel.txt")
        let result = await DiagnosticsView.loadAndSanitize(
            url: url, cap: 16 * 1024 * 1024
        )
        guard case .success(let text) = result else {
            return XCTFail("expected sanitized success, got \(result)")
        }
        XCTAssertFalse(text.contains("\u{1B}"), "ESC must be replaced")
        XCTAssertFalse(text.contains("\u{07}"), "BEL must be replaced")
        XCTAssertTrue(text.contains("\u{FFFD}"), "U+FFFD substitution must appear")
    }
}
