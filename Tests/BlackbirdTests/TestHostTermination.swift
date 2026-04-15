import XCTest
import AppKit

/// Ensures the test host (`Blackbird.app`) terminates cleanly after the test
/// bundle finishes. Without this, `xcodebuild test` leaves zombie app
/// processes: SwiftUI @main apps with a WindowGroup don't auto-exit when
/// XCTest completes.
///
/// Each XCTestCase registers this observer in `class func setUp()`; the
/// singleton guard prevents duplicate registration.
final class TestHostTermination: NSObject, XCTestObservation {
    static let shared = TestHostTermination()
    private var registered = false
    private let lock = NSLock()

    func register() {
        lock.lock()
        defer { lock.unlock() }
        guard !registered else { return }
        XCTestObservationCenter.shared.addTestObserver(self)
        registered = true
    }

    func testBundleDidFinish(_ testBundle: Bundle) {
        // Small delay so any pending main-thread work (cancellables, etc.)
        // completes before we exit. Use exit(0) directly rather than
        // NSApp.terminate because XCTest can intercept the latter and keep
        // the process alive (empirical — we were getting zombie host apps).
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            exit(0)
        }
    }
}
