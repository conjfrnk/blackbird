import Foundation

/// Pure xterm mouse-report wire encoder (SGR 1006 + X10 fallback), lifted
/// out of `TerminalView` so the branches that matter for correctness — SGR
/// vs X10, press/release, wheel/motion, the 223-column X10 limit — are
/// unit-testable without synthesizing NSEvents (REFACTOR.md Area 3: pin the
/// already-pure `encodeMouseReport`).
enum MouseReportEncoder {
    /// Pure encoder for xterm mouse reports — extracted so the branches that
    /// matter for correctness (SGR 1006 vs X10 fallback, press/release,
    /// wheel/motion) can be unit-tested without synthesizing NSEvents.
    ///
    /// - `sgr`: true when the app enabled SGR extended mouse reporting
    ///   (mode 1006). The final byte `M`/`m` distinguishes press from
    ///   release and the button number is carried verbatim.
    /// - `button`: the xterm button number — 0/1/2 for left/middle/right,
    ///   32 for motion-with-button, 64/65 for wheel up/down.
    /// - `press`: false for release events. In the X10 fallback (modes
    ///   1000/1002/1003), release always reports button bits = 3 regardless
    ///   of which button was released.
    ///
    /// Returns `nil` when X10 can't represent the position (cols/rows
    /// beyond 223). SGR has no such limit.
    static func encode(
        sgr: Bool,
        button: Int,
        press: Bool,
        col: Int,
        row: Int
    ) -> Data? {
        // Defensive guards — callers today pass 0…65 for button and
        // clamp col/row to 10 000, but a future caller outside the
        // TerminalView flow could exceed those bounds. X10's 6-byte
        // encoding traps on `UInt8(cbButton + 32)` when `cbButton >
        // 223`, and SGR's `\(button)` stringifies every value
        // including pathological ones. Reject up-front so the trap
        // surface stays bounded to this function, not the caller.
        guard (0..<224).contains(button), col >= 0, row >= 0 else { return nil }
        if sgr {
            // SGR 1006: ESC [ < button ; col+1 ; row+1 M/m
            let finalChar: Character = press ? "M" : "m"
            let seq = "\u{1B}[<\(button);\(col + 1);\(row + 1)\(finalChar)"
            return Data(seq.utf8)
        }
        // X10/normal: ESC [ M cb cx cy (6-byte, cx/cy capped at 223).
        guard col < 223, row < 223 else { return nil }
        let cbButton = press ? button : 3
        let cb = UInt8(cbButton + 32)
        let cx = UInt8(col + 33)
        let cy = UInt8(row + 33)
        return Data([0x1B, 0x5B, 0x4D, cb, cx, cy])
    }
}
