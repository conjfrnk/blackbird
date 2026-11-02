import XCTest
@testable import Blackbird

/// Blind regression tests for MSC-2: dropped-file shell quoting must be
/// safe for arbitrary filesystem paths under EVERY shell Blackbird ships
/// integration for (zsh, bash, fish), not just POSIX sh.
///
/// Contract under test: `PasteSanitizer.shellQuote` / `joinedDroppedPaths`
/// produce text that, when the shell parses it as command-line words,
/// yields exactly the original path(s) as literal arguments and runs
/// nothing else. That contract is checked against the real shells
/// (`fish`, `/bin/sh`, `/bin/bash`, `/bin/zsh`) used as parsing oracles:
/// each case runs `/usr/bin/printf '%s\0' <quoted words>` and compares the
/// NUL-separated argv the shell actually handed to printf with the
/// original path. A command injected through the filename shows up two
/// ways: argv no longer matches, and the injected `touch` leaves a marker
/// file in the per-run scratch directory (cwd of the shell).
///
/// Why fish is the interesting oracle: inside fish single quotes a
/// backslash is an escape character (`\\` -> `\`, `\'` -> `'`), whereas in
/// POSIX sh/bash/zsh a backslash inside single quotes is literal. A quoter
/// that only escapes `'` (as `'\''`) is therefore correct for POSIX but
/// lets a name like `a\' ; touch PWNED #` terminate the quote early under
/// fish and execute the tail as a command.
///
/// Cost: each case spawns one tiny shell process (tens of ms); ~25 spawns
/// total. No PTY, no window controller, no GUI.
final class DroppedPathShellQuoteBlindTests: XCTestCase {

    // MARK: - Hostile and ordinary paths

    /// The exact trigger from the report: backslash directly before a single
    /// quote, then `;`, a command, and a trailing `#` comment.
    private let injectionPath = "/tmp/drop/a\\' ; touch PWNED #"

    /// Two literal backslashes between letters. fish would read `\\` as one.
    private let doubleBackslashPath = "/tmp/drop/a\\\\b"

    /// Ends in a backslash. fish refuses to parse a line that ends inside
    /// an escape within single quotes.
    private let trailingBackslashPath = "/tmp/drop/trailing\\"

    /// A lone backslash before an ordinary letter (control: literal in every
    /// shell, even before any fix).
    private let plainBackslashPath = "/tmp/drop/a\\b c.txt"

    /// Backslash-heavy combinations around single quotes.
    private let quoteBackslashCombos: [String] = [
        "/tmp/drop/a\\'b",
        "/tmp/drop/a'\\b",
        "/tmp/drop/\\'",
        "/tmp/drop/'\\",
        "/tmp/drop/a\\\\'b",
        "/tmp/drop/a\\'\\'b",
        "/tmp/drop/\\",
        "/tmp/drop/\\\\",
    ]

    /// Ordinary metacharacter-laden paths with NO backslash. These were
    /// already safe and must stay safe.
    private let metacharPaths: [String] = [
        "/tmp/drop/plain.txt",
        "/tmp/drop/my image.png",
        "/tmp/drop/don't.txt",
        "/tmp/drop/''two quotes''.txt",
        "/tmp/drop/$HOME $(touch PWNED) `touch PWNED`.txt",
        "/tmp/drop/a;touch PWNED;b|c&d>e<f.txt",
        "/tmp/drop/*?[x]~{a,b}.txt",
        "/tmp/drop/\"dq\" #hash.txt",
    ]

    // MARK: - fish (the bug)

    func testFish_filenameWithBackslashThenQuote_doesNotExecuteTail() throws {
        let fish = try requireFish()
        let run = try parse(shell: fish, words: PasteSanitizer.shellQuote(injectionPath))
        XCTAssertFalse(
            run.injectedMarkerExists,
            "fish executed the tail of a dropped filename: marker file PWNED was created. "
                + describe(run))
        XCTAssertEqual(
            run.argv, [injectionPath],
            "fish must receive the dropped path as ONE literal argument. " + describe(run))
    }

