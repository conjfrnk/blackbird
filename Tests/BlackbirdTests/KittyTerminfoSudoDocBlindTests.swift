import XCTest
import Foundation

/// Blind regression for mpe-1b: `TERM=xterm-kitty` cannot be resolved by a
/// login shell that runs under ANOTHER account's `HOME` (`sudo -i`, `su -`,
/// `sudo -u other -i`, `login`), and nothing in the repository tells the
/// admin who hits it why, or what to do.
///
/// Background. Every Blackbird tab is spawned with `TERM=xterm-kitty`, which
/// only resolves because the app installs its bundled kitty terminfo into the
/// launching user's `~/.terminfo` (macOS's system terminfo has no
/// `xterm-kitty`). `sudo -i` / `su -` start a login shell whose `HOME` is the
/// target account's, and sudo/su pass `TERM` through unchanged, so inside the
/// elevated shell ncurses looks in a `.terminfo` that has no entry and prints
/// `unknown terminal ...` from `tput`, `clear`, `less` and every curses TUI.
/// A code fix (switching `TERM` per sudo) was tried and was not safe, so the
/// correct resolution is DOCUMENTATION: a findable section in `KNOWN_ISSUES.md`
/// plus a pointer to it from the `KittyTerminfo.swift` header comment.
///
/// Contract under test (what a reader needs, independent of wording):
///   - `KNOWN_ISSUES.md` has a dedicated heading-level section that mentions the
///     error text a reader would grep for (`unknown terminal ...
///     'xterm-kitty'`) together with `sudo`.
///   - It names every affected path: `sudo -i`, `su -`, `sudo -u ...`, `login`.
///   - It explains the cause: the entry is installed only under the launching
///     user's `~/.terminfo`, the other account's `HOME` has none, and the
///     system terminfo has none either.
///   - It says what is NOT affected: the same user's own shells, and `ssh`
///     (whose remote `TERM` defaults to `xterm-256color`).
///   - It lists the workarounds: `export TERM=xterm-256color` before sudo,
///     `sudo TERM=xterm-256color -i`, `sudo -E`, and installing the entry for
///     the other account with `tic -x -o <other home>/.terminfo` from the
///     bundled `kitty.terminfo`.
///   - `KittyTerminfo.swift`'s header comment links to that entry.
///   - The documented cause and the documented tic workaround are TRUE for the
///     real ncurses tools on this machine (a doc that lies is worse than none).
///
/// Wording is deliberately not pinned: requirements are matched as whitespace-
/// and backtick-insensitive literals or small alternations, never whole
/// sentences. Every assertion prints the measured value.
///
/// Cost pre-flight: reads two small text files. The one live test runs
/// `/usr/bin/tic` once and `/usr/bin/infocmp` three times against scratch
/// directories under the temp dir (a few KiB, well under 0.5 s). No window, no
/// Metal, no `MainWindowController`, no PTY, no GUI, nothing touches the real
/// `~/.terminfo` or the real `HOME`.
final class KittyTerminfoSudoDocBlindTests: XCTestCase {

    // MARK: - Rig

    private struct Section {
        let heading: String
        /// Whitespace-collapsed, backtick-stripped, quote-straightened body.
        let body: String
        /// `heading` + `body`, same normalization.
        var all: String { heading + " " + body }
    }

    private struct Requirement {
        let name: String
        /// ICU regular expression, matched against normalized text.
        let pattern: String
        let caseSensitive: Bool

        init(_ name: String, _ pattern: String, caseSensitive: Bool = false) {
            self.name = name
            self.pattern = pattern
            self.caseSensitive = caseSensitive
        }
    }

    private static func lit(_ s: String) -> String {
        NSRegularExpression.escapedPattern(for: s)
    }

    private static func repoRoot(file: String = #filePath) -> URL {
        URL(fileURLWithPath: file)
            .deletingLastPathComponent()  // Tests/BlackbirdTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // repo root
    }

