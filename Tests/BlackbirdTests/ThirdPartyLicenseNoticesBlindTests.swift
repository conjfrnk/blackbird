import XCTest
import Foundation

/// Blind regression for DPC-3: the shipped `Blackbird.app` must carry the
/// third-party license notices that the code and assets it redistributes
/// require, instead of presenting itself as plain MIT.
///
/// Contract (observable behaviour, not implementation):
///   Mounting a release DMG and running
///   `find Blackbird.app -iname '*licen*' -o -iname '*notice*' -o -iname '*credits*'`
///   must find the notices. Three components are redistributed inside the
///   bundle under licenses that oblige the distributor to ship the license
///   text / copyright notice with the binary:
///
///   1. `alacritty_terminal` (statically linked Rust core) is licensed
///      **Apache-2.0 only** (`vendor/alacritty_terminal/Cargo.toml`:
///      `license = "Apache-2.0"`). Apache-2.0 section 4(a): recipients must
///      be given a copy of the License.
///   2. Sparkle.framework (`Contents/Frameworks/Sparkle.framework`) is MIT
///      with the Sparkle authors' copyright line; the MIT condition is that
///      the copyright notice and permission notice ship in all copies.
///   3. Hack Nerd Font Mono (`Contents/Resources/Fonts/*.ttf`) derives from
///      Hack (MIT, Source Foundry Authors) and Bitstream Vera (Bitstream Vera
///      License, which requires the copyright + permission notice to be
///      included in all copies of the font).
///
/// How it measures: the test walks the *built* application bundle (the
/// xctest host's own bundle, found by bundle identifier), skipping the
/// injected `.xctest` bundle so this file's own string literals cannot
/// satisfy the check, and skipping `.ttf/.otf` so the license strings that
/// are embedded in the font's `name` table do not count as a user-visible
/// notice. Every remaining file that is plain UTF-8 text (or RTF / HTML,
/// which are reduced to their text) becomes a candidate notice. A candidate
/// is normalised to lower-case alphanumeric words so markdown/RTF/HTML
/// punctuation, line wrapping and quoting cannot hide a phrase. A
/// component's notice is shipped when at least one single file contains
/// every required phrase for that component; any layout is accepted (one
/// combined `THIRD_PARTY_NOTICES`, `Credits.rtf`, a `Licenses/` folder with
/// one file per component, ...).
///
/// Pre-flight memory/time budget: one walk of an app bundle (~50 files
/// outside Mach-O/font blobs), each file read at most once and capped at
/// 4 MiB, nothing held beyond the few text candidates (< 1 MiB total).
/// No PTYs, no Metal, no windows. Well under 1 s, < 20 MiB peak.
final class ThirdPartyLicenseNoticesBlindTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        TestHostTermination.shared.register()
    }

    // MARK: - Corpus of candidate notice files in the shipped bundle

    private struct CandidateFile {
        /// Path relative to the app bundle root, e.g. "Contents/Resources/X".
        let relativePath: String
        /// Lower-case alphanumeric words joined by single spaces.
        let normalizedText: String
    }

    private struct Corpus {
        let bundleURL: URL
        let candidates: [CandidateFile]
        let visitedRegularFiles: Int
        /// Relative paths of every file in the bundle whose name matches the
        /// exact probe from the bug report (`*licen*`, `*notice*`,
        /// `*credits*`) plus the other conventional names.
        let licenseLikeNames: [String]
    }

    private static let appBundleID = "dev.conjfrnk.blackbird"
    private static let maxCandidateBytes = 4 * 1024 * 1024
    private static let nonTextExtensions: Set<String> = [
        // Fonts carry the Hack/Vera license inside their name table. That is
        // not a notice a user can find, so it must not satisfy the check.
        "ttf", "otf", "ttc", "woff", "woff2",
        "icns", "png", "jpg", "jpeg", "tiff", "pdf", "car", "nib",
        "dylib", "metallib", "a", "o",
    ]

    /// Reduce arbitrary text to lower-case alphanumeric words separated by
    /// single spaces ("Version 2.0, January 2004" -> "version 2 0 january 2004").
    private static func normalize(_ text: String) -> String {
        let words: [String] = text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { (word: String) -> Bool in !word.isEmpty }
        return words.joined(separator: " ")
    }

    private static func plainText(extension ext: String, data: Data) -> String? {
        switch ext {
        case "rtf":
            guard let attributed = NSAttributedString(rtf: data, documentAttributes: nil) else {
                return nil
            }
            return attributed.string
        case "html", "htm", "xhtml":
            guard let raw = String(data: data, encoding: .utf8) else { return nil }
            return raw.replacingOccurrences(
                of: "<[^>]*>", with: " ", options: .regularExpression
            )
        default:
            return String(data: data, encoding: .utf8)
        }
    }

    private static func isLicenseLikeName(_ fileName: String) -> Bool {
        let lowered = fileName.lowercased()
        let needles: [String] = [
            "licen", "notice", "credits", "copying", "acknowledg", "third-party",
            "third_party", "thirdparty", "attribution",
        ]
        return needles.contains { (needle: String) -> Bool in lowered.contains(needle) }
    }

    /// Locate the application bundle under test (the xctest host).
    private static func locateAppBundle() -> Bundle? {
        if Bundle.main.bundleIdentifier == appBundleID { return Bundle.main }
        return Bundle.allBundles.first { (bundle: Bundle) -> Bool in
            bundle.bundleIdentifier == appBundleID
        }
    }

    /// Build the corpus, asserting the preconditions that make the scan
    /// meaningful (right bundle, scanner really reads text resources).
    private func loadCorpus(file: StaticString = #filePath, line: UInt = #line) throws -> Corpus {
        guard let bundle = Self.locateAppBundle() else {
            XCTFail(
                "Could not locate the Blackbird application bundle (id \(Self.appBundleID)) in the test process; bundles seen: \(Bundle.allBundles.compactMap { $0.bundleIdentifier })",
                file: file, line: line
            )
            throw XCTSkip("application bundle not found; failure recorded above")
        }
        let root: URL = bundle.bundleURL
        XCTAssertEqual(
            root.pathExtension, "app",
            "The bundle under scan must be the .app (got \(root.path))",
            file: file, line: line
        )

        let fm = FileManager.default
        var candidates: [CandidateFile] = []
        var visited = 0
        var licenseLike: [String] = []

        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey]
        guard let walker = fm.enumerator(
            at: root, includingPropertiesForKeys: keys, options: [], errorHandler: nil
        ) else {
            XCTFail("Could not enumerate \(root.path)", file: file, line: line)
            throw XCTSkip("enumeration failed; failure recorded above")
        }

        let rootPrefix: String = root.path.hasSuffix("/") ? root.path : root.path + "/"
        while let item = walker.nextObject() as? URL {
            if item.pathExtension == "xctest" {
                // The injected test bundle holds this file's own literals.
                walker.skipDescendants()
                continue
            }
            let relative: String = item.path.hasPrefix(rootPrefix)
                ? String(item.path.dropFirst(rootPrefix.count))
                : item.path
            if Self.isLicenseLikeName(item.lastPathComponent) {
                licenseLike.append(relative)
            }
            guard let values = try? item.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true else { continue }
            visited += 1
            let size: Int = values.fileSize ?? 0
            let ext: String = item.pathExtension.lowercased()
            if size == 0 || size > Self.maxCandidateBytes { continue }
            if Self.nonTextExtensions.contains(ext) { continue }
            guard let data = try? Data(contentsOf: item),
                  let text = Self.plainText(extension: ext, data: data) else { continue }
            candidates.append(
                CandidateFile(relativePath: relative, normalizedText: Self.normalize(text))
            )
        }

        // Scanner sanity: a text resource that project.yml definitely ships
        // must have been read, and no font blob may be among the candidates.
        let candidatePaths: [String] = candidates.map { $0.relativePath }
        XCTAssertEqual(
            candidatePaths.contains("Contents/Resources/osc133.zsh"), true,
            "Scanner precondition: the shipped text resource Contents/Resources/osc133.zsh must be among the \(candidates.count) candidate text files under \(root.path); candidates: \(candidatePaths)",
            file: file, line: line
        )
        XCTAssertEqual(
            candidatePaths.filter { $0.lowercased().hasSuffix(".ttf") },
            [],
            "Fonts must never count as notice candidates",
            file: file, line: line
        )

        return Corpus(
            bundleURL: root, candidates: candidates,
            visitedRegularFiles: visited, licenseLikeNames: licenseLike.sorted()
        )
    }

    // MARK: - Matching

    /// Phrases (any punctuation/case) a single shipped file must contain.
    private struct RequiredNotice {
        let component: String
        let phrases: [String]
    }

    /// Returns the phrases still missing from the best-matching single
    /// candidate (all phrases when no candidate matches any of them). An
    /// empty array means one file carries the complete notice.
    private func missingPhrases(_ notice: RequiredNotice, in corpus: Corpus) -> [String] {
        let wanted: [String] = notice.phrases.map { Self.normalize($0) }
        var best: [String] = notice.phrases
        for candidate in corpus.candidates {
            var missing: [String] = []
            for index in notice.phrases.indices
            where !candidate.normalizedText.contains(wanted[index]) {
                missing.append(notice.phrases[index])
            }
            if missing.count < best.count { best = missing }
        }
        return best
    }

    private func report(_ corpus: Corpus) -> String {
        """
        scanned app bundle: \(corpus.bundleURL.path)
        regular files visited: \(corpus.visitedRegularFiles); text candidates read: \(corpus.candidates.count)
        files with licence/notice/credits-style names (the bug's `find` probe): \(corpus.licenseLikeNames)
        """
    }

    // MARK: - Tests

    /// alacritty_terminal is Apache-2.0 only and is statically linked into
    /// the shipped binary: the Apache License text, attributed to
    /// Alacritty, must ship with the app.
    func test_shippedBundle_carriesAlacrittyTerminalApache2LicenseText() throws {
        // Premise: the vendored crate really is Apache-2.0 (not MIT-dual).
        let manifest = Self.repoRoot()
            .appendingPathComponent("vendor/alacritty_terminal/Cargo.toml")
        let manifestText: String = (try? String(contentsOf: manifest, encoding: .utf8)) ?? ""
        let manifestLines: [String] = manifestText.components(separatedBy: "\n")
        let licenseLine: String = manifestLines.first(where: { (line: String) -> Bool in
            line.hasPrefix("license")
        }) ?? "<no license line>"
        XCTAssertEqual(
            licenseLine.contains("Apache-2.0"), true,
            "Premise: \(manifest.path) must declare Apache-2.0 (saw: \(licenseLine))"
        )

        let corpus = try loadCorpus()
        let notice = RequiredNotice(
            component: "alacritty_terminal (Apache-2.0)",
            phrases: [
                "Apache License",
                "Version 2.0, January 2004",
                "TERMS AND CONDITIONS FOR USE, REPRODUCTION, AND DISTRIBUTION",
                "Alacritty",
            ]
        )
        XCTAssertEqual(
            missingPhrases(notice, in: corpus), [],
            "No single file in the shipped app carries the full Apache-2.0 notice for \(notice.component); phrases missing from the closest candidate are listed.\n\(report(corpus))"
        )
    }

    /// Sparkle.framework ships inside the app; its MIT copyright line and
    /// permission notice must accompany it.
    func test_shippedBundle_carriesSparkleMITCopyrightAndPermissionNotice() throws {
        let corpus = try loadCorpus()
        let sparkle: URL = corpus.bundleURL
            .appendingPathComponent("Contents/Frameworks/Sparkle.framework")
        var isDir: ObjCBool = false
        let embedded: Bool = FileManager.default.fileExists(atPath: sparkle.path, isDirectory: &isDir)
        XCTAssertEqual(
            embedded && isDir.boolValue, true,
            "Premise: Sparkle.framework must be embedded at \(sparkle.path)"
        )

        let notice = RequiredNotice(
            component: "Sparkle (MIT)",
            phrases: [
                "Andy Matuschak",
                "Permission is hereby granted, free of charge",
                "The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software",
            ]
        )
        XCTAssertEqual(
            missingPhrases(notice, in: corpus), [],
            "No single file in the shipped app carries the Sparkle copyright + MIT permission notice; phrases missing from the closest candidate are listed.\n\(report(corpus))"
        )
    }

    /// The bundled Hack Nerd Font Mono is a Hack (MIT) / Bitstream Vera
    /// derivative; both notices must ship in a user-reachable file, not
    /// only inside the font binaries.
    func test_shippedBundle_carriesHackAndBitstreamVeraFontNotices() throws {
        let corpus = try loadCorpus()
        let font: URL = corpus.bundleURL
            .appendingPathComponent("Contents/Resources/Fonts/HackNerdFontMono-Regular.ttf")
        XCTAssertEqual(
            FileManager.default.fileExists(atPath: font.path), true,
            "Premise: the bundled Hack font must exist at \(font.path)"
        )

        let notice = RequiredNotice(
            component: "Hack Nerd Font Mono (Hack MIT + Bitstream Vera)",
            phrases: [
                "Source Foundry Authors",
                "Bitstream Vera",
                "Permission is hereby granted, free of charge",
                "The above copyright and trademark notices and this permission notice shall be included in all copies of one or more of the Font Software typefaces",
            ]
        )
        XCTAssertEqual(
            missingPhrases(notice, in: corpus), [],
            "No single file in the shipped app carries the Hack / Bitstream Vera font notices; phrases missing from the closest candidate are listed.\n\(report(corpus))"
        )
    }

    // MARK: - Helpers

    private static func repoRoot(file: String = #filePath) -> URL {
        URL(fileURLWithPath: file)
            .deletingLastPathComponent()  // BlackbirdTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // repo root
    }
}