    func testFish_filenameWithDoubleBackslash_roundTripsLiterally() throws {
        let fish = try requireFish()
        let run = try parse(shell: fish, words: PasteSanitizer.shellQuote(doubleBackslashPath))
        XCTAssertEqual(
            run.argv, [doubleBackslashPath],
            "fish must see two literal backslashes, not one (path would point at a different file). "
                + describe(run))
    }

    func testFish_filenameWithTrailingBackslash_parsesAndRoundTrips() throws {
        let fish = try requireFish()
        let run = try parse(shell: fish, words: PasteSanitizer.shellQuote(trailingBackslashPath))
        XCTAssertEqual(
            run.argv, [trailingBackslashPath],
            "a dropped name ending in a backslash must parse under fish and arrive intact. "
                + describe(run))
        XCTAssertEqual(run.status, 0, "fish must not reject the line. " + describe(run))
    }

    func testFish_backslashAndQuoteCombinations_roundTripWithoutInjection() throws {
        let fish = try requireFish()
        for path in quoteBackslashCombos {
            let run = try parse(shell: fish, words: PasteSanitizer.shellQuote(path))
            XCTAssertEqual(
                run.argv, [path],
                "fish round-trip failed for \(String(reflecting: path)). " + describe(run))
            XCTAssertFalse(
                run.injectedMarkerExists, "unexpected side effect for \(String(reflecting: path))")
        }
    }

    func testFish_joinedDroppedPaths_hostileNamesStayThreeSeparateLiteralArguments() throws {
        let fish = try requireFish()
        let paths = [injectionPath, "/tmp/drop/second file.txt", doubleBackslashPath]
        let run = try parse(shell: fish, words: PasteSanitizer.joinedDroppedPaths(paths))
        XCTAssertFalse(
            run.injectedMarkerExists,
            "multi-file drop executed a filename tail under fish. " + describe(run))
        XCTAssertEqual(
            run.argv, paths,
            "a multi-file drop must reach fish as exactly the dropped paths, in order. "
                + describe(run))
    }

    // MARK: - fish controls (already safe; must not regress)

    func testFish_plainBackslashBeforeLetter_roundTripsLiterally() throws {
        let fish = try requireFish()
        let run = try parse(shell: fish, words: PasteSanitizer.shellQuote(plainBackslashPath))
        XCTAssertEqual(
            run.argv, [plainBackslashPath],
            "single backslash before a letter must stay literal under fish. " + describe(run))
    }

    func testFish_metacharacterPathsWithoutBackslash_roundTripLiterally() throws {
        let fish = try requireFish()
        for path in metacharPaths {
            let run = try parse(shell: fish, words: PasteSanitizer.shellQuote(path))
            XCTAssertEqual(
                run.argv, [path],
                "fish round-trip failed for \(String(reflecting: path)). " + describe(run))
            XCTAssertFalse(
                run.injectedMarkerExists,
                "metacharacters in \(String(reflecting: path)) were interpreted by fish")
        }
    }

    // MARK: - POSIX shells (regression guard: a fish fix must not break these)

    func testPOSIXShells_hostileAndOrdinaryPaths_roundTripLiterallyWithoutInjection() throws {
        let shells = try posixShells()
        XCTAssertGreaterThanOrEqual(
            shells.count, 2,
            "need at least /bin/sh and one of bash/zsh as oracles, found \(shells.map(\.path))")
        let all =
            [injectionPath, doubleBackslashPath, trailingBackslashPath, plainBackslashPath]
            + quoteBackslashCombos + metacharPaths
        for shell in shells {
            for path in all {
                let run = try parse(shell: shell, words: PasteSanitizer.shellQuote(path))
                XCTAssertEqual(
                    run.argv, [path],
                    "\(shell.lastPathComponent) round-trip failed for \(String(reflecting: path)). "
                        + describe(run))
                XCTAssertFalse(
                    run.injectedMarkerExists,
                    "\(shell.lastPathComponent) executed part of \(String(reflecting: path))")
            }
        }
    }

