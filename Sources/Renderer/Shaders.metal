#include <metal_stdlib>
using namespace metal;

struct CellInstance {
    float2 cellPosPx;
    float2 quadSizePx;    // per-cell quad size: cellSizePx for narrow, 2x for wide (CJK, emoji)
    float2 uvOrigin;
    float2 uvSize;
    float4 fgColor;
    float4 bgColor;
    uint4  attrs;         // .x = attribute bitmask (bit 0 = link hover underline); rest reserved/padding
};

struct FrameUniforms {
    float2 viewportPx;
    float2 cellSizePx;
    float4 accentColor;   // sRGB RGBA underline colour for accent attributes
};

struct VertexOut {
    float4 position [[position]];
    float2 uv;
    float4 fgColor;
    float4 bgColor;
    float4 accentColor;   // plumbed in via uniform, stamped per-vertex for the fragment
    uint   flags;
    uint   underlineColorPacked;  // 0x00RRGGBB or 0xFFFFFFFF sentinel (use fg)
    float2 localPx;       // position within the cell's quad, in points
    float2 quadSizePx;    // cell quad size (same for all 6 verts per instance)
};

vertex VertexOut vertex_cell(
    uint vid [[vertex_id]],
    uint iid [[instance_id]],
    const device CellInstance* instances [[buffer(0)]],
    constant FrameUniforms& u [[buffer(1)]]
) {
    // Two-triangle quad corners, CCW order.
    float2 corners[6] = {
        float2(0, 0), float2(1, 0), float2(0, 1),
        float2(1, 0), float2(1, 1), float2(0, 1)
    };
    float2 uvs[6] = {
        float2(0, 0), float2(1, 0), float2(0, 1),
        float2(1, 0), float2(1, 1), float2(0, 1)
    };

    CellInstance inst = instances[iid];
    float2 cornerPx = inst.cellPosPx + corners[vid] * inst.quadSizePx;

    // Convert pixel space -> clip space: top-left (0,0), bottom-right (viewport).
    float2 ndc;
    ndc.x = (cornerPx.x / u.viewportPx.x) * 2.0 - 1.0;
    ndc.y = 1.0 - (cornerPx.y / u.viewportPx.y) * 2.0;

    VertexOut out;
    out.position = float4(ndc, 0, 1);
    out.uv = inst.uvOrigin + uvs[vid] * inst.uvSize;
    out.fgColor = inst.fgColor;
    out.bgColor = inst.bgColor;
    out.accentColor = u.accentColor;
    out.flags = inst.attrs.x;
    out.underlineColorPacked = inst.attrs.z;
    out.localPx = corners[vid] * inst.quadSizePx;
    out.quadSizePx = inst.quadSizePx;
    return out;
}

// CellAttributeMask bits — must stay in lockstep with Sources/Renderer/CellInstance.swift.
// Lifted to named constants so the shader branches read like the Swift side.
constant uint BB_ATTR_LINK_HOVER         = 1u << 0;
constant uint BB_ATTR_STRIKE             = 1u << 1;
constant uint BB_ATTR_UNDERLINE          = 1u << 2;
constant uint BB_ATTR_UNDERLINE_DOUBLE   = 1u << 3;
constant uint BB_ATTR_UNDERCURL          = 1u << 4;
constant uint BB_ATTR_UNDERLINE_DOTTED   = 1u << 5;
constant uint BB_ATTR_UNDERLINE_DASHED   = 1u << 6;
// Cell's glyph lives in the color atlas (BGRA premultiplied) rather than
// the coverage-mono atlas. See `GlyphAtlas.colorTexture`.
constant uint BB_ATTR_IS_COLOR_GLYPH     = 1u << 7;
constant uint BB_ATTR_ANY_UNDERLINE      = BB_ATTR_UNDERLINE
                                         | BB_ATTR_UNDERLINE_DOUBLE
                                         | BB_ATTR_UNDERCURL
                                         | BB_ATTR_UNDERLINE_DOTTED
                                         | BB_ATTR_UNDERLINE_DASHED;