    /// Reads a repo file, failing LOUD (never skipping) when `#filePath`
    /// arithmetic does not reach the source tree.
    private static func readRepoFile(_ relativePath: String) -> String? {
        let url = repoRoot().appendingPathComponent(relativePath)
        guard FileManager.default.fileExists(atPath: url.path) else {
            XCTFail("\(relativePath) not found at \(url.path); #filePath arithmetic no longer reaches the repo root")
            return nil
        }
        do {
            return try String(contentsOf: url, encoding: .utf8)
        } catch {
            XCTFail("could not read \(url.path): \(error)")
            return nil
        }
    }

    /// Collapses all whitespace runs (including line wraps and list
    /// indentation) to one space, drops backticks, straightens curly quotes.
    private static func normalize(_ s: String) -> String {
        var t: String = s.replacingOccurrences(of: "`", with: "")
        t = t.replacingOccurrences(of: "\u{2018}", with: "'")
        t = t.replacingOccurrences(of: "\u{2019}", with: "'")
        t = t.replacingOccurrences(of: "\u{201C}", with: "\"")
        t = t.replacingOccurrences(of: "\u{201D}", with: "\"")
        let parts: [String] = t
            .split(whereSeparator: { (c: Character) -> Bool in c.isWhitespace })
            .map { (sub: Substring) -> String in String(sub) }
        return parts.joined(separator: " ")
    }

    private static func isHeadingLine(_ line: String) -> Bool {
        line.hasPrefix("## ") || line.hasPrefix("### ") || line.hasPrefix("#### ")
    }

    /// Splits a markdown document into flat sections at `##`..`####` headings,
    /// ignoring `#` lines inside code fences.
    private static func parseSections(_ text: String) -> [Section] {
        var sections: [Section] = []
        var heading: String?
        var bodyLines: [String] = []
        var inFence = false
        for line in text.components(separatedBy: "\n") {
            let trimmed: String = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") { inFence.toggle() }
            if !inFence && isHeadingLine(line) {
                if let h = heading {
                    sections.append(Section(heading: normalize(h),
                                            body: normalize(bodyLines.joined(separator: "\n"))))
                }
                let stripped: Substring = line.drop(while: { (c: Character) -> Bool in c == "#" })
                heading = String(stripped).trimmingCharacters(in: .whitespaces)
                bodyLines = []
                continue
            }
            bodyLines.append(line)
        }
        if let h = heading {
            sections.append(Section(heading: normalize(h),
                                    body: normalize(bodyLines.joined(separator: "\n"))))
        }
        return sections
    }

    private static func matches(_ req: Requirement, in text: String) -> Bool {
        var options: String.CompareOptions = [.regularExpression]
        if !req.caseSensitive { options.insert(.caseInsensitive) }
        return text.range(of: req.pattern, options: options) != nil
    }

    /// Names of requirements that `text` does not satisfy.
    private static func missing(_ reqs: [Requirement], in text: String) -> [String] {
        var out: [String] = []
        for req in reqs where !matches(req, in: text) { out.append(req.name) }
        return out
    }

    /// Requirements whose presence identifies "the" sudo section among
    /// several candidates (most satisfied wins).
    private static let identifyingRequirements: [Requirement] = [
        Requirement("sudo -i", lit("sudo -i")),
        Requirement("su -", lit("su -")),
        Requirement("sudo -u", lit("sudo -u")),
        Requirement("unknown terminal", lit("unknown terminal")),
        Requirement("xterm-256color", lit("xterm-256color")),
        Requirement("tic -x -o", lit("tic -x -o")),
        Requirement("kitty.terminfo", lit("kitty.terminfo")),
        Requirement("sudo -E", lit("sudo -E"), caseSensitive: true),
    ]

