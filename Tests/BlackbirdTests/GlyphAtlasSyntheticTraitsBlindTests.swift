import XCTest
import Metal
import AppKit
import CoreText
@testable import Blackbird

/// Blind tests for `GlyphAtlas.syntheticTraits(for:)`: a style trait is
/// synthesised only when the font family has no real face for it. The
/// expected answer is derived from an independent CoreText probe on this
/// machine so the assertions can't drift with the installed font set.
/// Cost: three tiny atlases (capacity 4) — negligible.
final class GlyphAtlasSyntheticTraitsBlindTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        TestHostTermination.shared.register()
    }

    // MARK: - Fixtures

    private func makeAtlas(font: NSFont) throws -> GlyphAtlas {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("No Metal device on this host")
        }
        return try XCTUnwrap(GlyphAtlas(
            device: device, metrics: CellMetrics(font: font), capacityGlyphs: 4, scale: 1
        ))
    }

    /// Independent probe: does CoreText give us a face carrying `trait`
    /// for this font? If not, the atlas must fake it.
    private func hasRealFace(_ font: NSFont, _ trait: CTFontSymbolicTraits) -> Bool {
        guard let styled = CTFontCreateCopyWithSymbolicTraits(font as CTFont, 0, nil, trait, trait) else {
            return false
        }
        return CTFontGetSymbolicTraits(styled).contains(trait)
    }

    // MARK: - Family with real bold + italic

    func test_systemMono_regularStyleNeedsNoSynthesis() throws {
        let atlas = try makeAtlas(font: .monospacedSystemFont(ofSize: 13, weight: .regular))
        let t = atlas.syntheticTraits(for: .regular)
        XCTAssertFalse(t.bold)
        XCTAssertFalse(t.italic)
    }

    func test_systemMono_boldItalicUsesRealFaces() throws {
        let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        // Pre-condition of the spec: SF Mono has real bold and italic faces.
        XCTAssertTrue(hasRealFace(font, .boldTrait), "fixture: SF Mono should have a real bold face")
        XCTAssertTrue(hasRealFace(font, .italicTrait), "fixture: SF Mono should have a real italic face")
        let atlas = try makeAtlas(font: font)
        let t = atlas.syntheticTraits(for: GlyphAtlas.Style(bold: true, italic: true))
        XCTAssertFalse(t.bold, "real bold face exists — must not synthesise")
        XCTAssertFalse(t.italic, "real italic face exists — must not synthesise")
        let b = atlas.syntheticTraits(for: GlyphAtlas.Style(bold: true, italic: false))
        XCTAssertFalse(b.bold)
        XCTAssertFalse(b.italic)
        let i = atlas.syntheticTraits(for: GlyphAtlas.Style(bold: false, italic: true))
        XCTAssertFalse(i.bold)
        XCTAssertFalse(i.italic)
    }

    // MARK: - Menlo: real bold, no italic (on stock macOS)

    func test_menlo_syntheticItalicOnly_boldIsReal() throws {
        let font = try XCTUnwrap(NSFont(name: "Menlo-Regular", size: 13))
        let atlas = try makeAtlas(font: font)
        let realBold = hasRealFace(font, .boldTrait)
        let realItalic = hasRealFace(font, .italicTrait)
        XCTAssertTrue(realBold, "fixture: Menlo ships Menlo-Bold")

        let t = atlas.syntheticTraits(for: GlyphAtlas.Style(bold: true, italic: true))
        XCTAssertEqual(t.bold, !realBold, "bold synthesised iff no real bold face")
        XCTAssertEqual(t.italic, !realItalic, "italic synthesised iff no real italic face")
        if !realItalic {
            // The stock-macOS expectation, stated explicitly.
            XCTAssertFalse(t.bold)
            XCTAssertTrue(t.italic)
        }
    }

    func test_menlo_boldOnlyStyleNeverSynthesisesItalic() throws {
        let font = try XCTUnwrap(NSFont(name: "Menlo-Regular", size: 13))
        let atlas = try makeAtlas(font: font)
        let t = atlas.syntheticTraits(for: GlyphAtlas.Style(bold: true, italic: false))
        XCTAssertFalse(t.italic, "italic not requested → never synthesised")
        XCTAssertEqual(t.bold, !hasRealFace(font, .boldTrait))
    }

    func test_menlo_regularNeverSynthesises() throws {
        let font = try XCTUnwrap(NSFont(name: "Menlo-Regular", size: 13))
        let atlas = try makeAtlas(font: font)
        let t = atlas.syntheticTraits(for: .regular)
        XCTAssertFalse(t.bold)
        XCTAssertFalse(t.italic)
    }

    // MARK: - Font with no bold/italic faces at all

    func test_emojiFont_synthesisesWhateverHasNoRealFace() throws {
        let font = try XCTUnwrap(NSFont(name: "Apple Color Emoji", size: 13))
        let atlas = try makeAtlas(font: font)
        let realBold = hasRealFace(font, .boldTrait)
        let realItalic = hasRealFace(font, .italicTrait)
        let t = atlas.syntheticTraits(for: GlyphAtlas.Style(bold: true, italic: true))
        XCTAssertEqual(t.bold, !realBold)
        XCTAssertEqual(t.italic, !realItalic)
        // Regular never needs synthesis regardless of family.
        let r = atlas.syntheticTraits(for: .regular)
        XCTAssertFalse(r.bold)
        XCTAssertFalse(r.italic)
    }

    // MARK: - Requested-trait gating

    func test_unrequestedTraitIsNeverSynthesised() throws {
        // Regardless of what the family lacks, a trait the style does not
        // ask for must never be reported as synthetic.
        for name in ["Menlo-Regular", "Apple Color Emoji"] {
            let font = try XCTUnwrap(NSFont(name: name, size: 13))
            let atlas = try makeAtlas(font: font)
            XCTAssertFalse(atlas.syntheticTraits(for: GlyphAtlas.Style(bold: false, italic: true)).bold,
                           "\(name): bold not requested")
            XCTAssertFalse(atlas.syntheticTraits(for: GlyphAtlas.Style(bold: true, italic: false)).italic,
                           "\(name): italic not requested")
        }
    }
}