fragment float4 fragment_cell(
    VertexOut in [[stage_in]],
    texture2d<float> atlas [[texture(0)]],
    texture2d<float> colorAtlas [[texture(1)]]
) {
    // Colour-space note (audit shaders F1 / metal-renderer F9 / glyph-atlas F10):
    // every colour flowing into this shader — fg, bg, accent, the
    // selection tint, and underline unpacks below — is sRGB-encoded as
    // a normalised float ∈ [0,1]. The render target is `.bgra8Unorm`
    // (NOT `_srgb`) so `mix()` and the output-merger blend op run in
    // sRGB-encoded numeric space rather than linear light. That is a
    // deliberate choice matching Terminal.app / Alacritty / iTerm2's
    // historical behaviour; the CAMetalLayer colorspace is pinned to
    // sRGB on the window side so Display P3 panels don't reinterpret
    // the bytes in wider primaries. Gamma-correct blending would
    // require switching to `.bgra8Unorm_srgb` and uploading linear
    // floats — deferred as a future user toggle.
    constexpr sampler s(coord::normalized, filter::linear, address::clamp_to_edge);
    uint flags = in.flags;
    float4 base;
    if ((flags & BB_ATTR_IS_COLOR_GLYPH) != 0u) {
        // Color emoji path. The color atlas stores premultiplied BGRA
        // bytes written by a CGBitmapContext with
        // `premultipliedFirst | byteOrder32Little` + transparent-cleared
        // background (see GlyphAtlas.rasterizeColor). Metal samples the
        // texture as `bgra8Unorm`, which maps the memory bytes to the
        // float4's color components in natural RGBA order.
        //
        // De-premultiply so the existing straight-alpha blend op
        // (`.sourceAlpha` / `.oneMinusSourceAlpha`) composites the emoji
        // correctly without double-multiplying alpha. `1.0/255.0` is the
        // smallest representable non-zero 8-bit alpha — any sampled texel
        // is either ≥ that or exactly zero, and the zero case falls into
        // the else branch below.
        float4 sample = colorAtlas.sample(s, in.uv);
        if (sample.a > 0.0) {
            base = float4(sample.rgb / max(sample.a, 1.0 / 255.0), sample.a);
        } else {
            // Empty texel (flushed atlas slot, rasterization failure, or
            // sampled outside the glyph's ink). Returning float4(0) would
            // leave the framebuffer's previous contents visible — wrong
            // over a cell that declared a non-default background
            // (selection highlight, vim status line, link-hover accent).
            // Falling back to `in.bgColor` matches the mono path's
            // zero-coverage behaviour exactly: the cell's own bg paints,
            // same as `mix(bg, fg, 0)`.
            base = in.bgColor;
        }
    } else {
        float coverage = atlas.sample(s, in.uv).r;
        // Blend fg glyph over bg. coverage = 0 → pure bg, coverage = 1 → pure fg.
        base = mix(in.bgColor, in.fgColor, coverage);
    }

    // The rest of the function overlays strike/underline/undercurl on top of
    // `base`, same code path for both mono and color glyphs (you can still
    // underline an emoji).
    float distFromBottom = in.quadSizePx.y - in.localPx.y;
    float x = in.localPx.x;

    // Unpack CSI 58 underline colour. 0xFFFFFFFF sentinel → use fg; any
    // other value is 0x00RRGGBB. Keeping this in a local avoids five
    // duplicate unpacks in the underline branches below.
    float4 ulColor = in.fgColor;
    if (in.underlineColorPacked != 0xFFFFFFFFu) {
        float r = float((in.underlineColorPacked >> 16) & 0xFFu) / 255.0;
        float g = float((in.underlineColorPacked >> 8) & 0xFFu) / 255.0;
        float b = float(in.underlineColorPacked & 0xFFu) / 255.0;
        ulColor = float4(r, g, b, 1.0);
    }

    // Strike: a single 1.5 pt band slightly above the glyph mid-line so it
    // reads as a strike-through whether the glyph is tall (capital) or short
    // (lowercase). Uses fg colour so it matches the text being crossed out.
    if ((flags & BB_ATTR_STRIKE) != 0u) {
        float strikeY = in.quadSizePx.y * 0.55;
        if (in.localPx.y >= strikeY && in.localPx.y <= strikeY + 1.5) {
            return in.fgColor;
        }
    }

    // Link-hover wins the underline colour: an OSC-8 hover highlight should
    // be visibly distinct even when the cell also carries a plain underline.
    // 2 pt band at the very bottom, in the theme accent.
    if ((flags & BB_ATTR_LINK_HOVER) != 0u && distFromBottom <= 2.0) {
        return in.accentColor;
    }

    // Underline family. All variants sit at the bottom 3 pt of the cell and
    // draw in the glyph's fg colour. Only one "style" bit is expected at a
    // time (alacritty's ALL_UNDERLINES is mutually-exclusive at the parser
    // level) but the checks are independent so a hypothetical future
    // per-bit override still does the right thing.
    if ((flags & BB_ATTR_ANY_UNDERLINE) != 0u) {
        // Plain single underline — 1.5 pt band along the baseline.
        if ((flags & BB_ATTR_UNDERLINE) != 0u && distFromBottom <= 1.5) {
            return ulColor;
        }
        // Double underline — two 1 pt bands with a 1 pt gap between.
        if ((flags & BB_ATTR_UNDERLINE_DOUBLE) != 0u) {
            if (distFromBottom <= 1.0) return ulColor;
            if (distFromBottom >= 2.0 && distFromBottom <= 3.0) return ulColor;
        }
        // Undercurl — sine wave baseline ±1 pt. Tuned so a single cycle is
        // about 3 cells wide; fast enough to read as "wavy" at terminal
        // sizes but not so fast it aliases at normal zoom.
        if ((flags & BB_ATTR_UNDERCURL) != 0u) {
            float baseline = in.quadSizePx.y - 2.5;
            float wave = sin(x * 1.4) * 1.2;
            if (abs(in.localPx.y - (baseline + wave)) <= 0.7) {
                return ulColor;
            }
        }
        // Dotted — every other *point* at the baseline, so the band
        // reads as 1/2-duty dots. `localPx` is in points, so at 2x
        // Retina each point is 2 pixels; dots are therefore 2-pixel
        // squares on Retina and 1-pixel on 1x displays. That's a
        // DPI-linked density — bake the behaviour into the comment so
        // a future "why is this fuzzy at 1x" bug report points here.
        //
        // Uses `floor(x)` + integer modulo instead of a raw
        // `(uint)x` cast. The cast is defined for positive floats
        // but `x` arrives pixel-centered at half-point offsets
        // (e.g. 7.5 on the right edge of point 7), so the cast
        // collapses a full-point phase into the same bucket. `floor`
        // makes the phase math explicit: a 1/2-duty dot pattern
        // whose boundaries land on integer point grid lines.
        // Audit shaders F3.
        if ((flags & BB_ATTR_UNDERLINE_DOTTED) != 0u && distFromBottom <= 1.5) {
            uint phase = uint(floor(x));
            if ((phase & 1u) == 0u) return ulColor;
        }
        // Dashed — 2 points on, 2 points off (same DPI caveat as
        // dotted: doubles to 4-pixel runs on Retina, 2-pixel on 1x).
        if ((flags & BB_ATTR_UNDERLINE_DASHED) != 0u && distFromBottom <= 1.5) {
            uint phase = uint(floor(x));
            if ((phase % 4u) < 2u) return ulColor;
        }
    }

    return base;
}

