import Foundation

enum MouseReportEncoder {
    /// `button`: 0/1/2 left/middle/right, 32 motion-with-button, 64/65 wheel up/down. `modifiers`: shift 4, meta 8, ctrl 16.
    static func encode(
        sgr: Bool,
        button: Int,
        press: Bool,
        col: Int,
        row: Int,
        modifiers: Int = 0,
        utf8: Bool = false
    ) -> Data? {
        // `UInt8(cb + 32)` traps above 223; the bound is on the emitted `button | modifiers`.
        guard (0..<224).contains(button | modifiers), col >= 0, row >= 0 else { return nil }
        if sgr {
            // SGR 1006: ESC [ < button|modifiers ; col+1 ; row+1 M/m
            let finalChar: Character = press ? "M" : "m"
            let seq = "\u{1B}[<\(button | modifiers);\(col + 1);\(row + 1)\(finalChar)"
            return Data(seq.utf8)
        }
        // X10 (1000/1002/1003) and DEC 1005: ESC [ M cb cx cy; a release always reports button bits 3.
        let cbButton = press ? button : 3
        let cb = UInt8((cbButton | modifiers) + 32)
        if utf8 {
            // DEC 1005: cx/cy are the UTF-8 encoding of n + 32 (1-based n); cb stays one raw byte.
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
        guard col < 223, row < 223 else { return nil }
        let cx = UInt8(col + 33)
        let cy = UInt8(row + 33)
        return Data([0x1B, 0x5B, 0x4D, cb, cx, cy])
    }
}
