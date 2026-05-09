import XCTest
@testable import Blackbird

/// Architectural-boundary pin: Blackbird does NOT use the macOS keychain
/// directly. Sparkle has its own keychain machinery (managed inside the
/// Sparkle.framework bundle, not in our source tree) for its EdDSA
/// signature handling and update-token storage; that's a third-party
/// concern. Blackbird's own code stays decoupled.
///
/// Why this matters for v1.0 hostile environments:
///   1. Keychain access can fail with `errSecAuthFailed`, `errSecNoSuchKeychain`,
///      `errSecInteractionNotAllowed`, or — in the worst case — a UI prompt
///      if `kSecAccessControlUserPresence` is invoked from a non-foreground
///      context. Each path is a distinct failure mode that needs a graceful-
///      degradation policy. We don't want any of them.
///   2. A future contributor adding "store something in the keychain"
///      without a fallback path is a launch-blocker for a user whose
///      keychain is locked, sandboxed off, or — a real audit case — whose
///      `Local Items` chain has rotated out from under them.
///   3. Coupling Blackbird to the keychain means our test discipline has
///      to grow a "skip if no keychain" mode, an entitlement, and a
///      provisioning path. Today none of those exist, and the source pin
///      below is what keeps it that way.
///
/// This is a SOURCE-PIN test, not a behavioural test:
///   - We grep the running source tree for `import Security`,
///     `SecKeychain*`, `SecItem*`, and `kSec*` symbol references.
///   - The expectation is ZERO matches inside `Sources/Blackbird` and
///     `Sources/BBCore` (Sparkle.framework's own sources are owned by
///     the Sparkle SwiftPM dependency and are NOT scanned — they live
///     under DerivedData on a contributor's machine).
///   - If a future change introduces direct keychain access, this test
///     fails LOUD with the offending file + line, and the contributor
///     has to either (a) remove the keychain dependency, or (b) update
///     this test in the same commit and add the graceful-degradation
///     policy the audit demands. Either path is fine; silent drift is
///     not.
///
/// Memory pre-flight: this test reads up to ~600 KB of source text into
/// memory (the entire Sources/Blackbird tree at ~2026-05-09 is ~480 KB
/// of `.swift` + `.h` files; we add 20% headroom for growth) and runs a
/// substring scan over each file. < 1 MB peak RSS, < 200 ms wall.
/// No PTY, no Metal, no UserDefaults, no shells.
final class KeychainCouplingTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        TestHostTermination.shared.register()
    }

    /// Symbols whose appearance in our source tree means a direct
    /// coupling to the macOS Security framework / keychain. Each is a
    /// substring match — these are public API names that don't appear
    /// in normal English, so false positives are extremely unlikely.
    /// If a false positive ever does appear (e.g. in a doc-comment or
    /// a test fixture), the right fix is to rephrase the comment, not
    /// to special-case it here — we want this test to be a tripwire,
    /// not a forgiving filter.
    private static let forbiddenSymbols: [String] = [
        // The Security framework itself — importing it is the canonical
        // first step toward any keychain coupling.
        "import Security",
        // Legacy keychain APIs (deprecated since 10.10 but still link).
        "SecKeychainCreate",
        "SecKeychainOpen",
        "SecKeychainCopyDefault",
        "SecKeychainItemCopyContent",
        "SecKeychainItemFreeContent",
        "SecKeychainAddInternetPassword",
        "SecKeychainAddGenericPassword",
        "SecKeychainFindGenericPassword",
        "SecKeychainFindInternetPassword",
        // Modern SecItem* APIs — kSecClass-keyed dictionaries.
        "SecItemCopyMatching",
        "SecItemAdd",
        "SecItemUpdate",
        "SecItemDelete",
        // The kSec* constants — referencing any of these implies a
        // keychain-shaped query dictionary.
        "kSecClass",
        "kSecAttrService",
        "kSecAttrAccount",
        "kSecValueData",
        "kSecReturnData",
        "kSecReturnAttributes",
        "kSecMatchLimit",
        // Access-control surfaces.
        "SecAccessControlCreate",
        "kSecAccessControl",
        // Keys / certificates / trust — the broader Security surface.
        "SecKeyCreateRandomKey",
        "SecKeyCreateSignature",
        "SecKeyVerifySignature",
        "SecCertificateCreate",
        "SecTrustCreate",
        "SecTrustEvaluate",
    ]

    /// Walk to the repo root from this test file, then enumerate every
    /// source file under `Sources/Blackbird` and `Sources/BBCore`.
    /// `Sources/Renderer` is included too — it ships our Metal shader
    /// host code, which in principle could reach the keychain (e.g. for
    /// a hypothetical shader-cache encryption key). We pin all three.
    ///
    /// Sparkle is a SwiftPM dependency — its sources live under
    /// `~/Library/Developer/Xcode/DerivedData/.../SourcePackages/checkouts/Sparkle`,
    /// NOT under our `Sources/`. So `Sources/` enumeration won't reach
    /// Sparkle's keychain code. Confirming the boundary.
    private func scannedSourceDirectories(file: String = #filePath) throws -> [URL] {
        let repoRoot = URL(fileURLWithPath: file)
            .deletingLastPathComponent()  // BlackbirdTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // <repo>
        let dirs = [
            repoRoot.appendingPathComponent("Sources/Blackbird"),
            repoRoot.appendingPathComponent("Sources/BBCore"),
            repoRoot.appendingPathComponent("Sources/Renderer"),
        ]
        for dir in dirs {
            guard FileManager.default.fileExists(atPath: dir.path) else {
                throw XCTSkip("Source directory \(dir.path) not present; repo layout drift?")
            }
        }
        return dirs
    }

    /// Recursively enumerate `.swift`, `.h`, `.m`, `.mm`, and `.c` files
    /// under each scanned directory. We scan headers and Obj-C/C files
    /// because the keychain APIs are C — a contributor reaching for
    /// them might do so from a `.h` or a bridging file rather than
    /// pure Swift.
    private func sourceFiles(under directory: URL) -> [URL] {
        let acceptedExtensions: Set<String> = ["swift", "h", "m", "mm", "c"]
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        var out: [URL] = []
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey])
            guard values?.isRegularFile == true else { continue }
            guard acceptedExtensions.contains(url.pathExtension.lowercased()) else { continue }
            out.append(url)
        }
        return out
    }

    /// THE pin: zero forbidden-symbol matches across the scanned tree.
    /// If this fails, Blackbird has grown a direct keychain dependency.
    /// Either (a) remove it and keep the boundary intact, or (b) update
    /// the audit and this test together — adding the graceful-degradation
    /// policy that hostile-keychain failure modes demand.
    func testNoDirectKeychainCouplingInBlackbirdSources() throws {
        // Memory: ~1 MB peak (read all source files into String buffers
        // sequentially; each is dropped before the next is loaded).
        // Wall: ~200 ms on a warm filesystem.
        let dirs = try scannedSourceDirectories()
        var offenders: [(URL, String, String)] = []  // file, snippet, symbol
        // Files that hit the stripper's known-gap patterns AND a
        // forbidden symbol within ~200 chars. The stripper would
        // misclassify these (raw / triple-quoted / nested-block
        // patterns), so we escalate co-occurrence into a manual-
        // inspection failure rather than trusting the strip pass.
        var stripperGapOffenders: [(URL, String, String)] = []
            // file, gap-pattern, nearby-symbol

        for dir in dirs {
            for file in sourceFiles(under: dir) {
                guard let body = try? String(contentsOf: file, encoding: .utf8) else {
                    // A non-UTF8 file in our source tree would itself be
                    // a problem; skipping is defensible because every
                    // shipping `.swift`/`.h` is UTF-8. If a future binary
                    // resource lands in `Sources/`, sourceFiles' extension
                    // filter would already exclude it.
                    continue
                }
                // Strip line comments and block comments BEFORE the
                // substring scan so a doc-comment that mentions a
                // forbidden symbol (e.g. "Sparkle owns its SecItem*
                // interactions") doesn't trip the gate. Tests are
                // about real symbol references, not English prose.
                let stripped = Self.stripComments(from: body)
                for symbol in Self.forbiddenSymbols where stripped.contains(symbol) {
                    // Capture the first non-comment line containing the
                    // symbol so the failure message points the
                    // contributor at the exact spot.
                    let snippet = Self.firstLineContaining(symbol, in: stripped) ?? "<unknown>"
                    offenders.append((file, snippet, symbol))
                }
                // Stripper-gap sweep: scan the RAW (un-stripped) body
                // for the limitation patterns near a forbidden symbol.
                // Co-occurrence within ~200 chars means the stripper's
                // misclassification might either hide a real coupling
                // (nested comments) or surface a false positive (raw /
                // triple-quoted strings) — either way, manual review
                // is the correct escalation.
                Self.collectStripperGapOffenders(
                    in: body, file: file, into: &stripperGapOffenders
                )
            }
        }

        XCTAssertTrue(
            offenders.isEmpty,
            """
            ARCHITECTURAL BOUNDARY VIOLATED — Blackbird is now coupled to the macOS keychain.

            Found \(offenders.count) forbidden symbol reference(s) in \
            non-comment source under Sources/{Blackbird,BBCore,Renderer}:

            \(offenders.map { (file, snippet, symbol) in
                "  - \(file.path)\n    matches `\(symbol)` in: \(snippet.trimmingCharacters(in: .whitespaces))"
            }.joined(separator: "\n"))

            Sparkle owns its own keychain interactions inside the framework; \
            Blackbird must NOT have a direct dependency. Either:
              (a) Remove the coupling and keep this test green.
              (b) Update this test in the same commit and add a graceful-degradation \
                  policy for keychain failures: errSecAuthFailed, errSecInteractionNotAllowed, \
                  errSecNoSuchKeychain. The hostile-environment audit (v1.0 launch) \
                  requires both.
            """
        )

        // The failure message describes raw / triple-quoted / nested-comment
        // patterns; we build it via concatenation so the `"""` and `#"…"#`
        // tokens we discuss don't terminate the multi-line literal.
        let gapHeader = "STRIPPER-GAP CO-OCCURRENCE — KeychainCouplingTests' "
            + "comment stripper has known gaps for raw strings, triple-quoted "
            + "strings, and nested block comments. One or more Sources files "
            + "contain a limitation pattern AND a forbidden symbol within "
            + "~200 chars; the stripper may have misclassified the symbol's "
            + "context."
        let gapOffenderList = stripperGapOffenders.map { entry -> String in
            let (file, pattern, symbol) = entry
            return "  - \(file.path)\n    pattern `\(pattern)` near symbol `\(symbol)`"
        }.joined(separator: "\n")
        let gapFooter = "For each: confirm the forbidden symbol is NOT a "
            + "real keychain coupling — i.e. it lives inside a doc-comment "
            + "/ string fixture / test scaffolding the stripper can't see. "
            + "If the symbol IS a real coupling, this test passing or failing "
            + "on the main scan is irrelevant: the architectural boundary is "
            + "violated regardless. If it's not, either rewrite the source "
            + "to avoid the limitation pattern, or extend the stripper "
            + "(non-trivial Swift-lexer reimplementation — see the doc "
            + "comment on `stripComments`)."
        XCTAssertTrue(
            stripperGapOffenders.isEmpty,
            gapHeader + "\n\nManual inspection required for:\n\n"
                + gapOffenderList + "\n\n" + gapFooter
        )
    }

    /// Look for raw strings (`#"`), triple-quoted strings (`"""`), and
    /// nested block comments (`/*` followed by another `/*` before a
    /// `*/`) in `body`, and for each occurrence emit an entry in
    /// `out` if any forbidden symbol appears within ±200 chars.
    /// Window-based co-occurrence is sufficient because real keychain
    /// coupling would always have the symbol on the same logical line
    /// or two; we err generous to avoid missing edge cases.
    static func collectStripperGapOffenders(
        in body: String,
        file: URL,
        into out: inout [(URL, String, String)]
    ) {
        // O(n) scan: walk forbidden-symbol positions, then check
        // whether each one is within window of any limitation
        // pattern. Keeps the worst case bounded to source-tree size
        // (~600 KB) per the file header pre-flight.
        let nsBody = body as NSString
        let totalLength = nsBody.length
        let window = 200
        // Limitation patterns. Order matters: the "nested block"
        // pattern is `/*` followed by another `/*` with no
        // intervening `*/`, but a substring check is good enough
        // for the heuristic — a co-occurrence escalates to manual
        // review regardless of the exact regex shape.
        let limitationPatterns: [String] = [
            #"#""#,        // raw string opener (#"…"#)
            "\"\"\"",      // triple-quoted string
        ]
        // Find all symbol occurrences once.
        var symbolHits: [(range: NSRange, symbol: String)] = []
        for symbol in Self.forbiddenSymbols {
            var searchRange = NSRange(location: 0, length: totalLength)
            while searchRange.location < totalLength {
                let r = nsBody.range(of: symbol, options: [], range: searchRange)
                if r.location == NSNotFound { break }
                symbolHits.append((r, symbol))
                let nextLoc = r.location + r.length
                searchRange = NSRange(
                    location: nextLoc,
                    length: max(0, totalLength - nextLoc)
                )
            }
        }
        guard !symbolHits.isEmpty else { return }

        // Substring-pattern occurrences for the simple cases.
        for pattern in limitationPatterns {
            var searchRange = NSRange(location: 0, length: totalLength)
            while searchRange.location < totalLength {
                let r = nsBody.range(of: pattern, options: [], range: searchRange)
                if r.location == NSNotFound { break }
                let lowerBound = max(0, r.location - window)
                let upperBound = min(totalLength, r.location + r.length + window)
                for hit in symbolHits where
                    hit.range.location >= lowerBound &&
                    hit.range.location < upperBound
                {
                    out.append((file, pattern, hit.symbol))
                }
                let nextLoc = r.location + r.length
                searchRange = NSRange(
                    location: nextLoc,
                    length: max(0, totalLength - nextLoc)
                )
            }
        }

        // Nested-block-comment heuristic: scan for `/*` whose
        // following `*/` is preceded (within the same comment span)
        // by a second `/*`. We approximate by finding any `/*` that
        // appears strictly inside another open block (i.e. between an
        // unmatched `/*` and its first `*/`). A substring sweep
        // suffices — false positives here just escalate to manual
        // inspection, which is the desired behaviour.
        var idx = 0
        while idx < totalLength {
            let openRange = nsBody.range(
                of: "/*",
                options: [],
                range: NSRange(location: idx, length: totalLength - idx)
            )
            if openRange.location == NSNotFound { break }
            let afterOpen = openRange.location + openRange.length
            let closeSearch = NSRange(
                location: afterOpen,
                length: totalLength - afterOpen
            )
            let closeRange = nsBody.range(of: "*/", options: [], range: closeSearch)
            if closeRange.location == NSNotFound { break }
            // Look for a SECOND `/*` strictly between openRange's
            // end and closeRange's start.
            let innerSearch = NSRange(
                location: afterOpen,
                length: closeRange.location - afterOpen
            )
            if innerSearch.length > 0 {
                let innerOpen = nsBody.range(
                    of: "/*", options: [], range: innerSearch
                )
                if innerOpen.location != NSNotFound {
                    let lowerBound = max(0, openRange.location - window)
                    let upperBound = min(
                        totalLength, closeRange.location + closeRange.length + window
                    )
                    for hit in symbolHits where
                        hit.range.location >= lowerBound &&
                        hit.range.location < upperBound
                    {
                        out.append((file, "/* /* */ */", hit.symbol))
                    }
                }
            }
            idx = closeRange.location + closeRange.length
        }
    }

    // MARK: - Comment stripping

    /// Remove `// …` line comments and `/* … */` block comments from a
    /// source string before the substring scan. This is a textbook
    /// Swift/C lexer pass written by hand because (a) there's no
    /// stdlib helper, (b) we don't want to pull in a dependency for a
    /// 30-line state machine, and (c) the existing
    /// `DiagnosticsView.sanitize(_:)` does control-char stripping but
    /// not comment stripping.
    ///
    /// KNOWN GAPS — DO NOT FIX BY GROWING THE LEXER. Each of these is
    /// pinned by a self-test below (`test_stripComments_doesNot…`)
    /// that asserts the CURRENT (limited) behaviour. The test names
    /// document the limitation; the runtime sweep in
    /// `testNoDirectKeychainCouplingInBlackbirdSources` then escalates
    /// any source file that uses one of these patterns NEAR a
    /// forbidden symbol into a loud false-positive.
    ///
    ///   1. Swift raw string literals (`#"…"#`, `##"…"##`, …):
    ///      The stripper has NO `#` awareness. A forbidden symbol
    ///      inside `#"import Security"#` survives the strip pass and
    ///      would trip the gate. (Right answer: such a string is
    ///      suspicious; flag it for manual inspection.)
    ///   2. Triple-quoted strings (`"""…"""`):
    ///      The stripper toggles state on each `"`, so a triple-quoted
    ///      string opens, closes, re-opens, etc. across its three
    ///      delimiters. Net effect: the body of a `"""…"""` is treated
    ///      as code by the stripper, even though the Swift compiler
    ///      sees a single string literal. A forbidden symbol inside a
    ///      `"""…"""` survives → false positive on the gate.
    ///   3. Nested block comments (`/* /* */ */`):
    ///      The stripper exits the outer block on the FIRST `*/`,
    ///      treating everything after as code. A forbidden symbol
    ///      between the inner `*/` and the outer `*/` would leak →
    ///      false NEGATIVE (gate fails to catch a real coupling).
    ///
    /// We accept the gaps because (a) the symbols we forbid are
    /// public-API C names, unlikely to appear in raw/triple/nested
    /// string-or-comment fixtures in real Blackbird code, and (b) the
    /// runtime sweep below escalates any co-occurrence into a loud
    /// failure that forces manual inspection. Growing the lexer to a
    /// full Swift-compatible state machine for these corners is a
    /// non-trivial engineering investment, paid for by zero current
    /// false positives or negatives in our actual source tree.
    static func stripComments(from source: String) -> String {
        enum State { case code, slash, lineComment, blockComment, blockCommentStar, string, stringEscape, charLit, charLitEscape }
        var state: State = .code
        var out = ""
        out.reserveCapacity(source.count)
        for ch in source {
            switch state {
            case .code:
                if ch == "/" {
                    state = .slash
                } else if ch == "\"" {
                    out.append(ch)
                    state = .string
                } else if ch == "'" {
                    out.append(ch)
                    state = .charLit
                } else {
                    out.append(ch)
                }
            case .slash:
                if ch == "/" {
                    state = .lineComment
                } else if ch == "*" {
                    state = .blockComment
                } else {
                    // The slash wasn't a comment opener; emit it now
                    // along with the current char.
                    out.append("/")
                    out.append(ch)
                    state = .code
                }
            case .lineComment:
                if ch == "\n" {
                    out.append(ch)  // preserve the newline so line
                                    // numbers in firstLineContaining
                                    // stay aligned with the original.
                    state = .code
                }
                // else: drop the comment char
            case .blockComment:
                if ch == "*" {
                    state = .blockCommentStar
                } else if ch == "\n" {
                    out.append(ch)  // preserve newlines for line alignment
                }
                // else: drop the comment char
            case .blockCommentStar:
                if ch == "/" {
                    state = .code
                } else if ch == "*" {
                    // stay in star — could be `**/`
                    state = .blockCommentStar
                } else if ch == "\n" {
                    out.append(ch)
                    state = .blockComment
                } else {
                    state = .blockComment
                }
            case .string:
                out.append(ch)
                if ch == "\\" {
                    state = .stringEscape
                } else if ch == "\"" {
                    state = .code
                }
            case .stringEscape:
                out.append(ch)
                state = .string
            case .charLit:
                out.append(ch)
                if ch == "\\" {
                    state = .charLitEscape
                } else if ch == "'" {
                    state = .code
                }
            case .charLitEscape:
                out.append(ch)
                state = .charLit
            }
        }
        return out
    }

    /// First non-comment line that contains `symbol`. Used purely for
    /// constructing the failure message so a tripped test points at the
    /// exact source location.
    static func firstLineContaining(_ symbol: String, in source: String) -> String? {
        for line in source.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.contains(symbol) {
                return String(line)
            }
        }
        return nil
    }

    // MARK: - Self-test for the comment stripper
    //
    // The stripper is non-trivial; a regression there would silently
    // weaken the gate above. Pin its key invariants here.

    func testStripComments_removesLineCommentsButPreservesNewlines() {
        let input = "let x = 1 // import Security\nlet y = 2"
        let output = Self.stripComments(from: input)
        XCTAssertFalse(
            output.contains("import Security"),
            "stripComments must remove line-comment contents"
        )
        XCTAssertTrue(
            output.contains("let x = 1"),
            "stripComments must preserve code on the line"
        )
        XCTAssertTrue(
            output.contains("\n"),
            "stripComments must preserve newlines for line alignment"
        )
    }

    func testStripComments_removesBlockComments() {
        let input = "let a = 1 /* import Security */ let b = 2"
        let output = Self.stripComments(from: input)
        XCTAssertFalse(
            output.contains("import Security"),
            "stripComments must remove block-comment contents"
        )
    }

    func testStripComments_preservesStringLiterals() {
        // A Swift String literal that LOOKS like a forbidden symbol must
        // NOT be stripped — the test would otherwise miss real keychain
        // string constants in code (though we don't expect any).
        let input = #"let s = "import Security""#
        let output = Self.stripComments(from: input)
        XCTAssertTrue(
            output.contains("import Security"),
            "stripComments must NOT strip contents inside string literals"
        )
    }

    func testStripComments_doesNotStripDivisions() {
        // A bare `/` (division operator, not a comment opener) must
        // survive. Without this, code like `let r = a / b` would
        // become `let r = a  b` — meaningless to the substring scan
        // but still incorrect.
        let input = "let r = a / b"
        let output = Self.stripComments(from: input)
        XCTAssertEqual(
            output, "let r = a / b",
            "stripComments must preserve a bare slash that isn't a comment opener"
        )
    }

    // MARK: - Documented stripper limitations
    //
    // Each of these tests asserts the CURRENT (limited) behaviour of
    // the stripper. They document — in test names + assertion
    // messages — that the stripper does NOT understand the listed
    // Swift syntax. The runtime sweep in
    // `testNoDirectKeychainCouplingInBlackbirdSources` escalates any
    // co-occurrence of these patterns with a forbidden symbol into a
    // loud manual-inspection failure. Together they convert a silent
    // gap into a documented + observable boundary.

    /// LIMITATION 1: Swift raw string literals (`#"…"#`).
    ///
    /// Swift accepts `#"…"#`, `##"…"##`, … as raw string delimiters.
    /// The stripper has no `#` awareness; it sees the leading `#`
    /// followed by `"`, treats the `"` as a normal-string opener,
    /// and toggles state on each subsequent `"`. As a result a
    /// forbidden symbol inside a raw string survives the strip pass.
    /// Pin this so a future "fix the stripper" rewrite can't quietly
    /// regress: the limitation is a feature, not a bug, and the
    /// runtime sweep is what makes it safe.
    func test_stripComments_doesNotHandleRawStrings_documentedLimitation() {
        // We can't write `#"import Security"#` as a Swift literal
        // here because Swift would parse it as a raw string. Build
        // the input character-by-character so the stripper sees a
        // raw-string OPENER followed by a forbidden symbol inside.
        let input = "let s = \u{23}\"import Security\"\u{23}"
        // Sanity-check the constructed input is actually a raw-
        // string-shaped string at the source level.
        XCTAssertTrue(
            input.contains("#\"import Security\"#"),
            "test fixture must contain the raw-string delimiter pair"
        )
        let output = Self.stripComments(from: input)
        XCTAssertTrue(
            output.contains("import Security"),
            """
            DOCUMENTED LIMITATION: stripComments does not handle Swift raw \
            string literals (#"…"#). The forbidden symbol survived the strip \
            pass — if a Sources file ever contains `#"import Security"#` as \
            a raw string fixture (vanishingly unlikely in real Blackbird code, \
            but possible in test scaffolding or doc-string examples), the main \
            gate would surface a false positive. The runtime stripper-gap sweep \
            in `testNoDirectKeychainCouplingInBlackbirdSources` is the defence \
            of last resort. See the doc comment on `stripComments`.
            """
        )
    }

    /// LIMITATION 2: Triple-quoted strings (`"""…"""`).
    ///
    /// The state machine toggles on each `"`. A triple-quoted
    /// opener `"""` is seen as: enter-string on the first `"`, exit-
    /// string on the second, re-enter on the third. Whatever appears
    /// between the opening and closing `"""` is treated by the
    /// stripper as code, so a forbidden symbol inside a multi-line
    /// triple-quoted block survives.
    func test_stripComments_doesNotHandleTripleQuotedStrings_documentedLimitation() {
        // Constructed so the stripper's state machine ends up
        // treating `import Security` as code, not as a string body.
        let input = "let s = \"\"\"\nimport Security\n\"\"\""
        let output = Self.stripComments(from: input)
        // For this constructed fixture, whether the symbol survives
        // depends on the exact `"` pairing. The stripper toggles
        // on each `"` so the body between the opening triple and
        // closing triple is treated as code (not as a single string
        // literal). The point of THIS test is to prove the stripper
        // doesn't have triple-quote awareness — the assertion below
        // pins what it actually does, NOT a contract about what
        // it should do.
        // Build the message via concatenation: a `"""` literal inside a
        // `"""…"""` literal would close the outer one, so we splice
        // single-line strings instead.
        let limitation2Message = "DOCUMENTED LIMITATION: stripComments toggles "
            + "state on each single `\"` and does not understand the triple-"
            + "quote pattern as a single literal. For a Sources file with a "
            + "forbidden symbol inside a triple-quoted block (e.g. a multi-"
            + "line message string referencing keychain APIs), the gate "
            + "surfaces a false positive. Runtime sweep is the defence."
        XCTAssertTrue(
            output.contains("import Security"),
            limitation2Message
        )
    }

    /// LIMITATION 3: Nested block comments (`/* /* */ */`).
    ///
    /// Swift permits nested block comments. The stripper treats
    /// block comments flat — it exits on the FIRST `*/`, returning
    /// to code state. A forbidden symbol between the inner closing
    /// `*/` and the outer closing `*/` would leak through as code,
    /// causing a false NEGATIVE: a real keychain coupling embedded
    /// inside an outer comment would NOT trip the gate.
    func test_stripComments_doesNotHandleNestedBlockComments_documentedLimitation() {
        // Build a nested-comment input where the outer comment
        // brackets a real `import Security` AFTER an inner `*/`.
        // The stripper exits on the first `*/`, treats the rest as
        // code, and `import Security` survives.
        let input = "let a = 1 /* outer /* inner */ import Security */ let b = 2"
        let output = Self.stripComments(from: input)
        XCTAssertTrue(
            output.contains("import Security"),
            """
            DOCUMENTED LIMITATION: stripComments treats block comments flat \
            and exits on the first `*/`. A forbidden symbol between the inner \
            `*/` and the outer `*/` of a nested block comment SURVIVES the strip \
            pass — which means the gate would FAIL on it (loud false positive, \
            forces inspection). The opposite asymmetry — a forbidden symbol \
            inside the inner comment's body — would still get stripped because \
            the inner comment's body is dropped before the inner `*/` is seen. \
            Either way, no nested-comment-with-forbidden-symbol pattern can \
            exist in Blackbird sources without a manual review.
            """
        )
    }
}