struct CursorUniforms {
    float2 viewportPx;
    float2 cursorPosPx;
    float2 cellSizePx;
    float4 color;
    float strokeWidthPx;
    float filled;           // 1.0 = solid (focused), 0.0 = outline (block only)
    uint  shape;            // 0 = block, 1 = bar, 2 = underline, 3 = hidden
    float _pad;
};

struct CursorOut {
    float4 position [[position]];
    float2 localPx;
};

vertex CursorOut vertex_cursor(
    uint vid [[vertex_id]],
    constant CursorUniforms& u [[buffer(0)]]
) {
    float2 corners[6] = {
        float2(0, 0), float2(1, 0), float2(0, 1),
        float2(1, 0), float2(1, 1), float2(0, 1)
    };
    float2 cornerPx = u.cursorPosPx + corners[vid] * u.cellSizePx;
    float2 ndc;
    ndc.x = (cornerPx.x / u.viewportPx.x) * 2.0 - 1.0;
    ndc.y = 1.0 - (cornerPx.y / u.viewportPx.y) * 2.0;

    CursorOut out;
    out.position = float4(ndc, 0, 1);
    out.localPx = corners[vid] * u.cellSizePx;
    return out;
}

fragment float4 fragment_cursor(
    CursorOut in [[stage_in]],
    constant CursorUniforms& u [[buffer(0)]]
) {
    float2 p = in.localPx;
    float2 s = u.cellSizePx;
    // DECSCUSR shape dispatch. Shape 3 (hidden) never reaches the shader —
    // the CPU path skips the draw entirely.
    // Bar: 2-pixel vertical column on the left edge of the cell.
    if (u.shape == 1u) {
        if (p.x >= 2.0) discard_fragment();
        return u.color;
    }
    // Underline: 2-pixel horizontal band at the bottom of the cell.
    if (u.shape == 2u) {
        if ((s.y - p.y) >= 2.0) discard_fragment();
        return u.color;
    }
    // Block (shape == 0). Focused = solid; unfocused = outline stroke.
    if (u.filled > 0.5) {
        return u.color;
    }
    bool stroke =
        p.x < u.strokeWidthPx ||
        p.y < u.strokeWidthPx ||
        (s.x - p.x) < u.strokeWidthPx ||
        (s.y - p.y) < u.strokeWidthPx;
    if (!stroke) discard_fragment();
    return u.color;
}
