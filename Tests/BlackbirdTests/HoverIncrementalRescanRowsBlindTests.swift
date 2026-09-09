import XCTest
@testable import Blackbird

/// Blind behaviour tests for `HoverCoordinator.incrementalRescanRows`.
///
/// Contract: the result is every damaged row plus its immediate neighbours
/// (row-1 and row+1), clamped to `0..<rows`. Neighbours matter because a URL
/// wrapped across a row boundary changes meaning when either half changes.
/// Pure function; duplicates and order in the input are irrelevant.
///
/// Written without reading `HoverCoordinator.swift` beyond the signature.
final class HoverIncrementalRescanRowsBlindTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        TestHostTermination.shared.register()
    }

    func test_middleRow_expandsToBothNeighbours() {
        XCTAssertEqual(HoverCoordinator.incrementalRescanRows(damaged: [5], rows: 24), [4, 5, 6])
    }

    func test_firstRow_clampsAtZero() {
        XCTAssertEqual(HoverCoordinator.incrementalRescanRows(damaged: [0], rows: 24), [0, 1])
    }

    func test_lastRow_clampsAtRowsMinusOne() {
        XCTAssertEqual(HoverCoordinator.incrementalRescanRows(damaged: [23], rows: 24), [22, 23])
    }

    func test_adjacentRows_unionWithoutGaps() {
        XCTAssertEqual(HoverCoordinator.incrementalRescanRows(damaged: [3, 4], rows: 24), [2, 3, 4, 5])
    }

    func test_emptyDamage_isEmpty() {
        XCTAssertTrue(HoverCoordinator.incrementalRescanRows(damaged: [], rows: 24).isEmpty)
    }

    func test_duplicateDamage_isIdempotent() {
        XCTAssertEqual(HoverCoordinator.incrementalRescanRows(damaged: [5, 5, 5], rows: 24), [4, 5, 6])
        XCTAssertEqual(HoverCoordinator.incrementalRescanRows(damaged: [4, 3, 4, 3], rows: 24),
                       HoverCoordinator.incrementalRescanRows(damaged: [3, 4], rows: 24))
    }

    func test_orderOfDamage_isIrrelevant() {
        XCTAssertEqual(HoverCoordinator.incrementalRescanRows(damaged: [10, 2], rows: 24),
                       HoverCoordinator.incrementalRescanRows(damaged: [2, 10], rows: 24))
        XCTAssertEqual(HoverCoordinator.incrementalRescanRows(damaged: [10, 2], rows: 24),
                       [1, 2, 3, 9, 10, 11])
    }

    func test_singleRowGrid_clampsBothSides() {
        XCTAssertEqual(HoverCoordinator.incrementalRescanRows(damaged: [0], rows: 1), [0])
    }

    func test_bothEnds_clampIndependently() {
        XCTAssertEqual(HoverCoordinator.incrementalRescanRows(damaged: [0, 23], rows: 24),
                       [0, 1, 22, 23])
    }

    func test_resultNeverLeavesGrid() {
        let rows = 24
        for damaged in [[0], [23], [0, 23], [1, 22], [12]] {
            let out = HoverCoordinator.incrementalRescanRows(damaged: damaged, rows: rows)
            XCTAssertTrue(out.allSatisfy { (0..<rows).contains($0) },
                          "damaged \(damaged) produced out-of-grid rows \(out.sorted())")
            XCTAssertTrue(Set(damaged).isSubset(of: out),
                          "every damaged row must be in the rescan set: \(damaged) vs \(out.sorted())")
        }
    }
}
