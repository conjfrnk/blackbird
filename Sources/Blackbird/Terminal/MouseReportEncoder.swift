import Foundation

/// Pure xterm mouse-report wire encoder (SGR 1006, UTF-8 1005 + X10
/// fallback), lifted out of `TerminalView` so the branches that matter for
/// correctness — SGR vs UTF-8 vs X10, press/release, wheel/motion, the
/// 223-column X10 limit — are unit-testable without synthesizing NSEvents
/// (REFACTOR.md Area 3: pin the already-pure `encodeMouseReport`).
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
    /// - `modifiers`: xterm modifier bits (shift 4, meta 8, ctrl 16) ORed
    ///   into the button code of every report, SGR and X10 alike — how a TUI
    ///   tells `<S-LeftMouse>` / `<C-RightMouse>` / `<C-ScrollWheelUp>` from
    ///   the plain gesture. In X10 they are applied after the release
    ///   substitution, so a modified release is `3 | modifiers`.
    /// - `utf8`: true when the app enabled UTF-8 extended mouse reporting
    ///   (mode 1005) without SGR. SGR wins if both are passed. The report
    ///   keeps the X10 shape, but each coordinate is sent as the UTF-8
    ///   encoding of `n + 32` (1-based `n`), so positions past 94 become two
    ///   bytes instead of a lone 0x80-0xFF byte a UTF-8 consumer rejects.
    ///
    /// Returns `nil` when X10 can't represent the position (cols/rows
    /// beyond 223), or UTF-8 can't (beyond 2015). SGR has no such limit.
    static func encode(
        sgr: Bool,
        button: Int,
        press: Bool,
        col: Int,
        row: Int,
        modifiers: Int = 0,
        utf8: Bool = false
    ) -> Data? {
        // Defensive guards — callers today pass 0…65 for button and
        // clamp col/row to 10 000, but a future caller outside the
        // TerminalView flow could exceed those bounds. X10's 6-byte
        // encoding traps on `UInt8(cbButton + 32)` when `cbButton >
        // 223`, and SGR's `\(button)` stringifies every value
        // including pathological ones. Reject up-front so the trap
        // surface stays bounded to this function, not the caller. The bound
        // is on `button | modifiers`: that is the value actually emitted, and
        // `3 | modifiers` (X10 release) stays under it too.
        guard (0..<224).contains(button | modifiers), col >= 0, row >= 0 else { return nil }
        if sgr {
            // SGR 1006: ESC [ < button|modifiers ; col+1 ; row+1 M/m
            let finalChar: Character = press ? "M" : "m"
            let seq = "\u{1B}[<\(button | modifiers);\(col + 1);\(row + 1)\(finalChar)"
            return Data(seq.utf8)
        }
        let cbButton = press ? button : 3
        let cb = UInt8((cbButton | modifiers) + 32)
        if utf8 {
            // DEC 1005: ESC [ M cb cx cy with cx/cy UTF-8 scalars (1 byte up
            // to 94, 2 bytes to the 2047 code-point ceiling). cb stays one
            // raw byte, as in xterm; it is < 128 for every real caller.
            guard col < 2015, row < 2015 else { return nil }
            var out: [UInt8] = [0x1B, 0x5B, 0x4D, cb]
            for n in [col, row] {
                let cp = n + 33
                if cp < 0x80 {
                    out.append(UInt8(cp))
                } else {
                    out.append(UInt8(0xC0 | (cp >> 6)))
                    out.append(UInt8(0x80 | (cp & 0x3F)))
                }
            }
            return Data(out)
        }
        // X10/normal: ESC [ M cb cx cy (6-byte, cx/cy capped at 223).
        guard col < 223, row < 223 else { return nil }
        let cx = UInt8(col + 33)
        let cy = UInt8(row + 33)
        return Data([0x1B, 0x5B, 0x4D, cb, cx, cy])
    }
}
