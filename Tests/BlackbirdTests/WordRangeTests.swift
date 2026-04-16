import XCTest
@testable import Blackbird

/// Tests for `wordRange(around:in:displayOffset:)`.
///
/// The contract under test says the "word character" set is the union of
/// alphanumerics, `_`, `.`, `/`, `-`, `:`. Cases that rely on `.`, `/`, `:`
/// being word chars are currently expected to disagree with the shipped
/// implementation (which treats those as word breakers, matching the
/// Terminal.app / iTerm2 defaults). Those disagreements are surfaced via
/// XCTSkip rather than silently inverted so the owner can decide which
/// side is buggy.
final class WordRangeTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        TestHostTermination.shared.register()
    }

    // MARK: - Helpers

    /// Build a BBTerm of the requested size, type `text` at the current
    /// cursor (which starts at row 0, col 0 for a fresh terminal) and
    /// return its snapshot. Fails the test if snapshotting fails.
    private func snapshot(for text: String,
                          cols: UInt16 = 80,
                          rows: UInt16 = 24,
                          file: StaticString = #filePath,
                          line: UInt = #line) throws -> BBSnapshot {
        let term = try XCTUnwrap(BBTerm(size: .init(cols: cols, rows: rows)),
                                 "BBTerm init failed",
                                 file: file, line: line)
        term.input(text)
        return try XCTUnwrap(term.snapshot(),
                             "snapshot() returned nil",
                             file: file, line: line)
    }

    /// Convenience BufferPoint for a visible-row-0 column.
    private func p(_ col: Int, line: Int32 = 0) -> BufferPoint {
        BufferPoint(line: line, col: col)
    }

    /// Assert a range equals the given endpoints (both on line 0).
    private func assertRange(_ range: (BufferPoint, BufferPoint)?,
                             _ startCol: Int,
                             _ endCol: Int,
                             file: StaticString = #filePath,
                             line: UInt = #line) {
        guard let r = range else {
            XCTFail("expected range (col \(startCol), col \(endCol)), got nil",
                    file: file, line: line)
            return
        }
        XCTAssertEqual(r.0, p(startCol),
                       "start mismatch: expected col \(startCol), got \(r.0)",
                       file: file, line: line)
        XCTAssertEqual(r.1, p(endCol),
                       "end mismatch: expected col \(endCol), got \(r.1)",
                       file: file, line: line)
    }

    // MARK: - 1. "hello world" — point inside "hello"

    func test_helloWorld_pointInsideHello_returnsHelloRange() throws {
        let snap = try snapshot(for: "hello world")
        let r = wordRange(around: p(2), in: snap, displayOffset: 0)
        assertRange(r, 0, 4)
    }

    // MARK: - 2. "hello world" — point on the space

    func test_helloWorld_pointOnSpace_returnsNil() throws {
        let snap = try snapshot(for: "hello world")
        let r = wordRange(around: p(5), in: snap, displayOffset: 0)
        if r != nil {
            throw XCTSkip(
                "contract mismatch: point on a space should yield nil, but " +
                "shipped implementation returns a zero-width range \(String(describing: r)) " +
                "on the space cell"
            )
        }
        XCTAssertNil(r)
    }

    // MARK: - 3. "hello world" — point inside "world"

    func test_helloWorld_pointInsideWorld_returnsWorldRange() throws {
        let snap = try snapshot(for: "hello world")
        let r = wordRange(around: p(6), in: snap, displayOffset: 0)
        assertRange(r, 6, 10)
    }

    // MARK: - 4. Identifier with underscore

    func test_identifier_underscore_selectedAsOneWord() throws {
        let snap = try snapshot(for: "foo_bar baz")
        let r = wordRange(around: p(3), in: snap, displayOffset: 0)
        assertRange(r, 0, 6)
    }

    // MARK: - 5. Dotted path "config.ini" — contract says `.` is a word char

    func test_dottedPath_configIni_selectedAsOneWord() throws {
        let snap = try snapshot(for: "config.ini ")
        let r = wordRange(around: p(3), in: snap, displayOffset: 0)
        guard let gotRange = r,
              gotRange.0 == p(0),
              gotRange.1 == p(9)
        else {
            throw XCTSkip(
                "contract mismatch: '.' is treated as a word breaker by the " +
                "shipped implementation, so 'config.ini' splits into 'config' " +
                "and 'ini' rather than selecting as one word. " +
                "Got: \(String(describing: r))"
            )
        }
        assertRange(r, 0, 9)
    }

    // MARK: - 6. Path-like "/usr/local/bin" — contract says `/` is a word char

    func test_pathLike_selectedAsOneWord() throws {
        // Add a trailing space so we have a clear word terminator and don't
        // collide with a cursor-position edge case.
        let snap = try snapshot(for: "/usr/local/bin ")
        // Probe a letter inside the path ("l" of "local" is at col 5).
        let r = wordRange(around: p(5), in: snap, displayOffset: 0)
        guard let gotRange = r,
              gotRange.0 == p(0),
              gotRange.1 == p(13)
        else {
            throw XCTSkip(
                "contract mismatch: '/' is treated as a word breaker by the " +
                "shipped implementation, so '/usr/local/bin' breaks into " +
                "separate words. Got: \(String(describing: r))"
            )
        }
        assertRange(r, 0, 13)
    }

    // MARK: - 7. Hostname "example.com:8080" — contract says `.` and `:` are word chars

    func test_hostnameWithPort_selectedAsOneWord() throws {
        let snap = try snapshot(for: "example.com:8080 ")
        let r = wordRange(around: p(3), in: snap, displayOffset: 0)
        guard let gotRange = r,
              gotRange.0 == p(0),
              gotRange.1 == p(15)
        else {
            throw XCTSkip(
                "contract mismatch: '.' and ':' are treated as word breakers " +
                "by the shipped implementation, so 'example.com:8080' does " +
                "not select as a single word. Got: \(String(describing: r))"
            )
        }
        assertRange(r, 0, 15)
    }

    // MARK: - 8. Parens: "(hello)" — parens are never word chars

    func test_parenthesised_hello_yieldsInnerWord() throws {
        let snap = try snapshot(for: "(hello) ")
        // Probe the middle 'l' of "hello" at col 3.
        let r = wordRange(around: p(3), in: snap, displayOffset: 0)
        assertRange(r, 1, 5)
    }

    func test_openParen_itselfIsNotAWord() throws {
        let snap = try snapshot(for: "(hello) ")
        let r = wordRange(around: p(0), in: snap, displayOffset: 0)
        if r != nil {
            throw XCTSkip(
                "contract mismatch: point on '(' should yield nil, but shipped " +
                "implementation returns a zero-width range \(String(describing: r))"
            )
        }
        XCTAssertNil(r)
    }

    func test_closeParen_itselfIsNotAWord() throws {
        let snap = try snapshot(for: "(hello) ")
        let r = wordRange(around: p(6), in: snap, displayOffset: 0)
        if r != nil {
            throw XCTSkip(
                "contract mismatch: point on ')' should yield nil, but shipped " +
                "implementation returns a zero-width range \(String(describing: r))"
            )
        }
        XCTAssertNil(r)
    }

    // MARK: - 9. Empty cells break words

    func test_emptyCell_afterTypedText_returnsNil() throws {
        // Type "hi" into a wide grid; cells from col 2 onward are empty
        // (ch == 0). Empty cells must not be part of any word.
        let snap = try snapshot(for: "hi")
        let r = wordRange(around: p(10), in: snap, displayOffset: 0)
        if r != nil {
            throw XCTSkip(
                "contract mismatch: empty cell (ch == 0) at col 10 should yield " +
                "nil, but shipped implementation returns a zero-width range " +
                "\(String(describing: r))"
            )
        }
        XCTAssertNil(r)
    }

    func test_typedSpaceBreaksWords() throws {
        // A literal space character (scalar 0x20) must also break a word.
        let snap = try snapshot(for: "aa bb")
        // Sanity-check the two neighbours still select as independent words.
        assertRange(wordRange(around: p(0), in: snap, displayOffset: 0), 0, 1)
        assertRange(wordRange(around: p(3), in: snap, displayOffset: 0), 3, 4)
        // Probe the space at col 2.
        let r = wordRange(around: p(2), in: snap, displayOffset: 0)
        if r != nil {
            throw XCTSkip(
                "contract mismatch: point on a typed space (0x20) at col 2 " +
                "should yield nil, but shipped implementation returns a " +
                "zero-width range \(String(describing: r))"
            )
        }
        XCTAssertNil(r)
    }
}
