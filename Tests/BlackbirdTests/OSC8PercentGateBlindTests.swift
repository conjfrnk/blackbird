import XCTest
@testable import Blackbird

/// Characterization of `OSC8URLPolicy.isAllowed`'s percent-encoded control /
/// invisible-scalar gate, written to pin the verdict for every input so that a
/// fast path for '%'-free strings cannot change an outcome.
///
/// Contract pinned (must hold before and after any speed-up):
///  - a URL whose `absoluteString` contains NO '%' byte is never rejected by
///    the percent gate, so its verdict is decided purely by the scheme /
///    credential / host / mailto rules;
///  - a URL containing a percent-encoded C0 / DEL / C1 / bidi / invisible
///    sequence is rejected regardless of hex-digit case or where the '%'
///    sits in the string;
///  - benign percent-encodings (`%20`, `%E2%9C%93`, an encoded literal
///    percent `%25`, near-miss bytes) remain allowed.
///
/// Cost: every test is a few dozen to ~4k `isAllowed` calls on short strings;
/// microseconds to low milliseconds each, a few KB of memory.
final class OSC8PercentGateBlindTests: XCTestCase {

    private func url(_ s: String, file: StaticString = #filePath, line: UInt = #line) throws -> URL {
        try XCTUnwrap(URL(string: s), "fixture must parse as a URL: \(s)", file: file, line: line)
    }

    // MARK: - '%'-free URLs: verdict unchanged

    func testPercentFreeHttpsURLsAreAllowed() throws {
        let urls = [
            "https://example.com",
            "https://example.com/",
            "https://example.com/path/to/file.html",
            "http://example.com:8080/p?x=1&y=2#frag",
            "https://sub.domain.example.co.uk/a/b/c?q=hello+world",
            "HTTPS://EXAMPLE.COM/Upper",
            "https://[::1]:3000/health",
            "https://192.168.0.1/admin",
            "https://github.com/conjfrnk/blackbird/pull/34#issuecomment-1",
        ]
        for s in urls {
            XCTAssertTrue(OSC8URLPolicy.isAllowed(try url(s)), "%-free URL must be allowed: \(s)")
        }
    }

    func testPercentFreeMailtoAllowedAndRejectedAsBefore() throws {
        XCTAssertTrue(OSC8URLPolicy.isAllowed(try url("mailto:user@example.com")))
        XCTAssertTrue(OSC8URLPolicy.isAllowed(try url("mailto:root@example.com?subject=hi")))
        // Non-subject header and repeated subject: still rejected by the mailto rules.
        XCTAssertFalse(OSC8URLPolicy.isAllowed(try url("mailto:a@b.com?subject=x&bcc=evil@example.com")))
        XCTAssertFalse(OSC8URLPolicy.isAllowed(try url("mailto:a@b.com?subject=x&subject=y")))
        // Multi-recipient (two '@'): rejected.
        XCTAssertFalse(OSC8URLPolicy.isAllowed(try url("mailto:user@safe.com,b@evil.com")))
    }

    func testPercentFreeURLsStillRejectedByNonPercentRules() throws {
        let rejected = [
            "javascript:alert(1)",
            "ftp://example.com/file",
            "file:///tmp/x.command",
            "ssh://example.com",
            "https://user:pass@example.com/",
            "https://:pw@example.com/",
            "https://xn--pple-43d.com/login",
            "https:///path/only",
        ]
        for s in rejected {
            guard let u = URL(string: s) else { continue }
            XCTAssertFalse(OSC8URLPolicy.isAllowed(u), "non-percent rule must still reject: \(s)")
        }
    }

    /// Bulk sweep over distinct '%'-free URLs of varying length; all allowed.
    /// 2000 calls on <200-byte strings.
    func testBulkPercentFreeURLsAllAllowed() throws {
        for i in 0..<2000 {
            let s = "https://host\(i % 17).example.com/p/\(i)/\(String(repeating: "a", count: i % 64))?k=\(i)#f\(i)"
            let u = try url(s)
            XCTAssertFalse(u.absoluteString.contains("%"))
            XCTAssertTrue(OSC8URLPolicy.isAllowed(u), "index \(i)")
        }
    }

    /// A lone '%' that Foundation re-encodes to `%25` followed by digits that
    /// would form a control code if (wrongly) read as an escape must stay allowed.
    func testEncodedLiteralPercentFollowedByDigitsIsAllowed() throws {
        let urls = [
            "https://example.com/50%",
            "https://example.com/%0",
            "https://example.com/%0G",
            "https://example.com/%GG",
            "https://example.com/%2",
            "https://example.com/%2508",
            "https://example.com/%257F",
            "https://example.com/%25%2508",
        ]
        for s in urls {
            XCTAssertTrue(OSC8URLPolicy.isAllowed(try url(s)), "must be allowed: \(s)")
        }
    }

    // MARK: - '%'-bearing benign URLs stay allowed

