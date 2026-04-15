import Foundation
import BBCore

/// Swift wrapper over the BBCore C ABI. Owns a single BBTerm and guarantees
/// freeing on deinit. Not Sendable — must be used from a single serial queue
/// (the `core` queue in a TerminalSession).
public final class BBTerm {
    public struct Size: Equatable {
        public var cols: UInt16
        public var rows: UInt16
        public init(cols: UInt16, rows: UInt16) {
            self.cols = cols
            self.rows = rows
        }
    }

    public enum Event {
        case title(String)
        case bell
        case cursorShape(Int)
        case osc52Clipboard(String)
        case fatal(String)
    }

    public typealias EventHandler = (Event) -> Void

    // 'struct BBTerm' is an opaque forward declaration in BBCore.h;
    // Swift imports struct BBTerm * as OpaquePointer throughout.
    private var handle: OpaquePointer?
    private var handler: EventHandler?
    private let ctxBox: UnsafeMutablePointer<EventCtx>

    private final class EventCtx {
        weak var owner: BBTerm?
    }

    public init?(size: Size, scrollback: UInt32 = 10_000) {
        guard let ptr = bb_term_new(size.cols, size.rows, scrollback) else { return nil }
        self.handle = ptr

        let box = UnsafeMutablePointer<EventCtx>.allocate(capacity: 1)
        box.initialize(to: EventCtx())
        self.ctxBox = box

        // Set the weak back-reference after self is fully initialized.
        box.pointee.owner = self
        bb_term_set_event_cb(ptr, BBTerm.eventTrampoline, UnsafeMutableRawPointer(box))
    }

    deinit {
        if let h = handle {
            bb_term_set_event_cb(h, nil, nil)
            bb_term_free(h)
        }
        ctxBox.deinitialize(count: 1)
        ctxBox.deallocate()
    }

    public func onEvent(_ handler: @escaping EventHandler) {
        self.handler = handler
    }

    public func input(_ bytes: [UInt8]) {
        guard let h = handle else { return }
        bytes.withUnsafeBufferPointer { buf in
            bb_term_input(h, buf.baseAddress, UInt(buf.count))
        }
    }

    public func input(_ string: String) {
        input(Array(string.utf8))
    }

    public func resize(to size: Size) {
        guard let h = handle else { return }
        bb_term_resize(h, size.cols, size.rows)
    }

    public func snapshot() -> BBSnapshot? {
        guard let h = handle else { return nil }
        guard let raw = bb_term_take_snapshot(h) else { return nil }
        return BBSnapshot(retaining: raw)
    }

    // MARK: - Event trampoline

    private static let eventTrampoline: @convention(c) (BBEvent, UnsafeMutableRawPointer?) -> Void = { ev, ctx in
        guard let ctx else { return }
        let box = ctx.assumingMemoryBound(to: EventCtx.self)
        guard let owner = box.pointee.owner else { return }
        owner.dispatch(ev)
    }

    private func dispatch(_ ev: BBEvent) {
        guard let handler else { return }
        // BBEventKind is typedef uint32_t in C. ev.kind is UInt32.
        // The BB_EVENT_KIND_* constants are C enum variants; use their integer
        // values directly to avoid Swift 6 cross-module typedef comparison issues.
        switch ev.kind {
        case 1:   // BB_EVENT_KIND_TITLE
            handler(.title(Self.string(from: ev)))
        case 2:   // BB_EVENT_KIND_BELL
            handler(.bell)
        case 3:   // BB_EVENT_KIND_CURSOR_SHAPE
            handler(.cursorShape(Int(ev.i32_arg)))
        case 4:   // BB_EVENT_KIND_OSC52_CLIPBOARD
            handler(.osc52Clipboard(Self.string(from: ev)))
        case 99:  // BB_EVENT_KIND_FATAL
            handler(.fatal(Self.string(from: ev)))
        default:
            break
        }
    }

    private static func string(from ev: BBEvent) -> String {
        guard let ptr = ev.payload, ev.len > 0 else { return "" }
        let buf = UnsafeBufferPointer(start: ptr, count: Int(ev.len))
        return String(decoding: buf, as: UTF8.self)
    }
}

/// Immutable snapshot of the grid. Holds a ref until deinit.
public final class BBSnapshot {
    private let handle: UnsafePointer<BBSnap>

    init(retaining raw: UnsafePointer<BBSnap>) {
        self.handle = raw
    }

    deinit {
        bb_snap_release(handle)
    }

    public var cols: Int { Int(handle.pointee.cols) }
    public var rows: Int { Int(handle.pointee.rows) }
    public var cursorCol: Int { Int(handle.pointee.cursor_col) }
    public var cursorRow: Int { Int(handle.pointee.cursor_row) }
    public var cursorVisible: Bool { handle.pointee.cursor_visible != 0 }

    public func character(at col: Int, row: Int) -> Character? {
        guard col < cols, row < rows else { return nil }
        let idx = row * cols + col
        let scalar = handle.pointee.cells[idx].ch
        guard scalar != 0, let us = Unicode.Scalar(scalar) else { return nil }
        return Character(us)
    }
}
