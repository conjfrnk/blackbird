import XCTest
@testable import Blackbird

/// `NonASCIIRowFilter` lets the find bar's Foundation scan skip rows that
/// cannot hold a non-ASCII query. The one property that matters is soundness:
/// whenever Foundation's own `range(of:options:)` finds the query in a row, the
/// filter must not have skipped that row (a skip there is a silently missing
/// match and a wrong Replace All). Foundation is the oracle throughout.
///
/// Cost: ~25 queries x ~60 rows of a few dozen characters, a few thousand
/// Foundation calls, well under 100 ms.
final class NonASCIIRowFilterTests: XCTestCase {

    private let queries: [String] = [
        "\u{E9}", "\u{C9}", "e\u{301}", "E\u{301}", "caf\u{E9}", "na\u{EF}ve", "\u{F1}", "\u{C5}", "\u{212B}", "\u{3A9}",
        "\u{2126}", "\u{3C3}", "\u{3C2}", "日本", "日本語", "한국어", "\u{AC00}", "\u{1F600}", "\u{2764}\u{FE0F}",
        "\u{130}", "\u{1C5}", "\u{FF21}", "\u{301}", "\u{2502}", "Привет",
        // ASCII-reachable through normalization or case folding: the filter
        // must either be unavailable for these or still pass the ASCII rows.
        "\u{DF}", "\u{17F}", "\u{212A}", "\u{FB03}", "\u{37E}", "\u{1E9E}", "\u{2126}\u{DF}",
    ]

    private let rows: [String] = [
        "plain ascii row", "STRASSE and strasse", "ffi fi k K s S ; ss SS", "cafe cafe\u{301} caf\u{E9} CAF\u{C9}",
        "\u{2502} step 000001 compiling module \u{25CF} ok", "\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}",
        "na\u{EF}ve nai\u{308}ve", "ni\u{F1}o nin\u{303}o", "\u{212B}ngstr\u{F6}m \u{C5} A\u{30A} a\u{30A}",
        "\u{2126} \u{3A9} \u{3C9}", "\u{3A3}\u{3C3}\u{3C2}", "日本語 テスト", "日本", "\u{65E5}\u{672C}\u{8A9E}",
        "한국어 \u{1112}\u{1161}\u{11AB}", "\u{AC00}", "grin \u{1F600} done", "\u{2764}\u{FE0F} \u{2764}",
        "\u{130}stanbul i\u{307}", "\u{1C4} \u{1C5} \u{1C6}", "\u{FF21}\u{FF22} \u{FF41}", "\u{FB03}ce o\u{FB03}ce",
        "\u{212A}elvin \u{17F}ome \u{DF}", "\u{37E} \u{1E9E}", "Привет привет", "\u{301}", "e\u{301}\u{301}",
        "\u{200B}\u{E9}\u{200D}", "\u{E9}\u{E9}", "x\u{E9}y", "R\u{E9}SUM\u{C9}",
    ]

    /// Whenever Foundation finds `query` in `row` (case-insensitive and
    /// case-sensitive), the filter must let the row through.
    func test_filterNeverSkipsARowFoundationMatches() {
        let optionSets: [String.CompareOptions] = [.caseInsensitive, []]
        var matches = 0
        for query in queries {
            guard var filter = NonASCIIRowFilter(query: query) else { continue }
            for row in rows {
                for options in optionSets {
                    guard row.range(of: query, options: options) != nil else { continue }
                    matches += 1
                    let passes = filter.mayMatch(row)
                    XCTAssertTrue(passes,
                                  "filter skipped \(row.debugDescription), which Foundation matches for "
                                  + "\(query.debugDescription) (options \(options.rawValue))")
                }
            }
        }
        XCTAssertGreaterThan(matches, 30, "fixture: the oracle must actually match rows")
    }