    /// The KNOWN_ISSUES.md section that deals with `xterm-kitty` under sudo.
    /// With `report`, a missing section is an XCTFail naming what exists.
    private func locateSudoSection(report: Bool = true) -> Section? {
        guard let text = Self.readRepoFile("KNOWN_ISSUES.md") else { return nil }
        let sections: [Section] = Self.parseSections(text)
        var best: Section?
        var bestScore = -1
        for section in sections {
            let hay: String = section.all.lowercased()
            guard hay.contains("sudo"), hay.contains("xterm-kitty") else { continue }
            let score: Int = Self.identifyingRequirements.count
                - Self.missing(Self.identifyingRequirements, in: section.all).count
            if score > bestScore {
                best = section
                bestScore = score
            }
        }
        if best == nil && report {
            let headings: String = sections.map { (s: Section) -> String in s.heading }
                .joined(separator: " | ")
            XCTFail("KNOWN_ISSUES.md has no section that mentions both `sudo` and `xterm-kitty`. "
                    + "A reader who hits `unknown terminal ... 'xterm-kitty'` after `sudo -i` has nothing to find. "
                    + "Existing headings (\(sections.count)): \(headings)")
        }
        return best
    }

    private func excerpt(_ section: Section) -> String {
        "section '\(section.heading)': \(String(section.body.prefix(400)))"
    }

    // MARK: - KNOWN_ISSUES.md content

    /// A reader grepping for the error text or scanning headings must land on
    /// a dedicated section, and that section must carry the error text itself.
    func testKnownIssuesHasDedicatedFindableSectionForXtermKittyUnderSudo() {
        guard let section = locateSudoSection() else { return }

        let headingLower: String = section.heading.lowercased()
        let headingFindable: Bool = ["sudo", "xterm-kitty", "unknown terminal", "su -"]
            .contains { (needle: String) -> Bool in headingLower.contains(needle) }
        XCTAssertEqual(headingFindable, true,
                       "the section heading must name sudo/su/xterm-kitty/the error so it can be found by scanning; heading was '\(section.heading)'")

        let missingText: [String] = Self.missing([
            Requirement("error text 'unknown terminal'", Self.lit("unknown terminal")),
            Requirement("the TERM value 'xterm-kitty'", Self.lit("xterm-kitty")),
            Requirement("the sudo entry point", "\\bsudo\\b"),
        ], in: section.all)
        XCTAssertEqual(missingText, [String](),
                       "section must quote the error a reader would paste into a search; missing \(missingText) in \(excerpt(section))")
    }

    /// Every way of landing in another account's login shell is named.
    func testSectionNamesEveryAffectedLoginPath() {
        guard let section = locateSudoSection() else { return }
        let absent: [String] = Self.missing([
            Requirement("sudo -i", Self.lit("sudo -i")),
            Requirement("su -", Self.lit("su -")),
            Requirement("sudo -u <user> -i", Self.lit("sudo -u")),
            Requirement("login", "\\blogin\\b"),
        ], in: section.all)
        XCTAssertEqual(absent, [String](),
                       "affected entry points not named: \(absent); \(excerpt(section))")
    }

    /// Why it happens: user-only ~/.terminfo + the other account's HOME + no
    /// entry in the system terminfo.
    func testSectionExplainsTheCause() {
        guard let section = locateSudoSection() else { return }
        let absent: [String] = Self.missing([
            Requirement("entry lives in the user's ~/.terminfo", Self.lit(".terminfo")),
            Requirement("the other account's HOME/home directory", "\\bhome\\b"),
            Requirement("the system/macOS terminfo has no entry",
                        "(system|macos).{0,80}terminfo|terminfo.{0,80}(system|macos)|/usr/share/terminfo"),
            Requirement("it is only installed for/under one user or account",
                        "(only|just).{0,80}(user|account|~/\\.terminfo|\\.terminfo)|(other|another|different|target|root).{0,40}(user|account|home)"),
        ], in: section.all)
        XCTAssertEqual(absent, [String](),
                       "cause not explained, missing: \(absent); \(excerpt(section))")
    }

    /// What still works: the same user's shells, and ssh with the default
    /// xterm-256color remote TERM.
    func testSectionStatesWhatIsNotAffected() {
        guard let section = locateSudoSection() else { return }
        let absent: [String] = Self.missing([
            Requirement("an explicit 'not affected / still works' statement",
                        "unaffected|not affected|isn't affected|aren't affected|is not affected|are not affected|does not affect|doesn't affect|still work|keeps? working|works? (fine|normally|as before)|no (problem|issue)"),
            Requirement("the same user's own shells",
                        "same[- ](user|account|login)|own (shells?|tabs?|sessions?|accounts?|home)|current (user|account)|your (own )?(shells?|tabs?|account|user)|normal (tabs?|shells?)|launching user"),
            Requirement("ssh with the default xterm-256color remote TERM",
                        "\\bssh\\b.{0,240}xterm-256color|xterm-256color.{0,240}\\bssh\\b"),
        ], in: section.all)
        XCTAssertEqual(absent, [String](),
                       "'what is not affected' not documented, missing: \(absent); \(excerpt(section))")
    }

