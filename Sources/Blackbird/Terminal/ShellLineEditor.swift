import Foundation
import BBCore

enum ShellLineEditor {
    enum RefusalReason: Error {
        case lineBreak
        case tab
        /// readline moves per codepoint while the DEL/arrow counts here are cell units.
        case multiCodepoint

        var message: String {
            switch self {
            case .lineBreak:     return "Refusing: replacement contains a line break"
            case .tab:           return "Refusing: replacement contains a tab"
            case .multiCodepoint: return "Refusing: replacement contains a multi-codepoint character"
            }
        }
    }

    /// `matches` must be non-empty and `cleanedReplacement` already sanitized. Matches are processed
    /// right-to-left so original-space coordinates stay valid. `.success(Data())` means nothing to write.
    static func spliceBytes(
        matches: [(line: Int32, startCol: Int, endCol: Int)],
        cleanedReplacement: Data,
        snapshot: BBSnapshot
    ) -> Result<Data, RefusalReason> {
        let snap = snapshot
        let line = matches[0].line
        let screenRow = Int(line) + snap.displayOffset
        // Count against the original snapshot: the shell echoes asynchronously, so a mid-splice re-read is stale.
        func chars(_ startCol: Int, _ endCol: Int) -> Int {
            guard startCol <= endCol else { return 0 }
            return snap.nonSpacerCellCount(
                row: screenRow, startCol: startCol, endCol: endCol
            ) ?? (endCol - startCol + 1)
        }
        let replacementChars = String(decoding: cleanedReplacement, as: UTF8.self).count
        if cleanedReplacement.contains(0x0A) || cleanedReplacement.contains(0x0D) {
            return .failure(.lineBreak)
        }
        if cleanedReplacement.contains(0x09) {
            return .failure(.tab)
        }
        let cleanedString = String(decoding: cleanedReplacement, as: UTF8.self)
        if cleanedString.count != cleanedString.unicodeScalars.count {
            return .failure(.multiCodepoint)
        }

        let escLeft: [UInt8] = [0x1B, 0x5B, 0x44]   // CSI D
        let escRight: [UInt8] = [0x1B, 0x5B, 0x43]  // CSI C
        func appendMoves(_ delta: Int, to bytes: inout Data) {
            if delta > 0 {
                for _ in 0..<delta { bytes.append(contentsOf: escRight) }
            } else if delta < 0 {
                for _ in 0..<(-delta) { bytes.append(contentsOf: escLeft) }
            }
        }
        // +1 on pending wrap: the grid cursor parks on the last cell while the shell's position is one past it.
        let p0 = chars(0, snap.cursorCol - 1) + (snap.cursorPendingWrap ? 1 : 0)
        var p = p0
        var bytes = Data()
        var spliced: [(sChar: Int, eChar: Int, len: Int)] = []
        for m in matches {
            let sChar = chars(0, m.startCol - 1)
            let len = chars(m.startCol, m.endCol)
            guard len > 0 else { continue }
            let eChar = sChar + len
            appendMoves(eChar - p, to: &bytes)
            bytes.append(Data(repeating: 0x7F, count: len))
            bytes.append(cleanedReplacement)
            p = sChar + replacementChars
            spliced.append((sChar, eChar, len))
        }
        guard !bytes.isEmpty else { return .success(Data()) }
        var finalTarget = p0
        var insideAdjusted = false
        for r in spliced {
            if r.eChar <= p0 {
                finalTarget += replacementChars - r.len
            } else if r.sChar < p0, p0 < r.eChar, !insideAdjusted {
                finalTarget += (r.sChar + replacementChars) - p0
                insideAdjusted = true
            }
        }
        appendMoves(finalTarget - p, to: &bytes)
        return .success(bytes)
    }
}
