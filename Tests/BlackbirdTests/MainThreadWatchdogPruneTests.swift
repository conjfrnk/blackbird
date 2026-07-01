import XCTest
import Foundation
@testable import Blackbird

/// S4-003: Orphan `.partial` hang-report files accumulate after a force-
/// quit mid-capture. The S5-004 fix routes `captureHangReport` through a
/// `<name>.txt.partial` sibling + atomic rename, so an interrupted
/// `sample(1)` leaves a `.partial` instead of polluting Settings →
/// Diagnostics with a truncated `.txt` trace. But the Diagnostics store
/// filters on the `.txt` suffix only, which means those orphans:
///
///   - never surface to the user, AND
///   - never get cleaned up.
///
/// Across enough force-quits this turns `~/Library/Logs/Blackbird/` into
/// a silent ratchet of dead-bytes (each capture target is ~tens of KB).
/// The fix is a startup-time prune step on `MainThreadWatchdog` that
/// removes ORPHAN `hang-*.txt.partial` siblings older than a safety
/// threshold (default ~60 s, so a concurrent capture-in-flight isn't
/// reaped from under itself).
///
/// These tests pin the CONTRACT of the prune function, not its
/// implementation. Each test:
///
///   1. mkdirs an isolated tmp directory (mktemp-style, UUID suffix),
///   2. plants 1-2 small files (a few bytes each — no payload required;
///      the prune function makes decisions on filename + mtime alone),
///   3. invokes `HangReportStore.pruneOrphanPartials(in:olderThan:)`,
///   4. asserts the post-prune directory state.
///
/// Memory + safety pre-flight (per CLAUDE.md test-authoring rules):
///   - ≤ 2 small text files per test (a few bytes each), well under 1 KB
///     on-disk per test. Peak RSS during the test < 100 KB.
///   - Wall time < 50 ms per test (no Thread.sleep, no real sample(1)
///     spawn, no MainWindowController, no PTY).
///   - `addTeardownBlock` removes the tmp dir even on assertion failure,
///     so a flaky run never leaves a turd in `/private/var/folders/...`.
///
/// Why TAG/HEAD diff is degenerate for this regression: at the v0.2.5
/// tag, `captureHangReport()` wrote directly to the final `.txt` path —
/// no `.partial` sibling existed in the codebase at all, so a TAG-era
/// startup prune would have nothing to grep for. The fix at HEAD
/// introduced the `.partial` pattern, which is exactly what creates the
/// invisible-orphan accumulation surface this prune must close.
final class MainThreadWatchdogPruneTests: XCTestCase {

    // MARK: - Helpers

