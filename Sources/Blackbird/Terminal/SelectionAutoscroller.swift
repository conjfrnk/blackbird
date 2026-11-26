import AppKit

final class SelectionAutoscroller {
    private var timer: Timer?

    /// `+1` scrolls toward older rows (top edge), `-1` toward newer rows, `0` is stopped.
    private(set) var direction: Int32 = 0

    /// `tick` returns `false` to stop. The timer runs in `.common` mode so it keeps
    /// firing during tracking runloops (menus, live resize).
    func update(direction: Int32, tick: @escaping () -> Bool) {
        if direction == 0 {
            stop()
            return
        }
        if self.direction == direction, timer != nil {
            return
        }
        self.direction = direction
        timer?.invalidate()
        let t = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            if !tick() { self.stop() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        direction = 0
    }
}
