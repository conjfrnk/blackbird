import Foundation

/// Audit S2-004: idle-based replacement for the test-host 60 s exit
/// fuse. The TESTS (TestHostTermination, in the injected bundle — same
/// process) post `activityNotification` on every test start/finish;
/// this monitor exits the host only when no heartbeat has arrived for
/// `idleLimit`. A single test legitimately running longer than the
/// limit would still be shot — 300 s is far past the suite's slowest
/// test (the project gates test cost deliberately) while keeping
/// zombie-host cleanup prompt enough for CI.
///
/// Exit code stays 0 on the idle path, preserving the original
/// safety-net semantics: a genuinely red run is caught by
/// TestHostTermination's issueCount → exit(1) propagation and by CI's
/// "both suites printed passed" grep, not by this last-resort fuse.
///
/// Lives in its own file (not `App.swift`) so the app entry point stays a
/// lifecycle table of contents; `AppDelegate.startTestHostIfUnderTest()`
/// is the only caller.
final class TestHostActivityMonitor {
    static let shared = TestHostActivityMonitor()
    static let activityNotification = Notification.Name(
        "dev.conjfrnk.blackbird.testHostActivity"
    )
    private static let idleLimit: TimeInterval = 300
    private static let checkInterval: TimeInterval = 30

    /// Main-queue confined (observer is delivered on .main; the timer
    /// fires on the main runloop).
    private var lastActivity = Date()
    private var observer: NSObjectProtocol?
    private var timer: Timer?

    func start() {
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(
            forName: Self.activityNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.lastActivity = Date()
        }
        let t = Timer(timeInterval: Self.checkInterval, repeats: true) { [weak self] _ in
            guard let self else { return }
            let idle = Date().timeIntervalSince(self.lastActivity)
            if idle > Self.idleLimit {
                FileHandle.standardError.write(Data(
                    "Blackbird test-host safety net: no test activity for \(Int(idle)) s — exiting host.\n".utf8
                ))
                exit(0)
            }
        }
        // .common so the check still fires while XCTest runs the
        // runloop in non-default modes (modal panels, tracking).
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }
}
