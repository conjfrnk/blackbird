import Foundation
import BBCore

/// The find-replace byte engine: given the matches on the live shell input line
/// and an already-sanitized replacement, synthesize the readline byte stream
/// (CSI C / CSI D cursor moves + DEL erasures + replacement bytes) that splices
/// every match in one consistent pass. Extracted verbatim from the splice path
/// (now `FindController.spliceReplacements`; REFACTOR.md Part IV "critical": the
/// most correctness-critical logic in the subsystem, mis-tuned by five prior
/// audits) into a pure, view-independent seam so its cursor math can be
/// exercised on raw byte arrays. The only responsibilities left to the caller
/// are sanitizing the replacement, surfacing the refusal toast, and writing the
/// bytes to the PTY.
enum ShellLineEditor {
    /// Why a replacement was refused. The shell would mis-execute these, so the
    /// engine emits no bytes and the caller shows a transient message.
    enum RefusalReason: Error {
        /// LF/CR — would run the leading fragment as a separate command (L20).
        case lineBreak
        /// TAB — would fire readline/ZLE completion mid-stream (S3-009).
        case tab
        /// A multi-scalar grapheme — readline moves per codepoint while the
        /// DEL/arrow counts here are cell units, so a Replace All would land the
        /// next span's DELs off-target. Refuse rather than corrupt.
        case multiCodepoint

        var message: String {
            switch self {
            case .lineBreak:     return "Refusing: replacement contains a line break"
            case .tab:           return "Refusing: replacement contains a tab"
            case .multiCodepoint: return "Refusing: replacement contains a multi-codepoint character"
            }
        }
    }

    /// Build the splice byte stream over `snapshot`. `matches` must be non-empty
    /// and `cleanedReplacement` must already be sanitized (bidi/control-stripped)
    /// by the caller — this engine only refuses the line-break/tab/multi-codepoint
    /// shapes the shell can't consume. `.success(Data())` means "nothing to do"
    /// (every match collapsed to zero length); the caller skips the write.
    ///
    /// Matches are processed RIGHT-TO-LEFT so original-space coordinates stay
    /// valid throughout (edits never move content left of the next region).
    /// Moves are bidirectional (the cursor may sit left of or inside a match).
    /// The +1 pending-wrap correction handles width-exact input lines where the
    /// grid cursor parks on the last cell but the shell's logical position is one
    /// past it. The final reposition maps the user's original cursor through the
    /// edits (positions right of a span shift by replacement−match; a position
    /// inside a span anchors to just after its replacement).
    static func spliceBytes(
        matches: [(line: Int32, startCol: Int, endCol: Int)],
        cleanedReplacement: Data,
        snapshot: BBSnapshot
    ) -> Result<Data, RefusalReason> {
        let snap = snapshot
        let line = matches[0].line
        let screenRow = Int(line) + snap.displayOffset
        // Character count over the ORIGINAL snapshot; the whole splice is
        // computed against one consistent line state (the shell echoes
        // asynchronously, so re-reading mid-splice would see stale cells).
        func chars(_ startCol: Int, _ endCol: Int) -> Int {
            guard startCol <= endCol else { return 0 }
            return snap.nonSpacerCellCount(
                row: screenRow, startCol: startCol, endCol: endCol
            ) ?? (endCol - startCol + 1)
        }
        // Shell-character length of the replacement, for cursor math.
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
