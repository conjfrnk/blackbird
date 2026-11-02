import XCTest
import Foundation
@testable import Blackbird

/// Blind regression tests for bug pty-4: the decision to hand new shells
/// `TERM=xterm-kitty` is made once per process, so removing the installed
/// terminfo entry while Blackbird is running leaves every later tab with a
/// `TERM` that ncurses cannot resolve.
///
/// Contract under test (observable, end to end): whatever `TERM` a freshly
/// spawned shell is given, the shell's own ncurses tools must be able to
/// resolve it. A user who deletes `~/.terminfo` (or just the `xterm-kitty`
/// entry inside it) and then opens a new tab or window must not see
/// `unknown terminal "xterm-kitty"` from `tput`, `clear`, `less` or any
/// curses program. Either of the two sensible outcomes satisfies this: the
/// app notices the entry is gone and re-provisions it (new shell still gets
/// `xterm-kitty`, now resolvable again), or it notices it cannot provide it
/// and falls back to the universally installed `xterm-256color`. What it may
/// not do is keep announcing a terminal name that no terminfo database on the
/// machine contains. The macOS system terminfo has no `xterm-kitty`, so
/// deleting the user's copy really does make the name unresolvable.
///
/// Rig. `PTY.spawn` runs `/bin/sh -c` with a tiny script that records, into
/// files in a private temp directory, the `TERM` and `HOME` it was handed and
/// the exit status (and stderr) of `infocmp "$TERM"`, `tput cols` and `clear`.
/// Reading the files back makes the oracle exactly what the real ncurses
/// tools in the child said, not what the app believes. The "delete" step
/// moves the installed `xterm-kitty` file(s) out of `$HOME/.terminfo` into a
/// backup directory; tearDown puts them back if the app did not already
/// re-create them, so a developer's real `~/.terminfo` ends the test as it
/// began. After the move the test itself runs `/usr/bin/infocmp xterm-kitty`
/// (no PTY, no app code) and requires it to FAIL, which proves the deletion
/// genuinely makes the name unresolvable rather than leaving the test
/// vacuous.
///
/// Preconditions are asserted, not assumed: `KittyTerminfo.available` must be
/// true when the test starts (the bug report's state: bundled entry present,
/// `tic` succeeded, probe ok) and an installed entry must exist to delete.
///
/// Pre-flight cost (project rule, per `feedback_test_memory_safety`): at most
/// two short-lived `/bin/sh` children per test, spawned strictly one at a
/// time and terminated before the test returns; one `infocmp` subprocess per
/// check; a handful of files under 4 KB; no window, no Metal device, no
/// `MainWindowController`. Wall time is well under a second per test apart
/// from the one-time `tic` inside `KittyTerminfo.available`; every wait is
/// capped at 15 s.
final class KittyTerminfoDeletionBlindTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        TestHostTermination.shared.register()
    }

    // MARK: - State cleaned up in tearDown

    private var scratchDirectories: [URL] = []

    override func tearDown() {
        for dir in scratchDirectories { try? FileManager.default.removeItem(at: dir) }
        scratchDirectories.removeAll()
        super.tearDown()
    }

    private func makeScratchDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("bb-kitty-terminfo-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        scratchDirectories.append(dir)
        return dir
    }

    // MARK: - Child report

    /// What the freshly spawned shell saw, as written by the shell itself.
    private struct ChildReport {
        let term: String
        let home: String
        let infocmpRC: String
        let infocmpErr: String
        let tputRC: String
        let tputErr: String
        let clearRC: String
        let clearErr: String

        var summary: String {
            "TERM=\(term.debugDescription) HOME=\(home.debugDescription) "
            + "infocmp rc=\(infocmpRC) err=\(infocmpErr.debugDescription); "
            + "tput cols rc=\(tputRC) err=\(tputErr.debugDescription); "
            + "clear rc=\(clearRC) err=\(clearErr.debugDescription)"
        }
    }

    /// The script the child runs. `$1` is the directory the reports go to.
    /// stdout of the probes is discarded; stderr (where ncurses prints
    /// `unknown terminal "..."`) is captured. Statuses are written as plain
    /// integers.
    private static let childScript = #"""
    d="$1"
    printf 'TERM=%s\nHOME=%s\n' "$TERM" "$HOME" > "$d/env.txt"
    infocmp "$TERM" >/dev/null 2>"$d/infocmp.err"; echo $? > "$d/infocmp.rc"
    tput cols >/dev/null 2>"$d/tput.err"; echo $? > "$d/tput.rc"
    clear >/dev/null 2>"$d/clear.err"; echo $? > "$d/clear.rc"
    """#

    private func read(_ url: URL) -> String {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return "<missing>" }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Spawns one real shell through `PTY.spawn` (exactly what a new tab
    /// does), waits for it to exit, and returns what it recorded.
    private func spawnShellAndReport(
        file: StaticString = #filePath, line: UInt = #line
    ) throws -> ChildReport {
        let dir = try makeScratchDirectory()
        let pty = try PTY.spawn(
            executable: "/bin/sh",
            arguments: ["-c", Self.childScript, "sh", dir.path],
            envOverrides: [:],
            size: .init(cols: 80, rows: 24)
        )
        let exited = expectation(description: "child exited")
        pty.setOnBytes { _ in }
        pty.setOnExit { _ in exited.fulfill() }
        pty.startReading()
        let result = XCTWaiter().wait(for: [exited], timeout: 15.0)
        XCTAssertEqual(result, .completed,
                       "probe shell did not exit within 15 s", file: file, line: line)
        pty.terminate()

        var term = "<missing>"
        var home = "<missing>"
        for rawLine in read(dir.appendingPathComponent("env.txt")).split(separator: "\n") {
            if rawLine.hasPrefix("TERM=") { term = String(rawLine.dropFirst("TERM=".count)) }
            if rawLine.hasPrefix("HOME=") { home = String(rawLine.dropFirst("HOME=".count)) }
        }
        return ChildReport(
            term: term,
            home: home,
            infocmpRC: read(dir.appendingPathComponent("infocmp.rc")),
            infocmpErr: read(dir.appendingPathComponent("infocmp.err")),
            tputRC: read(dir.appendingPathComponent("tput.rc")),
            tputErr: read(dir.appendingPathComponent("tput.err")),
            clearRC: read(dir.appendingPathComponent("clear.rc")),
            clearErr: read(dir.appendingPathComponent("clear.err"))
        )
    }

    // MARK: - ncurses oracle that does not go through the app

    /// Exit status of `/usr/bin/infocmp <name>` run directly by the test
    /// process, i.e. "can ncurses resolve this terminal name right now".
    private func infocmpStatus(for name: String) throws -> Int32 {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/infocmp")
        task.arguments = [name]
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        try task.run()
        task.waitUntilExit()
        return task.terminationStatus
    }

    // MARK: - Delete + restore of the installed entry

    private var homePath: String {
        ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()
    }

    /// Every installed `xterm-kitty` file under `$HOME/.terminfo/<dir>/`.
    /// macOS `tic` writes a hex-named subdirectory (`78`), older layouts use
    /// the letter (`x`); enumerating covers both.
    private func installedKittyEntries() -> [URL] {
        let root = URL(fileURLWithPath: homePath, isDirectory: true)
            .appendingPathComponent(".terminfo", isDirectory: true)
        let subdirs = (try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil)) ?? []
        return subdirs
            .map { $0.appendingPathComponent("xterm-kitty") }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// Moves every installed entry into a backup directory and arranges for
    /// tearDown to put each one back unless something already re-created it.
    /// Returns how many files were moved.
    @discardableResult
    private func removeInstalledKittyEntries() throws -> Int {
        let backupRoot = try makeScratchDirectory()
        var moved = 0
        for original in installedKittyEntries() {
            let backup = backupRoot.appendingPathComponent("\(moved)-xterm-kitty")
            try FileManager.default.moveItem(at: original, to: backup)
            moved += 1
            addTeardownBlock {
                if !FileManager.default.fileExists(atPath: original.path) {
                    try? FileManager.default.createDirectory(
                        at: original.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try? FileManager.default.moveItem(at: backup, to: original)
                }
            }
        }
        return moved
    }

    // MARK: - Tests

    /// Control: with the entry installed and untouched, a new shell gets
    /// `TERM=xterm-kitty` and every ncurses tool in it resolves that name.
    /// Passes on a correct build with or without the fix; it proves the rig
    /// (the child inherits the `HOME` whose `.terminfo` we manipulate, and
    /// `infocmp` / `tput` / `clear` do succeed when the entry is there), so a
    /// failure in the deletion test below can only mean deletion handling.
    func testControl_EntryIntact_ShellGetsResolvableXtermKitty() throws {
        XCTAssertTrue(KittyTerminfo.available,
                      "precondition: bundled kitty terminfo installed, tic ok, infocmp ok")
        XCTAssertEqual(try infocmpStatus(for: "xterm-kitty"), 0,
                       "precondition: xterm-kitty must be resolvable before the test touches anything")

        let report = try spawnShellAndReport()
        XCTAssertEqual(report.home, homePath,
                       "precondition: the child must see the HOME whose .terminfo this test manipulates; \(report.summary)")
        XCTAssertEqual(report.term, "xterm-kitty",
                       "with the entry present the shell must be told TERM=xterm-kitty; \(report.summary)")
        XCTAssertEqual(report.infocmpRC, "0", "infocmp $TERM must succeed; \(report.summary)")
        XCTAssertEqual(report.tputRC, "0", "tput cols must succeed; \(report.summary)")
        XCTAssertEqual(report.clearRC, "0", "clear must succeed; \(report.summary)")
    }

    /// The bug: the entry is removed while the app keeps running, then a new
    /// tab is opened. The new shell's `TERM` must still be resolvable by the
    /// shell's ncurses (re-provisioned `xterm-kitty`, or a fallback such as
    /// `xterm-256color`; never an unresolvable `xterm-kitty`).
    func testNewShellAfterEntryDeleted_TermIsResolvableByNcurses() throws {
        XCTAssertTrue(KittyTerminfo.available,
                      "precondition: bundled kitty terminfo installed, tic ok, infocmp ok")
        XCTAssertFalse(installedKittyEntries().isEmpty,
                       "precondition: an installed xterm-kitty entry under \(homePath)/.terminfo to delete")

        // Delete the way a user would, and prove (without any app code) that
        // the name is now genuinely unresolvable. Retry once or twice in the
        // unlikely event another process on the machine re-ran `tic` between
        // the move and the check.
        var movedTotal = 0
        var statusAfterDelete: Int32 = 0
        for _ in 0..<3 {
            movedTotal += try removeInstalledKittyEntries()
            statusAfterDelete = try infocmpStatus(for: "xterm-kitty")
            if statusAfterDelete != 0 { break }
        }
        XCTAssertGreaterThan(movedTotal, 0, "precondition: at least one xterm-kitty file was deleted")
        XCTAssertNotEqual(statusAfterDelete, 0,
                          "precondition: after deleting ~/.terminfo/*/xterm-kitty, `infocmp xterm-kitty` must fail (macOS system terminfo has no xterm-kitty); got status \(statusAfterDelete)")
        guard statusAfterDelete != 0 else { return }

        // "Press Cmd-T": a brand new shell, no app relaunch.
        let report = try spawnShellAndReport()
        XCTAssertEqual(report.home, homePath,
                       "precondition: the child must see the HOME whose .terminfo was edited; \(report.summary)")

        XCTAssertEqual(report.infocmpRC, "0",
                       "the TERM handed to a new shell (\(report.term)) must be resolvable by ncurses after the entry was deleted; \(report.summary)")
        XCTAssertEqual(report.tputRC, "0",
                       "`tput cols` in a new tab must not fail with `unknown terminal`; \(report.summary)")
        XCTAssertEqual(report.clearRC, "0",
                       "`clear` in a new tab must not fail with `unknown terminal`; \(report.summary)")
        XCTAssertFalse(report.tputErr.contains("unknown terminal"),
                       "tput stderr must not say `unknown terminal`; \(report.summary)")
    }
}
