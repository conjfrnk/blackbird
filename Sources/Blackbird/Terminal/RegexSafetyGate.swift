import Foundation

/// Cheap pre-compile gate that rejects the standard first-order ReDoS pattern
/// shapes before a find query is handed to `NSRegularExpression` (which has no
/// match-timeout API, so `(a+)+$` on a long row can backtrack for seconds on
/// the main thread). Extracted verbatim from `TerminalView.isReasonableRegexPattern`
/// (REFACTOR.md Part IV) — a pure, `self`-free validator that belongs in its own
/// testable seam, not on a 3,000-line NSView.
///
/// These checks are not exhaustive — a determined adversary can sidestep the
/// heuristics — but they knock out the textbook cases without false-positiving
/// on ordinary find queries. The 250 ms background-execution timeout in the
/// find engine is the real backstop; this is the cheap first line of defence.
/// Polynomial blowups with no nested quantifier (`.*.*.*.*.*x`, five adjacent
/// quantifiers) pass the gate on purpose: rejecting them would reject real
/// queries, so the scan itself is interruptible mid-row instead.
/// The length cap keeps the find field a "substring with options" UI, not a
/// regex playground. Audit findbar-selection F2.
enum RegexSafetyGate {
    /// True when `pattern` is safe enough to compile and run. See the type doc
    /// for the threat model and the (deliberately non-exhaustive) coverage.
    static func isReasonable(_ pattern: String) -> Bool {
        if pattern.count > 256 { return false }
        // Normalise non-capturing groups so `(?:a+)+` trips the same
        // substring checks as `(a+)+`. Keep the original around for the
        // alternation regex below — stripping the `?:` doesn't change
        // the topology of `(...|...)`.
        let normalised = pattern.replacingOccurrences(of: "(?:", with: "(")
        let dangerous = [
            "(.*)+", "(.+)+", "(.*)*", "(.+)*",
            "(a+)+", "(a*)*", "(a+)*", "(a*)+",
            "([^x]+)+", "([^x]*)*",
            "(\\w+)+", "(\\w*)*", "(\\d+)+", "(\\d*)*",
            "(\\s+)+", "(\\s*)*",
            "(.+)+$", "(.*)+$",
        ]
        for shape in dangerous where normalised.contains(shape) {
            return false
        }
        // Also strip one extra layer of grouping so `(((a+)))+` reduces
        // to `((a+))+` → `(a+)+`. Iterate a few times: in practice nobody
        // legitimately wraps a quantified atom in five layers of parens,
        // and bounded iteration keeps this O(n).
        var stripped = normalised
        for _ in 0..<5 {
            let next = stripped.replacingOccurrences(of: "((", with: "(")
                .replacingOccurrences(of: "))", with: ")")
            if next == stripped { break }
            stripped = next
        }
        for shape in dangerous where stripped.contains(shape) {
            return false
        }
        // Alternation inside a quantified group — `(a|aa)+`, `(x|xx)*`,
        // `(a|aa|aaa)+` — is the second textbook ReDoS class (overlapping
        // alternatives). The pattern matches `( <stuff> | <stuff> ) [+*]`
        // with no nested parens. The earlier shape used `[^()|]*` for
        // the branches, which required EXACTLY ONE `|` and silently let
        // 3+ way alternations slip past the gate (audit S3-003). The
        // body class is now `[^()]+` so the gate fires on any number of
        // `|` separators while still permitting non-alternating groups
        // (`(abc)+`, `(?:foo)+`) and rejecting nested parens.
        if let altRe = try? NSRegularExpression(
            pattern: #"\([^()]+\|[^()]+\)\s*[+*]"#,
            options: []
        ) {
            let ns = pattern as NSString
            if altRe.firstMatch(in: pattern, options: [], range: NSRange(location: 0, length: ns.length)) != nil {
                return false
            }
        }
        // Audit M4. Group whose body contains a quantifier (`+`, `*`,
        // or a brace `{n,…}`) AND is followed by another quantifier
        // is the same exponential-backtrack class as `(a+)+` —
        // `(a{1,})+`, `(.+){2,5}`, `(\w*){1,3}` etc. all fall here.
        // The substring list above only catches the bare-quantifier
        // form; the brace form was the documented gap.
        // Body restriction `[^()]*` keeps this O(n) without nested
        // backtracking. Non-capturing groups `(?:…)` survive in the
        // raw pattern (the substring scan above runs against the
        // `(?:`→`(` normalisation, but this regex runs against the
        // unnormalised pattern); a non-capturing form like
        // `(?:a{1,})+` still matches because `?:a{1,}` is a valid
        // body — the `?:` falls inside `[^()]*` and the `{` is the
        // body quantifier the regex looks for.
        if let braceRe = try? NSRegularExpression(
            pattern: #"\([^()]*[+*{][^()]*\)\s*[+*{]"#,
            options: []
        ) {
            let ns = pattern as NSString
            if braceRe.firstMatch(in: pattern, options: [], range: NSRange(location: 0, length: ns.length)) != nil {
                return false
            }
        }
        // Defensive: more than 6 unbounded quantifiers (`+`, `*`,
        // `{n,}`) in a single query is a strong "this isn't a real find
        // query" signal. Counts apply to escaped metacharacters too —
        // not perfect, but the cost of a false positive on a legitimate
        // query with seven quantifiers is "user uses a different tool",
        // versus the cost of a false negative which is a frozen UI.
        //
        // Audit fix-#10 (2026-05-11): also count nested optionals (`?`).
        // The shape `a?a?a?…aaaa` (N optionals followed by N literals)
        // produces 2^N backtracking branches in ICU's NFA engine —
        // exponential blowup that the pre-fix gate let through because
        // `?` wasn't in the quantCount tally. Treat `?` the same as
        // `+`/`*`/`{`: 6 of them combined is the cap.
        if repetitionFacts(pattern).quantifiers > 6 { return false }
        return true
    }

