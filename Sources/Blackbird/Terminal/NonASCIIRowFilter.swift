import Foundation

/// Conservative per-search row prefilter for the find bar's Foundation
/// substring scan, for queries that hold non-ASCII text (é, 日本, an emoji).
///
/// Foundation's case-insensitive `range(of:)` costs 5-17 us per row on the main
/// thread, so a query nobody can match with ASCII text, typed over a 100k-row
/// history (and redone by every snapshot refresh while output streams), blocked
/// the UI for 0.5-1.7 s. Nearly every row cannot hold such a query, and a
/// match needs at least one scalar of its own that relates to the query's
/// non-ASCII text, so `mayMatch` lets the scan skip the rows that hold none:
/// pure-ASCII rows, and rows whose non-ASCII text is unrelated to the query
/// (box-drawing, bullets, other scripts).
///
/// Conservative by construction: every doubt answers "may match" and the row
/// takes the Foundation loop, unchanged. A false skip would be a silently
/// missing match (and a wrong Replace All), so `NonASCIIRowFilterTests` pins
/// the rule against Foundation as the oracle.
///
/// Foundation's non-literal comparison equates texts across normalization and
/// case folding: the Kelvin sign with "k", "ß" with "ss", "ﬃ" with "ffi",
/// U+037E with ";", the Angstrom sign with "Å". So the filter works on forms:
/// the query's *key scalars* are the non-ASCII scalars of every case form (as
/// typed, lower-/upper-cased, case-folded), each in NFC, NFD, NFKC and NFKD,
/// and a row scalar *relates* when any of its own such forms holds a key.
/// The filter is unavailable (`init?` answers nil) when some form of the
/// query is pure ASCII, since ASCII rows could then match it.
struct NonASCIIRowFilter {
    /// Verdict per scalar value; 0 = not yet computed, 1 = unrelated, 2 = related.
    private var verdicts: [UInt8]
    private let keys: Set<UInt32>

    init?(query: String) {
        guard query.utf8.contains(where: { (b: UInt8) -> Bool in b >= 0x80 }) else { return nil }
        // U+0345 and U+1E9A also match ASCII text through no mapping the forms
        // show (a sweep of the BMP against Foundation found only these two).
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
            if !holdsNonASCII { return nil }
        }
        self.keys = keys
        // Allocated only for an eligible query: ASCII queries never get here.
        verdicts = [UInt8](repeating: 0, count: 0x11_0000)
        for key in keys { verdicts[Int(key)] = 2 }
    }

    /// Whether `hay` holds a scalar related to the query, i.e. whether the
    /// Foundation scan could find the query in it. False means it cannot.
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

    /// `s` as typed, lower-/upper-cased and case-folded, each also in NFC,
    /// NFD, NFKC and NFKD.
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
