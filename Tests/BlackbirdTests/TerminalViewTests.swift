import XCTest
import AppKit
import Combine
@testable import Blackbird

final class TerminalViewTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        TestHostTermination.shared.register()
    }

    func test_gridDimensionsFromPixelSize() {
        let metrics = CellMetrics(font: .monospacedSystemFont(ofSize: 13, weight: .regular))
        let grid = metrics.grid(forPixelSize: CGSize(width: 800, height: 480))
        XCTAssertGreaterThan(grid.cols, 40)
        XCTAssertGreaterThan(grid.rows, 10)
    }

    func test_cellMetricsAreConsistent() {
        let metrics = CellMetrics(font: .monospacedSystemFont(ofSize: 13, weight: .regular))
        XCTAssertGreaterThan(metrics.cellWidth, 0)
        XCTAssertGreaterThan(metrics.cellHeight, 0)
        XCTAssertGreaterThan(metrics.ascent, 0)
    }

    func test_resizeForwardsToSession() throws {
        let session = try TerminalSession.start(
            shell: "/bin/cat",
            arguments: [],
            size: .init(cols: 80, rows: 24)
        )
        let view = TerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 480))
        view.session = session

        // Expand to a new size. The view computes grid from pixel size.
        view.setFrameSize(NSSize(width: 1600, height: 900))

        // Wait for the resize to propagate through coreQueue → snapshot publish.
        let snapExp = expectation(description: "snap with new dims")
        var finalSnap: BBSnapshot?
        var c: AnyCancellable?
        c = session.$snapshot.sink { s in
            if let s, (s.cols != 80 || s.rows != 24), finalSnap == nil {
                finalSnap = s
                c?.cancel()
                snapExp.fulfill()
            }
        }
        wait(for: [snapExp], timeout: 3.0)

        XCTAssertGreaterThan(finalSnap?.cols ?? 0, 80)
        XCTAssertGreaterThan(finalSnap?.rows ?? 0, 24)

        session.terminate()
    }

    func test_viewRendersGivenSnapshotWithoutCrash() throws {
        let session = try TerminalSession.start(
            shell: "/bin/cat",
            arguments: [],
            size: .init(cols: 80, rows: 24)
        )

        let exp = expectation(description: "snap")
        var seen: BBSnapshot?
        var c: AnyCancellable?
        c = session.$snapshot
            .compactMap { $0 }
            .sink { snap in
                if seen == nil {
                    seen = snap
                    c?.cancel()
                    exp.fulfill()
                }
            }
        session.send(Data("hi\n".utf8))
        wait(for: [exp], timeout: 3.0)

        let view = TerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 480))
        view.session = session
        view.render(snapshot: seen!)  // must not crash

        session.terminate()
    }
}