    /// mktemp-style isolated directory. Mirrors the pattern used in
    /// `DiagnosticReportStoreTests.makeTempDirectory()` so the prune
    /// tests stay in lockstep with the store-side fixture style.
    private func makeTempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("blackbird-watchdog-prune-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Plant a small file (a few bytes) and optionally back-date its
    /// mtime so the prune's `olderThan` window catches it. mtime is
    /// the ONLY signal the prune can use to distinguish "abandoned
    /// orphan from a prior session" from "live `.partial` from a
    /// capture happening RIGHT NOW in this PID" — pid in the name
    /// doesn't disambiguate (pids recycle), and ctime/birthtime aren't
    /// portably mutable from userspace.
    @discardableResult
    private func plantFile(
        named name: String,
        in directory: URL,
        ageSeconds: TimeInterval = 0
    ) throws -> URL {
        let url = directory.appendingPathComponent(name)
        let data = Data("x".utf8)  // 1 byte is enough; prune decides on name+mtime alone.
        let created = FileManager.default.createFile(atPath: url.path, contents: data)
        XCTAssertTrue(created, "plant of \(name) failed — test fixture is unhealthy")
        if ageSeconds > 0 {
            let backdated = Date(timeIntervalSinceNow: -ageSeconds)
            try FileManager.default.setAttributes(
                [.modificationDate: backdated],
                ofItemAtPath: url.path
            )
        }
        return url
    }

    // MARK: - Happy path: orphan reaped

    /// Pre-flight: 1 file (1 byte), 1 stat, 1 unlink. Memory: <1 KB.
    /// Wall: <20 ms. No subprocess, no thread.
    ///
    /// The smoking gun for S4-003: a `hang-*.txt.partial` file that
    /// matches the filename shape produced by `captureHangReport`
    /// (timestamp-pid-uuid in the stem) AND is older than the safety
    /// threshold MUST be removed by `pruneOrphanPartials`. Passing
    /// `olderThan: 0` says "anything strictly older than now is
    /// reapable" — deterministic for assertions because the file's
    /// mtime is necessarily in the past by the time we call prune.
    func test_prunesOrphanPartialHangFiles() throws {
        let tmpDir = try makeTempDirectory()
        addTeardownBlock {
            try? FileManager.default.removeItem(at: tmpDir)
        }

        let orphan = try plantFile(
            named: "hang-1700000000000-9999-deadbeef.txt.partial",
            in: tmpDir,
            ageSeconds: 3600  // 1 h old — well past any sane safety threshold.
        )

        HangReportStore.pruneOrphanPartials(in: tmpDir.path, olderThan: 0)

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: orphan.path),
            "orphan hang-*.txt.partial older than the safety threshold MUST be "
                + "reaped — found \(orphan.lastPathComponent) still on disk"
        )
        // Stronger directory-level pin: NO `.partial` files remain anywhere
        // under tmpDir. Catches an implementation that removes the one we
        // planted but somehow leaves a sibling on disk.
        let remaining = (try? FileManager.default.contentsOfDirectory(atPath: tmpDir.path)) ?? []
        let stragglers = remaining.filter { $0.hasSuffix(".partial") }
        XCTAssertTrue(
            stragglers.isEmpty,
            "expected no `.partial` files post-prune, found: \(stragglers)"
        )
    }

    // MARK: - Real hang reports preserved

    /// Pre-flight: 1 file, 1 stat. Memory: <1 KB. Wall: <20 ms.
    ///
    /// `hang-*.txt` is the SURFACED report — it's what the user sees in
    /// Settings → Diagnostics and what `DiagnosticReportStore` filters
    /// for. The prune MUST NOT touch these: clobbering a real report
    /// would be a worse bug than the orphan accumulation we're fixing.
    /// Use `olderThan: 0` to maximise the chance an over-eager prune
    /// would reap this (no safety-window protection), and assert it's
    /// still there.
    func test_preservesRealHangReports() throws {
        let tmpDir = try makeTempDirectory()
        addTeardownBlock {
            try? FileManager.default.removeItem(at: tmpDir)
        }

        let realReport = try plantFile(
            named: "hang-1700000000000-9999-cafebabe.txt",
            in: tmpDir,
            ageSeconds: 3600  // old too — proves age alone doesn't gate the reap.
        )

        HangReportStore.pruneOrphanPartials(in: tmpDir.path, olderThan: 0)

        XCTAssertTrue(
            FileManager.default.fileExists(atPath: realReport.path),
            "real hang report (`.txt`, no `.partial` suffix) MUST be preserved "
                + "by prune — found \(realReport.lastPathComponent) was removed"
        )
    }

    // MARK: - Unrelated partials preserved

    /// Pre-flight: 2 small files. Memory: <1 KB. Wall: <20 ms.
    ///
    /// The prune's name filter MUST be specific to `hang-*.txt.partial`
    /// — the exact filename shape `captureHangReport` writes. Generic
    /// `.partial` files (an editor's swap, another tool's atomic-write
    /// pattern, a user-placed file) are NONE of our business and must
    /// survive. Two non-matching shapes:
    ///
    ///   - `not-a-hang.txt.partial` — matches `*.txt.partial` but NOT
    ///     `hang-*.txt.partial`. Tests that the prefix gate fires.
    ///   - `random-file.partial`     — `.partial` suffix but no `.txt`
    ///     middle segment. Tests that the suffix gate fires.
    ///
    /// Both must remain on disk after prune. Use `olderThan: 0` so
    /// age can't be the excuse for preservation — it has to be the
    /// name filter doing the work.
    func test_preservesUnrelatedPartials() throws {
        let tmpDir = try makeTempDirectory()
        addTeardownBlock {
            try? FileManager.default.removeItem(at: tmpDir)
        }

        let notAHang = try plantFile(
            named: "not-a-hang.txt.partial",
            in: tmpDir,
            ageSeconds: 3600
        )
        let randomFile = try plantFile(
            named: "random-file.partial",
            in: tmpDir,
            ageSeconds: 3600
        )

        HangReportStore.pruneOrphanPartials(in: tmpDir.path, olderThan: 0)

        XCTAssertTrue(
            FileManager.default.fileExists(atPath: notAHang.path),
            "non-hang `*.txt.partial` MUST be preserved — prune over-reached "
                + "and removed \(notAHang.lastPathComponent)"
        )
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: randomFile.path),
            "generic `*.partial` (no `.txt` middle segment) MUST be preserved "
                + "— prune over-reached and removed \(randomFile.lastPathComponent)"
        )
    }

    // MARK: - Safety threshold respected

    /// Pre-flight: 1 fresh file. Memory: <1 KB. Wall: <20 ms.
    ///
    /// A `hang-*.txt.partial` whose mtime is YOUNGER than the safety
    /// threshold could be a `captureHangReport` in flight RIGHT NOW
    /// (sample(1) takes 2 s; if the watchdog races with the prune,
    /// reaping the partial mid-capture would either undo the sample
    /// output or — worse — leave the rename-target dangling once
    /// `moveItem` fires on a path that prune just unlinked).
    ///
    /// Concrete scenario the contract pins:
    ///   - we plant a brand-new `hang-...txt.partial` (mtime ≈ now),
    ///   - call prune with `olderThan: 3600` (1 h window),
    ///   - the file MUST be preserved (it's not yet an orphan).
    ///
    /// The plant uses `ageSeconds: 0` which leaves mtime at the
    /// `createFile` instant — by the time prune runs, the file is
    /// at most a few ms old, comfortably under the 1 h window.
    func test_respectsSafetyThreshold() throws {
        let tmpDir = try makeTempDirectory()
        addTeardownBlock {
            try? FileManager.default.removeItem(at: tmpDir)
        }

        let freshPartial = try plantFile(
            named: "hang-1700000000000-9999-feedface.txt.partial",
            in: tmpDir,
            ageSeconds: 0  // mtime = now; younger than 1 h window below.
        )

        HangReportStore.pruneOrphanPartials(in: tmpDir.path, olderThan: 3600)

        XCTAssertTrue(
            FileManager.default.fileExists(atPath: freshPartial.path),
            "fresh `hang-*.txt.partial` (mtime ~ now) MUST be preserved when "
                + "called with `olderThan: 3600` — a concurrent capture's "
                + "in-flight partial cannot be reaped from under it"
        )
    }
}
