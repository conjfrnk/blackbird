import Foundation

/// Exits the test host with code 0 once no `activityNotification` has arrived for `idleLimit`.
final class TestHostActivityMonitor {
    static let shared = TestHostActivityMonitor()
    static let activityNotification = Notification.Name(
        "dev.conjfrnk.blackbird.testHostActivity"
    )
    private static let idleLimit: TimeInterval = 300
    private static let checkInterval: TimeInterval = 30

    /// Main-queue confined.
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
        // .common so the check still fires while XCTest runs the runloop in non-default modes.
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }
}