    func testPOSIXShells_joinedDroppedPaths_hostileNamesStayLiteralArguments() throws {
        let shells = try posixShells()
        let paths = [injectionPath, "/tmp/drop/second file.txt", doubleBackslashPath, trailingBackslashPath]
        for shell in shells {
            let run = try parse(shell: shell, words: PasteSanitizer.joinedDroppedPaths(paths))
            XCTAssertEqual(
                run.argv, paths,
                "\(shell.lastPathComponent) multi-file round-trip failed. " + describe(run))
            XCTAssertFalse(
                run.injectedMarkerExists, "\(shell.lastPathComponent) executed a filename tail")
        }
    }

    // MARK: - Oracle plumbing

    private struct ShellRun {
        let shell: String
        let line: String
        let argv: [String]
        let stdout: String
        let stderr: String
        let status: Int32
        let injectedMarkerExists: Bool
    }

    private func describe(_ run: ShellRun) -> String {
        "shell=\(run.shell) exit=\(run.status) line=\(String(reflecting: run.line)) "
            + "argv=\(run.argv.map { String(reflecting: $0) }) "
            + "stderr=\(String(reflecting: run.stderr)) markerCreated=\(run.injectedMarkerExists)"
    }

    /// fish is a hard requirement: CI installs it (see `.github/workflows/ci.yml`)
    /// and the whole point of this suite is the fish parsing rules. A silent
    /// skip would turn the regression test vacuous.
    private func requireFish() throws -> URL {
        let candidates = ["/opt/homebrew/bin/fish", "/usr/local/bin/fish", "/usr/bin/fish", "/bin/fish"]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        XCTFail(
            "fish not found in \(candidates). MSC-2 is a fish-parsing regression and cannot be "
                + "verified without it (CI: `brew install fish`).")
        throw XCTSkip("fish unavailable")
    }

    private func posixShells() throws -> [URL] {
        var shells: [URL] = []
        for path in ["/bin/sh", "/bin/bash", "/bin/zsh"]
        where FileManager.default.isExecutableFile(atPath: path) {
            shells.append(URL(fileURLWithPath: path))
        }
        XCTAssertFalse(shells.isEmpty, "no POSIX shell oracle available")
        return shells
    }

    /// Have `shell` parse `words` as the arguments of `/usr/bin/printf '%s\0'`
    /// in a fresh empty scratch directory, and return the argv the shell
    /// produced. `\0` inside the single-quoted printf format is two literal
    /// characters in every shell tested and printf turns it into a NUL
    /// separator, so any filename byte except NUL survives intact.
    private func parse(shell: URL, words: String) throws -> ShellRun {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("bb-msc2-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        let line = "/usr/bin/printf '%s\\0' " + words
        let name = shell.lastPathComponent
        let process = Process()
        process.executableURL = shell
        switch name {
        case "fish": process.arguments = ["--no-config", "-c", line]
        case "zsh": process.arguments = ["-f", "-c", line]
        case "bash": process.arguments = ["--noprofile", "--norc", "-c", line]
        default: process.arguments = ["-c", line]
        }
        var env = ProcessInfo.processInfo.environment
        env["HOME"] = scratch.path
        env["TERM"] = "xterm-256color"
        env.removeValue(forKey: "ENV")
        env.removeValue(forKey: "BASH_ENV")
        process.environment = env
        process.currentDirectoryURL = scratch
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = FileHandle.nullDevice
        try process.run()

        let deadline = Date().addingTimeInterval(5.0)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        if process.isRunning {
            process.terminate()
            Thread.sleep(forTimeInterval: 0.1)
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            XCTFail("\(name) hung parsing \(String(reflecting: line))")
        }
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()

        var fields = outData.split(separator: 0, omittingEmptySubsequences: false)
        if let last = fields.last, last.isEmpty { fields.removeLast() }
        let argv = fields.map { String(decoding: $0, as: UTF8.self) }
        let marker = scratch.appendingPathComponent("PWNED").path
        return ShellRun(
            shell: name,
            line: words,
            argv: argv,
            stdout: String(decoding: outData, as: UTF8.self),
            stderr: String(decoding: errData, as: UTF8.self),
            status: process.terminationStatus,
            injectedMarkerExists: FileManager.default.fileExists(atPath: marker))
    }
}
