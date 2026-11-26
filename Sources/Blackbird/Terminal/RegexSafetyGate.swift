import Foundation

/// Pre-compile ReDoS gate for find queries: `NSRegularExpression` has no match-timeout API. Not exhaustive; polynomial
/// blowups with no nested quantifier (`.*.*.*.*.*x`) pass on purpose and the scan is interruptible mid-row instead.
enum RegexSafetyGate {
    static func isReasonable(_ pattern: String) -> Bool {
        if pattern.count > 256 { return false }
        // Normalise non-capturing groups so `(?:a+)+` trips the same substring checks as `(a+)+`.
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
        // Alternation inside a quantified group (`(a|aa)+`, `(a|aa|aaa)*`): overlapping alternatives, any number of `|`.
        if let altRe = try? NSRegularExpression(
            pattern: #"\([^()]+\|[^()]+\)\s*[+*]"#,
            options: []
        ) {
            let ns = pattern as NSString
            if altRe.firstMatch(in: pattern, options: [], range: NSRange(location: 0, length: ns.length)) != nil {
                return false
            }
        }
        // A group whose body holds a quantifier and is itself quantified: `(a{1,})+`, `(.+){2,5}`.
        // Runs against the unnormalised pattern; `?:` falls inside `[^()]*`.
        if let braceRe = try? NSRegularExpression(
            pattern: #"\([^()]*[+*{][^()]*\)\s*[+*{]"#,
            options: []
        ) {
            let ns = pattern as NSString
            if braceRe.firstMatch(in: pattern, options: [], range: NSRange(location: 0, length: ns.length)) != nil {
                return false
            }
        }
        // `?` counts too: `a?a?a?…aaaa` (N optionals, N literals) backtracks 2^N in ICU.
        if repetitionFacts(pattern).quantifiers > 6 { return false }
        return true
    }

    private static let uninterruptibleStepBudget = 1_000_000.0

    /// The longest row (UTF-16 units) matched without ICU progress callbacks, which cost ~65% on an ordinary scan; 0 means
    /// every row needs them. k repetition operators cost at most about n^(k+1)/(k+1)! steps on an n-unit row.
    static func uninterruptibleRowLimit(for pattern: String) -> Int {
        let facts = repetitionFacts(pattern)
        if facts.repeatsGroupOrBackReference || facts.quantifiers > 8 { return 0 }
        if facts.quantifiers == 0 { return Int.max }
        var factorial = 1.0
        for factor in 2...(facts.quantifiers + 1) { factorial *= Double(factor) }
        let limit = pow(uninterruptibleStepBudget * factorial, 1 / Double(facts.quantifiers + 1))
        return limit >= Double(Int.max) ? Int.max : Int(limit)
    }

    /// Walks UTF-8, not `Character`s: a quantifier followed by a combining mark is one grapheme and would not be counted.
    private static func repetitionFacts(_ pattern: String) -> (quantifiers: Int, repeatsGroupOrBackReference: Bool) {
        var quantifiers = 0
        var repeatsGroupOrBackReference = false
        var previous: UInt8 = 0
        for byte in pattern.utf8 {
            switch byte {
            case UInt8(ascii: "+"), UInt8(ascii: "*"), UInt8(ascii: "{"):
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