    /// The four workarounds, each as a concrete command a reader can paste,
    /// and the file the install workaround points at must really exist.
    func testSectionListsEveryWorkaround() {
        guard let section = locateSudoSection() else { return }
        let absent: [String] = Self.missing([
            Requirement("export TERM=xterm-256color before sudo",
                        Self.lit("export TERM=xterm-256color")),
            Requirement("sudo TERM=xterm-256color -i",
                        Self.lit("sudo TERM=xterm-256color -i")),
            Requirement("sudo -E", Self.lit("sudo -E"), caseSensitive: true),
            Requirement("tic -x -o <other home>/.terminfo",
                        "tic -x -o \\S*\\.terminfo"),
            Requirement("the bundled kitty.terminfo as tic's input",
                        Self.lit("kitty.terminfo")),
            Requirement("Blackbird.app as the place the bundled file lives",
                        "Blackbird\\.app"),
        ], in: section.all)
        XCTAssertEqual(absent, [String](),
                       "workarounds not documented, missing: \(absent); \(excerpt(section))")

        let bundled: URL = Self.repoRoot()
            .appendingPathComponent("Sources/Blackbird/Resources/Terminfo/kitty.terminfo")
        XCTAssertEqual(FileManager.default.fileExists(atPath: bundled.path), true,
                       "precondition: the file the tic workaround names (kitty.terminfo) must still be bundled at \(bundled.path)")
    }

    // MARK: - KittyTerminfo.swift header

    /// The header comment of KittyTerminfo.swift (everything above the
    /// `available` latch) must point at the KNOWN_ISSUES entry.
    func testKittyTerminfoHeaderCommentLinksTheKnownIssuesEntry() {
        guard let source = Self.readRepoFile("Sources/Blackbird/Terminal/KittyTerminfo.swift")
        else { return }

        var commentLines: [String] = []
        var sawLatch = false
        for line in source.components(separatedBy: "\n") {
            if line.contains("static let available") { sawLatch = true; break }
            let trimmed: String = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("//") {
                let stripped: Substring = trimmed.drop(while: { (c: Character) -> Bool in c == "/" || c == "!" })
                commentLines.append(String(stripped))
            }
        }
        XCTAssertEqual(sawLatch, true,
                       "precondition: KittyTerminfo.swift must still declare `static let available`, the end of the header region")
        let header: String = Self.normalize(commentLines.joined(separator: "\n"))

        XCTAssertEqual(header.contains("KNOWN_ISSUES"), true,
                       "KittyTerminfo.swift header comment must reference KNOWN_ISSUES; header was: \(String(header.prefix(500)))")

        // It must say WHICH entry: a topic word, or a quoted heading that
        // matches a real KNOWN_ISSUES.md heading.
        let topical = Requirement(
            "topic",
            "\\bsudo\\b|\\bsu -|login shell|(other|another|different) (account|user|home)")
        var linksTopic = Self.matches(topical, in: header)
        if !linksTopic, let section = locateSudoSection(report: false) {
            let pieces: [String] = header.components(separatedBy: "\"")
            var quoted: [String] = []
            var idx = 1
            while idx < pieces.count {
                quoted.append(pieces[idx])
                idx += 2
            }
            let headingLower: String = section.heading.lowercased()
            linksTopic = quoted.contains { (q: String) -> Bool in
                let ql: String = q.lowercased()
                return ql.count >= 8 && (headingLower.contains(ql) || ql.contains(headingLower))
            }
        }
        XCTAssertEqual(linksTopic, true,
                       "header comment must name the sudo/su/other-account entry (or quote its heading) so the link is actionable; header was: \(String(header.prefix(500)))")
    }

