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
        var quantCount = 0
        var i = pattern.startIndex
        while i < pattern.endIndex {
            let c = pattern[i]
            if c == "+" || c == "*" || c == "?" {
                quantCount += 1
            } else if c == "{" {
                // Treat any `{` as a possible quantifier; we don't
                // bother parsing `{n,m}` precisely.
                quantCount += 1
            }
            i = pattern.index(after: i)
        }
        if quantCount > 6 { return false }
        return true
    }
}