    func testBenignPercentEncodingsAreAllowed() throws {
        let urls = [
            "https://example.com/a%20b",
            "https://example.com/%41%2F",
            "https://example.com/%7E",
            "https://example.com/%7e",
            "https://example.com/%E2%9C%93",       // U+2713
            "https://example.com/%C2%A0",          // NBSP is not a C1 control
            "https://example.com/%C2%AE",          // U+00AE, near-miss for soft hyphen
            "https://example.com/%80",             // lone continuation byte (deferred S4-005)
            "https://example.com/%E2%80%90",       // hyphen, below the bidi range
            "https://example.com/%E2%80%8A",       // hair space, below %8B
            "https://example.com/%E2%81%A5",       // just below isolates
            "https://example.com/%E2%81%AA",       // just above isolates
            "https://example.com/%EF%B8%90",       // not a variation selector
            "https://example.com/%F3%A0%82%80",     // outside tag-block pattern
            "https://example.com/%F3%A0%88%80",     // outside VS17 pattern
            "https://example.com/%D8%9D",
            "https://example.com/%E1%A0%8F",
            "mailto:a@b.com?subject=Hello%20World",
        ]
        for s in urls {
            XCTAssertTrue(OSC8URLPolicy.isAllowed(try url(s)), "must be allowed: \(s)")
        }
    }

    // MARK: - '%'-bearing hostile URLs stay rejected

    func testEveryC0AndDelEscapeIsRejectedInAnyCase() throws {
        var count = 0
        for byte in 0x00...0x1F {
            for fmt in ["%%%02X", "%%%02x"] {
                let esc = String(format: fmt, byte)
                let u = try url("https://example.com/a\(esc)b")
                XCTAssertFalse(OSC8URLPolicy.isAllowed(u), "must reject \(esc)")
                count += 1
            }
        }
        for esc in ["%7F", "%7f"] {
            XCTAssertFalse(OSC8URLPolicy.isAllowed(try url("https://example.com/a\(esc)b")), esc)
        }
        XCTAssertEqual(count, 64)
    }

    func testEveryC1EscapeIsRejected() throws {
        for b in 0x80...0x9F {
            let esc = String(format: "%%C2%%%02X", b)
            XCTAssertFalse(OSC8URLPolicy.isAllowed(try url("https://example.com/\(esc)x")), esc)
            let lower = esc.lowercased()
            XCTAssertFalse(OSC8URLPolicy.isAllowed(try url("https://example.com/\(lower)x")), lower)
        }
    }

    func testBidiAndInvisibleEscapesAreRejected() throws {
        let hostile = [
            "%E2%80%AE", "%E2%80%AD", "%E2%80%A8", "%E2%80%AF", "%E2%80%8B", "%E2%80%8F",
            "%E2%81%A0", "%E2%81%A6", "%E2%81%A9",
            "%C2%AD", "%D8%9C", "%E1%A0%8E",
            "%EF%B8%80", "%EF%B8%8F", "%EF%BB%BF",
            "%F3%A0%80%80", "%F3%A0%81%BF", "%F3%A0%84%80", "%F3%A0%87%AF",
        ]
        for esc in hostile {
            for variant in [esc, esc.lowercased()] {
                XCTAssertFalse(OSC8URLPolicy.isAllowed(try url("https://example.com/p\(variant)q")), variant)
            }
        }
        // Mixed hex case.
        XCTAssertFalse(OSC8URLPolicy.isAllowed(try url("https://example.com/%Ef%Bb%Bf")))
        XCTAssertFalse(OSC8URLPolicy.isAllowed(try url("https://example.com/%e2%80%Ae")))
    }

    /// The '%' may sit anywhere: start of path, query, fragment, end of string,
    /// after many '%'-free bytes, or after a benign escape.
    func testHostileEscapePositionDoesNotMatter() throws {
        let urls = [
            "https://example.com/%08",
            "https://example.com/?q=%0d%0a",
            "https://example.com/#%1b",
            "https://example.com/%20%08",
            "https://example.com/%E2%9C%93%E2%80%AE",
            "https://example.com/\(String(repeating: "a", count: 4000))%08",
            "https://example.com/\(String(repeating: "%41", count: 500))%7F",
            "mailto:user@apple.com%08evil.com",
            "mailto:a@b.com?subject=Hi%0D%0Abcc",
            "HTTPS://EXAMPLE.COM/%e2%80%ae",
        ]
        for s in urls {
            XCTAssertFalse(OSC8URLPolicy.isAllowed(try url(s)), "must be rejected: \(s.prefix(60))")
        }
    }

    /// A long benign-percent URL (no hostile sequence) is still allowed: the
    /// gate must scan the whole string, not stop at the first '%'.
    func testManyBenignEscapesRemainAllowed() throws {
        let s = "https://example.com/" + String(repeating: "%41%2F%20", count: 300)
        XCTAssertTrue(OSC8URLPolicy.isAllowed(try url(s)))
    }

    // MARK: - Pairing: same URL with/without the hostile escape

    func testInsertingHostileEscapeFlipsVerdict() throws {
        for tail in ["", "/", "/a/b", "/a?x=1", "/a#f"] {
            let clean = "https://example.com\(tail)"
            let dirty = "https://example.com\(tail)%E2%80%AE"
            XCTAssertTrue(OSC8URLPolicy.isAllowed(try url(clean)), clean)
            XCTAssertFalse(OSC8URLPolicy.isAllowed(try url(dirty)), dirty)
        }
    }
}