    /// Queries Foundation can match with pure-ASCII text get no filter, or a
    /// filter that still passes the ASCII rows they match.
    func test_queriesReachableFromAsciiNeverSkipAsciiRowsFoundationMatches() {
        let asciiRows: [String] = [
            "STRASSE strasse ss SS", "k K kelvin", "s S", "ffi FFI office", "; semicolon", "SS", "fi FI",
        ]
        for query in ["\u{DF}", "\u{17F}", "\u{212A}", "\u{FB03}", "\u{37E}", "\u{1E9E}"] {
            guard var filter = NonASCIIRowFilter(query: query) else { continue }
            for row in asciiRows where row.range(of: query, options: [.caseInsensitive]) != nil {
                let passes = filter.mayMatch(row)
                XCTAssertTrue(passes,
                              "filter skipped ASCII row \(row.debugDescription) that Foundation matches for \(query.debugDescription)")
            }
        }
    }

    func test_asciiQueryHasNoFilter() {
        XCTAssertNil(NonASCIIRowFilter(query: "needle"))
        XCTAssertNil(NonASCIIRowFilter(query: "\u{DF}"), "ß folds to ss: ASCII rows can match it")
        XCTAssertNil(NonASCIIRowFilter(query: "\u{212A}"), "the Kelvin sign folds to k")
        XCTAssertNil(NonASCIIRowFilter(query: "\u{FB03}"), "the ffi ligature folds to ffi")
    }

    /// The point of the filter: rows holding nothing related to the query are
    /// skipped (pure ASCII, box-drawing, bullets, other scripts), and rows
    /// holding the query in any case or normalization form are not.
    func test_skipsUnrelatedRowsAndKeepsRelatedOnes() throws {
        var accent = try XCTUnwrap(NonASCIIRowFilter(query: "\u{E9}"))
        for row in ["plain ascii row", "\u{2502} step 000001 \u{25CF} ok", "\u{2500}\u{2500}\u{2500}", "日本語 テスト", "grin \u{1F600}", ""] {
            let passes = accent.mayMatch(row)
            XCTAssertFalse(passes, "\(row.debugDescription) cannot hold \u{E9}")
        }
        for row in ["caf\u{E9}", "CAF\u{C9}", "cafe\u{301}", "CAFE\u{301}", "\u{2502} caf\u{E9} \u{25CF}"] {
            let passes = accent.mayMatch(row)
            XCTAssertTrue(passes, "\(row.debugDescription) holds \u{E9}")
        }

        var cjk = try XCTUnwrap(NonASCIIRowFilter(query: "日本"))
        let cjkOnAscii = cjk.mayMatch("plain ascii row \u{2502} \u{E9}")
        XCTAssertFalse(cjkOnAscii)
        let cjkOnCjk = cjk.mayMatch("日本語 テスト")
        XCTAssertTrue(cjkOnCjk)

        var emoji = try XCTUnwrap(NonASCIIRowFilter(query: "\u{1F600}"))
        let emojiOnOther = emoji.mayMatch("plain \u{E9} 日本")
        XCTAssertFalse(emojiOnOther)
        let emojiOnEmoji = emoji.mayMatch("grin \u{1F600} done")
        XCTAssertTrue(emojiOnEmoji)
    }

    /// A related scalar written in a form the query does not use still passes:
    /// the Angstrom sign for A-ring, the Ohm sign for Omega.
    func test_relatedScalarInAnotherNormalizationFormPasses() throws {
        var ring = try XCTUnwrap(NonASCIIRowFilter(query: "\u{C5}"))
        let angstromSign = ring.mayMatch("x \u{212B} y")
        XCTAssertTrue(angstromSign)
        let decomposed = ring.mayMatch("A\u{30A}")
        XCTAssertTrue(decomposed)
        var omega = try XCTUnwrap(NonASCIIRowFilter(query: "\u{3A9}"))
        let ohmSign = omega.mayMatch("\u{2126}")
        XCTAssertTrue(ohmSign)
    }
}
