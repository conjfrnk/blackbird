import Foundation

/// Row prefilter for the find bar's Foundation scan of a non-ASCII query. Foundation equates text across normalization
/// and case folding ("ß" with "ss"), and a false skip is a silently missing match, so every doubt answers "may match".
struct NonASCIIRowFilter {
    /// Verdict per scalar value; 0 = not yet computed, 1 = unrelated, 2 = related.
    private var verdicts: [UInt8]
    private let keys: Set<UInt32>

    init?(query: String) {
        guard query.utf8.contains(where: { (b: UInt8) -> Bool in b >= 0x80 }) else { return nil }
        // U+0345 and U+1E9A also match ASCII text through no mapping the forms show.
        for scalar in query.unicodeScalars where scalar.value == 0x0345 || scalar.value == 0x1E9A {
            return nil
        }
        var keys = Set<UInt32>()
        for form in Self.forms(of: query) {
            var holdsNonASCII = false
            for scalar in form.unicodeScalars where scalar.value >= 0x80 {
                keys.insert(scalar.value)
                holdsNonASCII = true
            }
            // A pure-ASCII form means ASCII rows could match the query.
            if !holdsNonASCII { return nil }
        }
        self.keys = keys
        verdicts = [UInt8](repeating: 0, count: 0x11_0000)
        for key in keys { verdicts[Int(key)] = 2 }
    }

    mutating func mayMatch(_ hay: String) -> Bool {
        for scalar in hay.unicodeScalars where scalar.value >= 0x80 {
            if relates(scalar) { return true }
        }
        return false
    }

    private mutating func relates(_ scalar: Unicode.Scalar) -> Bool {
        let index = Int(scalar.value)
        if verdicts[index] == 0 {
            let keys = self.keys
            let related: Bool = Self.forms(of: String(scalar)).contains { (form: String) -> Bool in
                form.unicodeScalars.contains { (s: Unicode.Scalar) -> Bool in keys.contains(s.value) }
            }
            verdicts[index] = related ? 2 : 1
        }
        return verdicts[index] == 2
    }

    private static func forms(of s: String) -> [String] {
        let cased: [String] = [
            s, s.lowercased(), s.uppercased(),
            s.folding(options: .caseInsensitive, locale: nil),
        ]
        var out: [String] = []
        out.reserveCapacity(cased.count * 5)
        for c in cased {
            out.append(c)
            out.append(c.precomposedStringWithCanonicalMapping)
            out.append(c.decomposedStringWithCanonicalMapping)
            out.append(c.precomposedStringWithCompatibilityMapping)
            out.append(c.decomposedStringWithCompatibilityMapping)
        }
        return out
    }
}
