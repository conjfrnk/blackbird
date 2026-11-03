import XCTest
import AppKit
import Metal
import MetalKit
@testable import Blackbird
import BBCore

/// Blind regression suite for **RA-1: a selection whose start falls on the
/// right half (spacer cell) of a wide glyph copies the glyph but does not
/// highlight it.**
///
/// Authored without reading the implementation of `CellInstanceBuilder`,
/// `MetalRenderer`, `SelectionController` or `core/src/text.rs` (CLAUDE.md,
/// "Author new behavior tests blind"). Only declarations, doc comments, the
/// existing `WideGlyphSelectionStartBlindTests` / `WideGlyphSpacerOverpaintBlindTests`
/// / `BackgroundOnlyQuadAtlasIsolationBlindTests` rigs were consulted.
///
/// Contract. A double-width glyph (CJK ideograph, emoji) is ONE visual object
/// occupying two grid cells (lead + spacer). The pointer cannot see that seam,
/// so what the user sees highlighted and what ⌘C / copy-on-select / Services /
/// drag-out puts on the pasteboard MUST name the same glyphs:
///
///   - a character-mode or rectangular selection with any part of a wide
///     glyph's two cells at its start highlights BOTH cells of that glyph and
///     copies the glyph (`WideGlyphSelectionStartBlindTests` pins the copy
///     half; this suite pins the highlight half AND that the two agree);
///   - highlight and copy never disagree, whichever way a fix resolves an
///     ambiguous gesture (e.g. a bare click that lands on a spacer).
///
/// Oracles.
///   - COPY: `TerminalView.selectedStringForServices()`, the production
///     ⌘C / Services pipeline minus the pasteboard write.
///   - HIGHLIGHT: real pixels. The selection produced by real `mouseDown` /
///     `mouseDragged` / `mouseUp` deliveries on a `TerminalView` (so it is the
///     exact `Selection` the app hands to `MetalRenderer.render(...selection:)`)
///     is rendered by a fresh `MetalRenderer` into an offscreen drawable and
///     read back. A cell is "highlighted" iff its interior renders differently
///     from the same snapshot rendered with no selection (an unselected cell
///     is byte-identical, a selected one changes its whole background and its
///     glyph edges). Pixels are the only oracle that stays valid wherever a
///     fix lives (mouse layer, selection model, per-cell predicate, instance
///     builder), because they are what the user actually sees.
///   - Non-vacuity is asserted, not assumed: a reference frame whose selection
///     starts on a lead cell (the already-correct path) must differ from the
///     no-selection frame at the selected cell and be identical outside it,
///     and the `test_control_*` tests pin that the oracle reports the expected
///     highlight for the already-correct gestures (CJK and emoji). If the host
///     cannot vend/read back an offscreen drawable the suite XCTSkips (same
///     self-guard as `BackgroundOnlyQuadAtlasIsolationBlindTests`) instead of
///     passing.
///
/// Memory + time budget (CLAUDE.md test-authoring rule): per rig one headless
/// 800 x 480 `TerminalView` (never in a window, never drawn) plus one PTY-less
/// headless session resized to 40 x 6 = 240 cells (a few KB). Per rendered
/// frame one `MetalRenderer` (a few MB of instance buffers + ~1 KB atlas at
/// scale 1) and one ~320 x 100 BGRA drawable (~130 KB). At most 2 rigs and
/// 6 frames in any one test, all freed at test end. No `NSWindow`, no
/// `MainWindowController`, no real shell, no runloop pumping. Every gesture
/// stays on interior display rows (2 and 3 of 6) so no edge-autoscroll timer
/// is armed.
final class WideGlyphSelectionHighlightBlindTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        TestHostTermination.shared.register()
    }

    // MARK: - Fixture

    private let gridCols: UInt16 = 40
    private let gridRows: UInt16 = 6

    /// Display row of the first fixture line.
    private let firstRow = 2

    /// Columns 0..<probeCols of a row are inspected for highlight.
    private let probeCols = 10

    /// `中文abc`: 中 = cols 0 (lead) + 1 (spacer), 文 = cols 2 + 3, a = 4, b = 5, c = 6.
    private let cjkLine = "中文abc"
    private let cjkGlyphs: [(text: String, col: Int, width: Int)] = [
        ("中", 0, 2), ("文", 2, 2), ("a", 4, 1), ("b", 5, 1), ("c", 6, 1),
    ]
    private let cjkSpacerOfFirst = 1
    private let cjkLeadOfSecond = 2
    private let cjkSpacerOfSecond = 3
    private let cjkColOfA = 4
    private let cjkColOfC = 6

    /// `😀abc`: 😀 = cols 0 (lead) + 1 (spacer), a = 2, b = 3, c = 4.
    private let emojiLine = "😀abc"
    private let emojiSpacer = 1
    private let emojiColOfC = 4

    private struct Rig {
        let view: TerminalView
        let session: TerminalSession
    }

    private func makeRig(lines: [String],
                         file: StaticString = #filePath,
                         line: UInt = #line) throws -> Rig {
        let device = try requireMetalDevice(file: file, line: line)
        let view = TerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 480),
                                device: device)
        let session = TerminalSession.makeHeadlessForTests()
        addTeardownBlock { session.terminate() }

        let applied = session.coreQueue.sync {
            session.bbterm.resize(to: .init(cols: gridCols, rows: gridRows))
        }
        XCTAssertEqual(applied?.cols, gridCols,
                       "precondition: headless session grid widened to \(gridCols) cols",
                       file: file, line: line)
        XCTAssertEqual(applied?.rows, gridRows,
                       "precondition: headless session grid grown to \(gridRows) rows",
                       file: file, line: line)

        // CSI ?25l hides the text cursor so the rendered frame has no cursor
        // quad; two CR+LF park the first line on display row 2.
        let payload = "\u{1B}[?25l\r\n\r\n" + lines.joined(separator: "\r\n")
        session.feedBytesForTests(Data(payload.utf8))

        view.session = session
        let snap = try XCTUnwrap(session.coreQueue.sync { session.bbterm.snapshot() },
                                 "snapshot() returned nil",
                                 file: file, line: line)
        view.currentSnapshot = snap
        XCTAssertEqual(snap.cols, Int(gridCols), "precondition: snapshot width",
                       file: file, line: line)
        XCTAssertEqual(snap.displayOffset, 0, "precondition: not scrolled back",
                       file: file, line: line)
        XCTAssertEqual(snap.historySize, 0, "precondition: no scrollback, so line == row",
                       file: file, line: line)
        return Rig(view: view, session: session)
    }

    private func assertCell(_ snap: BBSnapshot, row: Int, col: Int,
                            is expected: BBSnapshot.CellKind,
                            file: StaticString = #filePath,
                            line: UInt = #line) {
        XCTAssertEqual(snap.cellKind(at: col, row: row), expected,
                       "fixture: cell (row \(row), col \(col))",
                       file: file, line: line)
    }

    // MARK: - Gestures (real NSEvent deliveries)

    /// View-local point at the centre of grid cell (`row`, `col`). The view is
    /// not flipped; mirrors `WideGlyphSelectionStartBlindTests.localPoint`.
    private func localPoint(row: Int, col: Int, in view: TerminalView) -> NSPoint {
        let textAreaHeight = view.bounds.height - view.titlebarOnlyTopInset
        return NSPoint(
            x: TerminalView.horizontalContentInsetPoints
                + (CGFloat(col) + 0.5) * view.metrics.cellWidth,
            y: textAreaHeight - (CGFloat(row) + 0.5) * view.metrics.cellHeight
        )
    }

    private func mouseEvent(_ type: NSEvent.EventType,
                            at p: NSPoint,
                            modifiers: NSEvent.ModifierFlags,
                            timestamp: TimeInterval,
                            file: StaticString = #filePath,
                            line: UInt = #line) throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(
            with: type,
            location: p,
            modifierFlags: modifiers,
            timestamp: timestamp,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1.0
        ), "NSEvent.mouseEvent returned nil", file: file, line: line)
    }

    private func assertPointMapsToCell(_ rig: Rig, _ p: NSPoint,
                                       row: Int, col: Int, what: String,
                                       file: StaticString, line: UInt) {
        XCTAssertEqual(rig.view.bufferPointFromLocalPoint(p),
                       BufferPoint(line: Int32(row), col: col),
                       "precondition: \(what) point lands on grid cell (\(row), \(col))",
                       file: file, line: line)
    }

    /// One complete single-click drag: press in the centre of `from`, drag to
    /// the centre of `to`, release. `t0` offsets the event timestamps so two
    /// gestures in one test can never be read as a multi-click.
    private func drag(_ rig: Rig,
                      from: (row: Int, col: Int),
                      to: (row: Int, col: Int),
                      modifiers: NSEvent.ModifierFlags = [],
                      t0: TimeInterval = 0,
                      file: StaticString = #filePath,
                      line: UInt = #line) throws {
        let view = rig.view
        let down = localPoint(row: from.row, col: from.col, in: view)
        let up = localPoint(row: to.row, col: to.col, in: view)
        assertPointMapsToCell(rig, down, row: from.row, col: from.col, what: "press",
                              file: file, line: line)
        assertPointMapsToCell(rig, up, row: to.row, col: to.col, what: "release",
                              file: file, line: line)
        view.mouseDown(with: try mouseEvent(.leftMouseDown, at: down, modifiers: modifiers,
                                            timestamp: t0, file: file, line: line))
        view.mouseDragged(with: try mouseEvent(.leftMouseDragged, at: up, modifiers: modifiers,
                                               timestamp: t0 + 0.01, file: file, line: line))
        view.mouseUp(with: try mouseEvent(.leftMouseUp, at: up, modifiers: modifiers,
                                          timestamp: t0 + 0.02, file: file, line: line))
    }

    /// A press + release on one cell with no drag in between.
    private func click(_ rig: Rig,
                       at cell: (row: Int, col: Int),
                       modifiers: NSEvent.ModifierFlags = [],
                       t0: TimeInterval = 0,
                       file: StaticString = #filePath,
                       line: UInt = #line) throws {
        let view = rig.view
        let p = localPoint(row: cell.row, col: cell.col, in: view)
        assertPointMapsToCell(rig, p, row: cell.row, col: cell.col, what: "click",
                              file: file, line: line)
        view.mouseDown(with: try mouseEvent(.leftMouseDown, at: p, modifiers: modifiers,
                                            timestamp: t0, file: file, line: line))
        view.mouseUp(with: try mouseEvent(.leftMouseUp, at: p, modifiers: modifiers,
                                          timestamp: t0 + 0.01, file: file, line: line))
    }

    private func shown(_ s: String?) -> String {
        guard let s else { return "nil" }
        return "\(String(reflecting: s)) (\(s.unicodeScalars.count) scalars)"
    }

    // MARK: - Pixel oracle

    private struct Frame {
        let width: Int
        let height: Int
        /// Drawable pixels per view point (1 on this rig; derived, not assumed).
        let pxPerPoint: Double
        let bytes: [UInt8]   // BGRA, row 0 at top

        func pixel(_ x: Int, _ y: Int) -> [UInt8] {
            let o = (y * width + x) * 4
            return Array(bytes[o..<(o + 4)])
        }

        func isPixel(_ x: Int, _ y: Int, equalTo ref: [UInt8]) -> Bool {
            let o = (y * width + x) * 4
            return bytes[o] == ref[0] && bytes[o + 1] == ref[1]
                && bytes[o + 2] == ref[2] && bytes[o + 3] == ref[3]
        }
    }

    private lazy var cachedMetrics: CellMetrics =
        CellMetrics(font: .monospacedSystemFont(ofSize: 13, weight: .regular))

    private func makeMetrics() -> CellMetrics { cachedMetrics }

    /// Render the view's current snapshot with `selection` through a fresh
    /// `MetalRenderer` (scale 1, no insets) into an offscreen drawable and
    /// read it back. XCTSkips when the host can't vend/read the drawable.
    private func renderFrame(of rig: Rig,
                             selection: Selection?,
                             file: StaticString = #filePath,
                             line: UInt = #line) throws -> Frame {
        let device = try requireMetalDevice(file: file, line: line)
        let metrics = makeMetrics()
        let renderer = try XCTUnwrap(MetalRenderer(device: device, metrics: metrics, scale: 1),
                                     "MetalRenderer init failed", file: file, line: line)
        let snap = try XCTUnwrap(rig.view.currentSnapshot, "snapshot missing",
                                 file: file, line: line)
        let w = Int((Double(gridCols) * Double(metrics.cellWidth)).rounded(.up)) + 8
        let h = Int((Double(gridRows) * Double(metrics.cellHeight)).rounded(.up)) + 8

        let view = MTKView(frame: NSRect(x: 0, y: 0, width: w, height: h), device: device)
        view.isPaused = true
        view.enableSetNeedsDisplay = false
        view.colorPixelFormat = .bgra8Unorm
        view.framebufferOnly = false
        view.autoResizeDrawable = false
        view.drawableSize = CGSize(width: w, height: h)

        // Treat the core's default bg as "no bg quad", as the app does
        // (TerminalView.applyTheme -> setDefaultBgRgb): the last cell of the
        // last row is never written by the fixture.
        renderer.setDefaultBgRgb(snap.cellsPointer[snap.cols * snap.rows - 1].bg)

        renderer.render(in: view, snapshot: snap, focused: true, selection: selection)
        if renderer.didFrameSkipLastRender {
            throw XCTSkip("renderer skipped the frame; no pixels to read")
        }
        guard let drain = renderer.atlas.flushBarrier else {
            throw XCTSkip("atlas flushBarrier unavailable; cannot order readback behind the frame")
        }
        drain()
        guard let tex = view.currentDrawable?.texture,
              tex.pixelFormat == .bgra8Unorm, tex.width > 0, tex.height > 0 else {
            throw XCTSkip("host cannot vend/read back an offscreen drawable")
        }
        let tw = tex.width, th = tex.height
        var bytes = [UInt8](repeating: 0, count: tw * th * 4)
        bytes.withUnsafeMutableBytes { (p: UnsafeMutableRawBufferPointer) -> Void in
            tex.getBytes(p.baseAddress!, bytesPerRow: tw * 4,
                         from: MTLRegionMake2D(0, 0, tw, th), mipmapLevel: 0)
        }
        view.releaseDrawables()
        return Frame(width: tw, height: th,
                     pxPerPoint: Double(tw) / Double(w), bytes: bytes)
    }

    /// Inclusive pixel rect strictly inside grid cell (`col`, `row`): 2 px in
    /// from the left/right edges and 1 px from the top/bottom, so a quad edge
    /// that rounds a pixel either way can never leak a neighbour's colour in.
    private func interior(col: Int, row: Int, in f: Frame) -> (x0: Int, x1: Int, y0: Int, y1: Int) {
        let m = makeMetrics()
        let cw = Double(m.cellWidth) * f.pxPerPoint
        let ch = Double(m.cellHeight) * f.pxPerPoint
        let x0 = Int((Double(col) * cw).rounded(.up)) + 2
        let x1 = Int((Double(col + 1) * cw).rounded(.down)) - 3
        let y0 = Int((Double(row) * ch).rounded(.up)) + 1
        let y1 = Int((Double(row + 1) * ch).rounded(.down)) - 2
        return (x0, min(x1, f.width - 1), y0, min(y1, f.height - 1))
    }

    private func centerPixel(col: Int, row: Int, in f: Frame) -> [UInt8] {
        let r = interior(col: col, row: row, in: f)
        return f.pixel((r.x0 + r.x1) / 2, (r.y0 + r.y1) / 2)
    }

    /// How many pixels in the interior of (`col`, `row`) differ between `f`
    /// and the same snapshot rendered with NO selection. The frames are
    /// rendered by identical fresh renderers from one snapshot, so an
    /// unselected cell is byte-identical (count 0) and a selected one changes
    /// every background pixel and every glyph edge pixel. (Counting pixels that
    /// merely equal the tint colour is not enough: a colour emoji bitmap
    /// covers the middle of its two cells, leaving only the corners tinted.)
    private func changedPixelCount(col: Int, row: Int, in f: Frame, baseline: Frame) -> Int {
        let r = interior(col: col, row: row, in: f)
        var n = 0
        for y in r.y0...r.y1 {
            for x in r.x0...r.x1 where f.pixel(x, y) != baseline.pixel(x, y) { n += 1 }
        }
        return n
    }

    /// Reference pixels measured from frames that do not depend on the bug:
    /// `baseline` = the snapshot rendered with no selection, `tint` = a cell
    /// selected from a lead cell, `background` = an untouched cell.
    private struct Palette {
        let baseline: Frame
        let tint: [UInt8]
        let background: [UInt8]
    }

    private func measurePalette(of rig: Rig,
                                file: StaticString = #filePath,
                                line: UInt = #line) throws -> Palette {
        let baseline = try renderFrame(of: rig, selection: nil, file: file, line: line)
        let ref = try renderFrame(
            of: rig,
            selection: Selection(anchor: BufferPoint(line: Int32(firstRow), col: 0),
                                 cursor: BufferPoint(line: Int32(firstRow), col: probeCols - 1),
                                 mode: .character),
            file: file, line: line)
        let tint = centerPixel(col: probeCols - 1, row: firstRow, in: ref)
        let bg = centerPixel(col: probeCols - 1, row: firstRow, in: baseline)
        XCTAssertNotEqual(tint, bg,
                          "precondition: selecting an empty cell must change its pixels (tint \(tint) vs "
                              + "background \(bg)) or the highlight oracle is vacuous",
                          file: file, line: line)
        XCTAssertEqual(centerPixel(col: Int(gridCols) - 2, row: 0, in: ref),
                       centerPixel(col: Int(gridCols) - 2, row: 0, in: baseline),
                       "precondition: a cell outside the selection renders identically with and without it",
                       file: file, line: line)
        return Palette(baseline: baseline, tint: tint, background: bg)
    }

    /// Highlight string for columns 0..<probeCols of `row`: `T` = the cell
    /// interior changed under the selection (>= 6 pixels), `F` = not at all,
    /// `?` = only a few (neither clearly selected nor clearly not; reported,
    /// never guessed). `counts` are the changed-pixel counts per column.
    private func highlightMap(row: Int, in f: Frame, palette: Palette) -> (map: String, counts: [Int]) {
        var chars = ""
        var counts: [Int] = []
        for col in 0..<probeCols {
            let n = changedPixelCount(col: col, row: row, in: f, baseline: palette.baseline)
            counts.append(n)
            chars += n >= 6 ? "T" : (n == 0 ? "F" : "?")
        }
        return (chars, counts)
    }

    /// Highlight string for `row` as the app would draw the rig's current selection.
    private func renderedHighlight(of rig: Rig, palette: Palette, row: Int,
                                   file: StaticString = #filePath,
                                   line: UInt = #line) throws -> (map: String, counts: [Int]) {
        let f = try renderFrame(of: rig, selection: rig.view.selection, file: file, line: line)
        return highlightMap(row: row, in: f, palette: palette)
    }

    /// The highlight string a copy of `copied` implies for a single row made
    /// of `glyphs`: the copy must be a contiguous run of that row's glyphs;
    /// every cell of every copied glyph is expected highlighted, nothing else.
    /// nil if `copied` is not such a run.
    private func highlightImplied(byCopied copied: String?,
                                  glyphs: [(text: String, col: Int, width: Int)]) -> String? {
        let copiedGlyphs = (copied ?? "").filter { !$0.isNewline }.map { String($0) }
        var highlighted = [Bool](repeating: false, count: probeCols)
        if !copiedGlyphs.isEmpty {
            let texts: [String] = glyphs.map { (g: (text: String, col: Int, width: Int)) -> String in g.text }
            if copiedGlyphs.count > texts.count { return nil }
            var matched = false
            for start in 0...(texts.count - copiedGlyphs.count) {
                let end = start + copiedGlyphs.count
                if Array(texts[start..<end]) != copiedGlyphs { continue }
                for g in glyphs[start..<end] {
                    for c in g.col..<(g.col + g.width) where c < probeCols { highlighted[c] = true }
                }
                matched = true
                break
            }
            if !matched { return nil }
        }
        return highlighted.map { $0 ? "T" : "F" }.joined()
    }

    // MARK: - Fixture self-check

    func test_fixture_wideGlyphsOccupyLeadAndSpacerCells() throws {
        let rig = try makeRig(lines: [cjkLine, emojiLine])
        let snap = try XCTUnwrap(rig.view.currentSnapshot, "snapshot missing")
        assertCell(snap, row: firstRow, col: 0, is: .character("中"))
        assertCell(snap, row: firstRow, col: 1, is: .spacer)
        assertCell(snap, row: firstRow, col: 2, is: .character("文"))
        assertCell(snap, row: firstRow, col: 3, is: .spacer)
        assertCell(snap, row: firstRow, col: 4, is: .character("a"))
        assertCell(snap, row: firstRow, col: 6, is: .character("c"))
        assertCell(snap, row: firstRow + 1, col: 0, is: .character("😀"))
        assertCell(snap, row: firstRow + 1, col: 1, is: .spacer)
        assertCell(snap, row: firstRow + 1, col: 2, is: .character("a"))
    }

    // MARK: - Controls (already-correct behaviour; must pass before and after the fix)

    /// Baseline for the pixel oracle: a drag from the LEADING cell highlights
    /// the whole line and copies it. If this fails the harness, not the bug,
    /// is broken.
    func test_control_dragFromLeadingCell_highlightsAndCopiesWholeLine() throws {
        let rig = try makeRig(lines: [cjkLine])
        let palette = try measurePalette(of: rig)
        try drag(rig, from: (firstRow, 0), to: (firstRow, cjkColOfC))
        let sel = try XCTUnwrap(rig.view.selection, "a real drag must leave a selection")
        XCTAssertEqual(sel.mode, .character, "precondition: character-mode selection")

        let copied = rig.view.selectedStringForServices()
        let hl = try renderedHighlight(of: rig, palette: palette, row: firstRow)
        XCTAssertEqual(copied, "中文abc", "control: copy; got \(shown(copied))")
        XCTAssertEqual(hl.map, "TTTTTTTFFF",
                       "control: highlight cols 0-9 (T=highlighted); changed-pixel counts per col \(hl.counts)")
    }

    /// A selection whose END falls on a glyph's spacer already highlights and
    /// copies that glyph (only a spacer at the START is broken).
    func test_control_dragEndingOnSpacer_highlightsAndCopiesThatGlyph() throws {
        let rig = try makeRig(lines: [cjkLine])
        let palette = try measurePalette(of: rig)
        try drag(rig, from: (firstRow, 0), to: (firstRow, cjkSpacerOfSecond))

        let copied = rig.view.selectedStringForServices()
        let hl = try renderedHighlight(of: rig, palette: palette, row: firstRow)
        XCTAssertEqual(copied, "中文", "control: copy; got \(shown(copied))")
        XCTAssertEqual(hl.map, "TTTTFFFFFF",
                       "control: highlight cols 0-9; changed-pixel counts per col \(hl.counts)")
    }

    /// Baseline for the emoji half of the oracle: a drag from 😀's LEADING
    /// cell tints both of its cells (measurable despite the colour bitmap
    /// covering the middle of the glyph) and copies it.
    func test_control_dragFromLeadingCellOfEmoji_highlightsAndCopiesTheGlyph() throws {
        let rig = try makeRig(lines: [emojiLine])
        let palette = try measurePalette(of: rig)
        try drag(rig, from: (firstRow, 0), to: (firstRow, emojiColOfC))

        let copied = rig.view.selectedStringForServices()
        let hl = try renderedHighlight(of: rig, palette: palette, row: firstRow)
        XCTAssertEqual(copied, "😀abc", "control: copy; got \(shown(copied))")
        XCTAssertEqual(hl.map, "TTTTTFFFFF",
                       "control: highlight cols 0-9 (T=highlighted); changed-pixel counts per col \(hl.counts)")
    }

    // MARK: - The bug: character-mode drag that STARTS on a spacer

    /// Headline repro. Press on the right half of 中 (col 1), drag to `c`.
    /// 中 must be tinted (both cells) AND copied; the bug copies it untinted.
    func test_characterDrag_startingOnRightHalfOfFirstGlyph_highlightsTheGlyphItCopies() throws {
        let rig = try makeRig(lines: [cjkLine])
        let palette = try measurePalette(of: rig)
        try drag(rig, from: (firstRow, cjkSpacerOfFirst), to: (firstRow, cjkColOfC))
        let sel = try XCTUnwrap(rig.view.selection, "a real drag must leave a selection")
        XCTAssertEqual(sel.mode, .character, "precondition: character-mode selection")

        let copied = rig.view.selectedStringForServices()
        let hl = try renderedHighlight(of: rig, palette: palette, row: firstRow)
        XCTAssertEqual(copied, "中文abc",
                       "starting on the right half of 中 must copy 中; got \(shown(copied))")
        XCTAssertEqual(hl.map, "TTTTTTTFFF",
                       "starting on the right half of 中 must tint BOTH cells of 中 (cols 0-1), "
                           + "the glyph that is copied (copy was \(shown(copied))); "
                           + "highlight cols 0-9 (T=highlighted), changed-pixel counts per col \(hl.counts)")
    }

    /// Same defect one glyph later: start on the right half of 文 (col 3).
    func test_characterDrag_startingOnRightHalfOfSecondGlyph_highlightsTheGlyphItCopies() throws {
        let rig = try makeRig(lines: [cjkLine])
        let palette = try measurePalette(of: rig)
        try drag(rig, from: (firstRow, cjkSpacerOfSecond), to: (firstRow, cjkColOfC))

        let copied = rig.view.selectedStringForServices()
        let hl = try renderedHighlight(of: rig, palette: palette, row: firstRow)
        XCTAssertEqual(copied, "文abc",
                       "starting on the right half of 文 must copy 文; got \(shown(copied))")
        XCTAssertEqual(hl.map, "FFTTTTTFFF",
                       "starting on the right half of 文 must tint BOTH cells of 文 (cols 2-3), "
                           + "the glyph that is copied (copy was \(shown(copied))); "
                           + "highlight cols 0-9, changed-pixel counts per col \(hl.counts)")
    }

    /// BACKWARD drag: press on `c`, release on 中's spacer. The spacer is then
    /// the normalized START of the range; same contract as the forward drag.
    func test_characterDrag_backwardEndingOnRightHalfOfFirstGlyph_highlightsTheGlyphItCopies() throws {
        let rig = try makeRig(lines: [cjkLine])
        let palette = try measurePalette(of: rig)
        try drag(rig, from: (firstRow, cjkColOfC), to: (firstRow, cjkSpacerOfFirst))

        let copied = rig.view.selectedStringForServices()
        let hl = try renderedHighlight(of: rig, palette: palette, row: firstRow)
        XCTAssertEqual(copied, "中文abc",
                       "a backward drag ending on the right half of 中 must copy 中; got \(shown(copied))")
        XCTAssertEqual(hl.map, "TTTTTTTFFF",
                       "a backward drag ending on the right half of 中 must tint BOTH cells of 中, "
                           + "the glyph that is copied (copy was \(shown(copied))); "
                           + "highlight cols 0-9, changed-pixel counts per col \(hl.counts)")
    }

    /// "Press on the right of the line, release on that spacer": the press is
    /// on an empty cell well past `c`, the release on 中's right half. The
    /// selection runs spacer .. col 12, so every probed column is inside it.
    func test_characterDrag_fromEmptyCellRightOfLineBackToSpacer_highlightsTheGlyphItCopies() throws {
        let rig = try makeRig(lines: [cjkLine])
        let palette = try measurePalette(of: rig)
        try drag(rig, from: (firstRow, 12), to: (firstRow, cjkSpacerOfFirst))

        let copied = rig.view.selectedStringForServices()
        let trimmed = copied?.trimmingCharacters(in: .whitespacesAndNewlines)
        let hl = try renderedHighlight(of: rig, palette: palette, row: firstRow)
        XCTAssertEqual(trimmed, "中文abc",
                       "a drag from past the end of the line back onto the right half of 中 must copy 中; "
                           + "got \(shown(copied))")
        XCTAssertEqual(hl.map, "TTTTTTTTTT",
                       "a drag from past the end of the line back onto the right half of 中 must tint BOTH "
                           + "cells of 中, the glyph that is copied (copy was \(shown(copied))); "
                           + "highlight cols 0-9, changed-pixel counts per col \(hl.counts)")
    }

    /// Emoji are the other wide-glyph family: 😀 = cols 0-1.
    func test_characterDrag_startingOnRightHalfOfEmoji_highlightsTheGlyphItCopies() throws {
        let rig = try makeRig(lines: [emojiLine])
        let snap = try XCTUnwrap(rig.view.currentSnapshot, "snapshot missing")
        assertCell(snap, row: firstRow, col: 0, is: .character("😀"))
        assertCell(snap, row: firstRow, col: emojiSpacer, is: .spacer)
        let palette = try measurePalette(of: rig)
        try drag(rig, from: (firstRow, emojiSpacer), to: (firstRow, emojiColOfC))

        let copied = rig.view.selectedStringForServices()
        let hl = try renderedHighlight(of: rig, palette: palette, row: firstRow)
        XCTAssertEqual(copied, "😀abc",
                       "starting on the right half of 😀 must copy 😀; got \(shown(copied))")
        XCTAssertEqual(hl.map, "TTTTTFFFFF",
                       "starting on the right half of 😀 must tint BOTH cells of 😀 (cols 0-1), "
                           + "the glyph that is copied (copy was \(shown(copied))); "
                           + "highlight cols 0-9, changed-pixel counts per col \(hl.counts)")
    }

    // MARK: - The bug: rectangular (Option) drag that STARTS on a spacer

    func test_rectangularDrag_startingOnRightHalfOfFirstGlyph_highlightsTheGlyphItCopies() throws {
        let rig = try makeRig(lines: [cjkLine])
        let palette = try measurePalette(of: rig)
        try drag(rig, from: (firstRow, cjkSpacerOfFirst), to: (firstRow, cjkColOfC),
                 modifiers: [.option])
        let sel = try XCTUnwrap(rig.view.selection, "a real drag must leave a selection")
        XCTAssertEqual(sel.mode, .rectangular, "precondition: Option-drag is a rectangular selection")

        let copied = rig.view.selectedStringForServices()
        let hl = try renderedHighlight(of: rig, palette: palette, row: firstRow)
        XCTAssertEqual(copied, "中文abc",
                       "rectangular drag starting on the right half of 中 must copy 中; got \(shown(copied))")
        XCTAssertEqual(hl.map, "TTTTTTTFFF",
                       "rectangular drag starting on the right half of 中 must tint BOTH cells of 中, "
                           + "the glyph that is copied (copy was \(shown(copied))); "
                           + "highlight cols 0-9, changed-pixel counts per col \(hl.counts)")
    }

    /// Two identical rows: the rectangle's left edge falls on a spacer in
    /// EVERY row it spans, so every row must tint and copy its leading glyph.
    func test_rectangularDrag_twoRows_startingOnSpacer_highlightsTheGlyphOnEveryRow() throws {
        let rig = try makeRig(lines: [cjkLine, cjkLine])
        let snap = try XCTUnwrap(rig.view.currentSnapshot, "snapshot missing")
        assertCell(snap, row: firstRow + 1, col: cjkSpacerOfFirst, is: .spacer)
        let palette = try measurePalette(of: rig)
        try drag(rig, from: (firstRow, cjkSpacerOfFirst), to: (firstRow + 1, cjkColOfC),
                 modifiers: [.option])
        let sel = try XCTUnwrap(rig.view.selection, "a real drag must leave a selection")
        XCTAssertEqual(sel.mode, .rectangular, "precondition: Option-drag is a rectangular selection")

        let copied = rig.view.selectedStringForServices()
        let rows = (copied ?? "").split(whereSeparator: \.isNewline).map(String.init)
        let f = try renderFrame(of: rig, selection: rig.view.selection)
        let top = highlightMap(row: firstRow, in: f, palette: palette)
        let bottom = highlightMap(row: firstRow + 1, in: f, palette: palette)
        XCTAssertEqual(rows, ["中文abc", "中文abc"],
                       "each rectangle row must copy the glyph under its left edge; got \(shown(copied))")
        XCTAssertEqual(top.map, "TTTTTTTFFF",
                       "rectangle row 1: 中 must be tinted (both cells) like it is copied; "
                           + "changed-pixel counts per col \(top.counts)")
        XCTAssertEqual(bottom.map, "TTTTTTTFFF",
                       "rectangle row 2: 中 must be tinted (both cells) like it is copied; "
                           + "changed-pixel counts per col \(bottom.counts)")
    }

    // MARK: - Highlight and copy must agree for the ambiguous gestures

    /// CONTROL (agreement rule; must hold before and after the fix). A bare
    /// click (press + release, no drag) on the right half of 中. A fix
    /// may legitimately resolve it as "no selection" (like a bare click on a
    /// narrow glyph) or as "select the glyph"; what it must NEVER do is copy
    /// the glyph while showing nothing, or show it while copying nothing.
    func test_control_bareClickOnRightHalfOfGlyph_highlightAgreesWithCopy() throws {
        let rig = try makeRig(lines: [cjkLine])
        let palette = try measurePalette(of: rig)
        try click(rig, at: (firstRow, cjkSpacerOfFirst))

        let copied = rig.view.selectedStringForServices()
        let hl = try renderedHighlight(of: rig, palette: palette, row: firstRow)
        let implied = try XCTUnwrap(
            highlightImplied(byCopied: copied, glyphs: cjkGlyphs),
            "the copy \(shown(copied)) is not a contiguous run of the row's glyphs")
        XCTAssertEqual(hl.map, implied,
                       "a bare click on the right half of 中 copied \(shown(copied)): the highlight "
                           + "(cols 0-9, T=highlighted) must show exactly what is copied; "
                           + "selection after the click: \(String(describing: rig.view.selection)); "
                           + "changed-pixel counts per col \(hl.counts)")
    }

    /// Shift-click that lands on a spacer with the cursor moving BELOW (before)
    /// the anchor: the spacer becomes the normalized start of the selection.
    func test_shiftClickOnSpacerBelowAnchor_highlightAgreesWithCopy() throws {
        let rig = try makeRig(lines: [cjkLine])
        let palette = try measurePalette(of: rig)
        // Anchor on `c` (col 6), cursor dragged to `a` (col 4).
        try drag(rig, from: (firstRow, cjkColOfC), to: (firstRow, cjkColOfA))
        let first = try XCTUnwrap(rig.view.selection, "precondition: the first drag leaves a selection")
        XCTAssertEqual(first.mode, .character, "precondition: character-mode selection")
        // Shift-click on 中's right half, far in time from the drag so it can
        // never be read as a multi-click.
        try click(rig, at: (firstRow, cjkSpacerOfFirst), modifiers: [.shift], t0: 5.0)
        let extended = try XCTUnwrap(rig.view.selection,
                                     "precondition: shift-click extends the selection (still present)")
        XCTAssertNotEqual(extended, first,
                          "precondition: shift-click on col \(cjkSpacerOfFirst) changed the selection "
                              + "(before \(first), after \(extended))")

        let copied = rig.view.selectedStringForServices()
        let hl = try renderedHighlight(of: rig, palette: palette, row: firstRow)
        XCTAssertTrue((copied ?? "").hasPrefix("中"),
                      "a selection starting on the right half of 中 must copy 中 first; got \(shown(copied))")
        let implied = try XCTUnwrap(
            highlightImplied(byCopied: copied, glyphs: cjkGlyphs),
            "the copy \(shown(copied)) is not a contiguous run of the row's glyphs")
        XCTAssertEqual(hl.map, implied,
                       "after a shift-click onto the right half of 中 the highlight (cols 0-9, T=highlighted) "
                           + "must show exactly what is copied (\(shown(copied))); "
                           + "selection: \(extended); changed-pixel counts per col \(hl.counts)")
    }
}