    /// Worst-case steps ICU may spend in ONE row before the scan must be able
    /// to interrupt it (~5-25 ms at 40-200 M steps/s).
    private static let uninterruptibleStepBudget = 1_000_000.0

    /// The longest row (UTF-16 units) the scan may match WITHOUT asking ICU for
    /// progress callbacks; a longer row needs them so the deadline can stop a
    /// match already in progress. 0 means every row, `Int.max` means none.
    ///
    /// The callbacks make ICU visit every start position through a block, which
    /// costs ~65% on an ordinary scan, so a scan pays for them only on rows
    /// where the pattern could run long. Backtracking is exponential with a
    /// repeated group (`(a|aa){40}`, `(.*)+`) or a back-reference (`(.*)\1`):
    /// every row. Otherwise k repetition operators cost at most about
    /// n^(k+1)/(k+1)! steps on an n-unit row (`.*.*.*.*.*x` on 100 columns is
    /// 10+ s, but on 25 columns it is milliseconds), so a row stays plain
    /// until that bound passes the budget: an ordinary `\d+\.\d+` or
    /// `https?://\S+` never pays on a terminal row.
    static func uninterruptibleRowLimit(for pattern: String) -> Int {
        let facts = repetitionFacts(pattern)
        if facts.repeatsGroupOrBackReference || facts.quantifiers > 8 { return 0 }
        if facts.quantifiers == 0 { return Int.max }
        var factorial = 1.0
        for factor in 2...(facts.quantifiers + 1) { factorial *= Double(factor) }
        let limit = pow(uninterruptibleStepBudget * factorial, 1 / Double(facts.quantifiers + 1))
        return limit >= Double(Int.max) ? Int.max : Int(limit)
    }

    /// What the two checks above need from `pattern`: the tally of `+`, `*`,
    /// `?` and `{`, and whether a group is repeated (`)` then `+`, `*` or `{`)
    /// or a back-reference (`\1`-`\9`, `\k<name>`) is present. Counts escaped
    /// metacharacters and bracket-class members too, which only ever errs
    /// toward "more quantifiers". Walks UTF-8, not `Character`s: a quantifier
    /// followed by a combining mark is one grapheme and would not be counted.
    private static func repetitionFacts(_ pattern: String) -> (quantifiers: Int, repeatsGroupOrBackReference: Bool) {
        var quantifiers = 0
        var repeatsGroupOrBackReference = false
        var previous: UInt8 = 0
        for byte in pattern.utf8 {
            switch byte {
            case UInt8(ascii: "+"), UInt8(ascii: "*"), UInt8(ascii: "{"):
                // Treat any `{` as a possible quantifier; we don't
                // bother parsing `{n,m}` precisely.
                quantifiers += 1
                if previous == UInt8(ascii: ")") { repeatsGroupOrBackReference = true }
            case UInt8(ascii: "?"):
                quantifiers += 1
            case UInt8(ascii: "1")...UInt8(ascii: "9"), UInt8(ascii: "k"):
                if previous == UInt8(ascii: "\\") { repeatsGroupOrBackReference = true }
            default:
                break
            }
            previous = byte
        }
        return (quantifiers, repeatsGroupOrBackReference)
    }
}