    // MARK: - The documented claims are true

    private struct ToolResult {
        let status: Int32
        let stderr: String
    }

    private static func runTool(_ path: String, _ args: [String], home: URL) -> ToolResult? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: path)
        proc.arguments = args
        // Minimal env: no TERMINFO / TERMINFO_DIRS / TERM leaking from the host.
        proc.environment = ["HOME": home.path, "PATH": "/usr/bin:/bin"]
        let err = Pipe()
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = err
        do {
            try proc.run()
        } catch {
            XCTFail("could not run \(path): \(error)")
            return nil
        }
        let data: Data = err.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        return ToolResult(status: proc.terminationStatus,
                          stderr: String(data: data, encoding: .utf8) ?? "<non-utf8>")
    }

    /// The section's technical claims, checked against the real ncurses tools:
    /// (1) under a HOME with no `.terminfo`, `xterm-kitty` does not resolve
    /// (cause); (2) `xterm-256color` does (workaround 1-3); (3)
    /// `tic -x -o <home>/.terminfo kitty.terminfo` makes `xterm-kitty` resolve
    /// under that HOME (workaround 4). Gated on the section existing so this
    /// only passes once the documentation it vouches for is there.
    func testDocumentedCauseAndInstallWorkaroundHoldForRealNcurses() {
        guard let section = locateSudoSection() else { return }
        XCTAssertEqual(Self.matches(Requirement("tic", "tic -x -o \\S*\\.terminfo"), in: section.all), true,
                       "precondition: the section must document the tic -x -o workaround that this test replays; \(excerpt(section))")

        let fm = FileManager.default
        let scratch: URL = fm.temporaryDirectory
            .appendingPathComponent("bb-sudo-doc-\(UUID().uuidString)", isDirectory: true)
        let otherHome: URL = scratch.appendingPathComponent("other-home", isDirectory: true)
        let emptyHome: URL = scratch.appendingPathComponent("empty-home", isDirectory: true)
        do {
            try fm.createDirectory(at: otherHome, withIntermediateDirectories: true)
            try fm.createDirectory(at: emptyHome, withIntermediateDirectories: true)
        } catch {
            XCTFail("could not create scratch dirs under \(scratch.path): \(error)")
            return
        }
        addTeardownBlock { try? FileManager.default.removeItem(at: scratch) }

        let bundled: URL = Self.repoRoot()
            .appendingPathComponent("Sources/Blackbird/Resources/Terminfo/kitty.terminfo")
        let infocmp = "/usr/bin/infocmp"
        let tic = "/usr/bin/tic"

        // (1) The cause: a HOME with no .terminfo cannot resolve xterm-kitty,
        // and the system terminfo has no fallback.
        guard let before = Self.runTool(infocmp, ["xterm-kitty"], home: emptyHome) else { return }
        XCTAssertNotEqual(before.status, 0,
                          "cause: `infocmp xterm-kitty` under a HOME with no ~/.terminfo must fail (system terminfo has no entry); exit \(before.status), stderr: \(before.stderr)")

        // (2) xterm-256color resolves from the system database under any HOME.
        guard let universal = Self.runTool(infocmp, ["xterm-256color"], home: emptyHome) else { return }
        XCTAssertEqual(universal.status, 0,
                       "workaround TERM=xterm-256color: `infocmp xterm-256color` under an empty HOME must succeed; stderr: \(universal.stderr)")

        // (3) The tic workaround, exactly as documented, installs the entry
        // for the other account.
        guard let installed = Self.runTool(
            tic, ["-x", "-o", otherHome.appendingPathComponent(".terminfo").path, bundled.path],
            home: otherHome)
        else { return }
        XCTAssertEqual(installed.status, 0,
                       "workaround `tic -x -o <other home>/.terminfo kitty.terminfo` must succeed; stderr: \(installed.stderr)")
        guard let after = Self.runTool(infocmp, ["xterm-kitty"], home: otherHome) else { return }
        XCTAssertEqual(after.status, 0,
                       "after the documented tic install, `infocmp xterm-kitty` under that HOME must succeed; stderr: \(after.stderr)")
    }
}
