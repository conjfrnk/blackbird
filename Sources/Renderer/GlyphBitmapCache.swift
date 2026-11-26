import Foundation
import os

/// Process-wide cache of rasterised glyph bitmaps, shared across every `GlyphAtlas`.
enum GlyphBitmapCache {

    /// Everything that determines the rasterised pixels.
    struct Key: Hashable {
        let fontName: String
        /// Point size × 100, rounded.
        let sizeQ: Int
        /// Backing scale × 100, rounded.
        let scaleQ: Int
        let scalar: UInt32
        let bold: Bool
        let italic: Bool
        let wide: Bool
        let isColor: Bool
        /// Bare base scalar vs. base + VS16: these can share `(scalar, wide, isColor)` yet rasterise differently.
        let emojiPresentation: Bool
    }

    struct Bitmap {
        let bytes: [UInt8]
        let width: Int
        let height: Int
        let bytesPerRow: Int

        init(bytes: [UInt8], width: Int, height: Int, bytesPerRow: Int) {
            assert(
                bytes.count == height * bytesPerRow,
                "GlyphBitmapCache.Bitmap: bytes.count \(bytes.count) != height*bytesPerRow \(height * bytesPerRow)"
            )
            assert(
                width >= 1 && height >= 1 && bytesPerRow >= width,
                "GlyphBitmapCache.Bitmap: degenerate dims w=\(width) h=\(height) bytesPerRow=\(bytesPerRow)"
            )
            self.bytes = bytes
            self.width = width
            self.height = height
            self.bytesPerRow = bytesPerRow
        }
    }

    private static let maxEntries = 4096

    /// A lock, not @MainActor: atlases are also constructed off the main thread.
    /// Invariant: every group in `order` has entries in `dict`, and vice versa.
    private struct State {
        var dict: [Key: Bitmap] = [:]
        var order: [Group] = []
        var evictions = 0
    }
    private static let storage = OSAllocatedUnfairLock<State>(initialState: State())

    /// The unit of eviction.
    struct Group: Hashable {
        let fontName: String
        let sizeQ: Int
        let scaleQ: Int
        init(_ k: Key) { fontName = k.fontName; sizeQ = k.sizeQ; scaleQ = k.scaleQ }
    }
    static var evictionCount: Int { storage.withLock { $0.evictions } }

    /// Only written inside `storage.withLock`.
    private static var saturationLogged = false
    private static let logger = Logger(
        subsystem: "dev.conjfrnk.blackbird", category: "atlas"
    )

    /// Presumes finite, in-range input.
    static func quantize(_ value: CGFloat) -> Int { Int((value * 100).rounded()) }

    static func get(_ key: Key) -> Bitmap? {
        storage.withLock { $0.dict[key] }
    }

    static func put(_ key: Key, _ bitmap: Bitmap) {
        let group = Group(key)
        storage.withLock { state in
            if state.dict[key] == nil && state.dict.count >= maxEntries {
                guard let victim = state.order.first(where: { $0 != group }) else {
                    if !saturationLogged {
                        saturationLogged = true
                        logger.notice(
                            "GlyphBitmapCache saturated at \(maxEntries, privacy: .public) entries within one font set — new glyphs rasterise uncached (logged once)"
                        )
                    }
                    return
                }
                state.dict = state.dict.filter { Group($0.key) != victim }
                state.order.removeAll { $0 == victim }
                state.evictions &+= 1
                logger.log("GlyphBitmapCache evicted font set \(victim.fontName, privacy: .public)@\(victim.sizeQ, privacy: .public)/\(victim.scaleQ, privacy: .public) to admit new glyphs")
            }
            if state.dict[key] == nil, !state.order.contains(group) {
                state.order.append(group)
            }
            state.dict[key] = bitmap
        }
    }

    #if DEBUG
    static var _countForTests: Int { storage.withLock { $0.dict.count } }
    static func _resetForTests() {
        storage.withLock { $0 = State() }
    }
    #endif
}
