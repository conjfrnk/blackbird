import XCTest
@testable import Blackbird

final class BBTermTests: XCTestCase {

    func test_initAndDeinit() {
        let term = BBTerm(size: .init(cols: 80, rows: 24))
        XCTAssertNotNil(term)
        // deinit runs when scope exits
    }

    func test_initFailsWithZeroDimensions() {
        XCTAssertNil(BBTerm(size: .init(cols: 0, rows: 24)))
        XCTAssertNil(BBTerm(size: .init(cols: 80, rows: 0)))
    }

    func test_inputIsVisibleInSnapshot() throws {
        let term = try XCTUnwrap(BBTerm(size: .init(cols: 80, rows: 24)))
        term.input("hello")
        let snap = try XCTUnwrap(term.snapshot())
        XCTAssertEqual(snap.character(at: 0, row: 0), "h")
        XCTAssertEqual(snap.character(at: 4, row: 0), "o")
    }

    func test_resizeUpdatesSnapshotDimensions() throws {
        let term = try XCTUnwrap(BBTerm(size: .init(cols: 80, rows: 24)))
        term.resize(to: .init(cols: 120, rows: 40))
        let snap = try XCTUnwrap(term.snapshot())
        XCTAssertEqual(snap.cols, 120)
        XCTAssertEqual(snap.rows, 40)
    }

    func test_bellEventFires() throws {
        let term = try XCTUnwrap(BBTerm(size: .init(cols: 20, rows: 5)))
        let exp = expectation(description: "bell")
        term.onEvent { ev in
            if case .bell = ev { exp.fulfill() }
        }
        term.input([0x07])  // BEL
        wait(for: [exp], timeout: 1.0)
    }

    func test_titleEventFires() throws {
        let term = try XCTUnwrap(BBTerm(size: .init(cols: 20, rows: 5)))
        let exp = expectation(description: "title")
        var received: String?
        term.onEvent { ev in
            if case .title(let t) = ev {
                received = t
                exp.fulfill()
            }
        }
        // OSC 2 ; my-title ST  — alacritty accepts either ST (ESC \) or BEL as terminator
        term.input("\u{1B}]2;my-title\u{07}")
        wait(for: [exp], timeout: 1.0)
        XCTAssertEqual(received, "my-title")
    }
}
