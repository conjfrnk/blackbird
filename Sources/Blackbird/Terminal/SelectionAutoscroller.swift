import AppKit

/// Owns the selection-drag edge-autoscroll timer. Lifted off `TerminalView` so
/// the timer and its direction are mutated in exactly ONE place rather than
/// being two more `internal` fields any extension could touch (REFACTOR.md
/// Area 3: stateful controllers / the field hoist). The view drives it via
/// `update(direction:tick:)`; the only thing it reads back is `direction`,
/// inside its own tick, to use as the scroll delta.
///
/// Behaviour is unchanged from the inline `updateSelectionAutoscroll` /
/// `stopSelectionAutoscroll` it replaces — same ~60 Hz cadence, same
/// `.common`-mode runloop install, same re-arm-is-a-no-op semantics, same
/// drive-from-the-timer-tick model. Audit terminal-view-2 F2.
final class SelectionAutoscroller {
    private var timer: Timer?

    /// `+1` = scrolling toward older rows (cursor in the top edge band),
    /// `-1` = newer rows (bottom edge), `0` = stopped. Read by the view's tick
    /// to pass as the `session.scroll(delta:)` amount.
    private(set) var direction: Int32 = 0

    /// Arm, re-arm, or tear down the timer based on `direction`
    /// (`+1` top, `-1` bottom, `0` stop).
    ///
    /// While running, `tick` fires at ~60 Hz on the main runloop in `.common`
    /// mode — fast enough that holding at the edge feels responsive, slow
    /// enough to avoid 120 Hz Metal-pressure storms on ProMotion, and
    /// common-mode so it keeps firing during tracking runloops (menu bar,
    /// dropdowns, live resize) that default mode would stall. `tick` returns
    /// `false` to request an immediate stop (e.g. the drag ended). Re-arming
    /// with the same non-zero direction while already running is a no-op: the
    /// existing timer stays the sole driver, and a `mouseDragged` landing in
    /// the same band just confirms it.
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

    /// Stop any in-flight autoscroll. Safe to call when none is running.
    func stop() {
        timer?.invalidate()
        timer = nil
        direction = 0
    }
}
