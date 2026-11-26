#include <metal_stdlib>
using namespace metal;

struct CellInstance {
    float2 cellPosPx;
    float2 quadSizePx;    // cellSizePx for narrow, 2x for wide (CJK, emoji)
    float2 uvOrigin;
    float2 uvSize;
    float4 fgColor;
    float4 bgColor;
    uint4  attrs;         // .x = attribute bitmask
};

struct FrameUniforms {
    float2 viewportPx;
    float2 cellSizePx;
    float4 accentColor;   // sRGB RGBA
    float4 decorationPx;  // pt from bottom: x underline centre, z strike centre; y thickness
};

struct VertexOut {
    float4 position [[position]];
    float2 uv;
    float4 fgColor;
    float4 bgColor;
    float4 accentColor;
    uint   flags;
    uint   underlineColorPacked;  // 0x00RRGGBB or 0xFFFFFFFF sentinel (use fg)
    float2 localPx;       // position within the cell's quad, in points
    float2 quadSizePx;
    float  cellOriginX;   // quad's left edge in points
    float4 decorationPx;
};

// Shader-internal, NOT a CellAttributeMask bit: vertex_cell sets it for instances whose UV rect
// is empty. Bit 31 keeps the Swift side's reserved bits 8-30 free.
constant uint BB_ATTR_NO_GLYPH           = 1u << 31;

vertex VertexOut vertex_cell(
    uint vid [[vertex_id]],
    uint iid [[instance_id]],
    const device CellInstance* instances [[buffer(0)]],
    constant FrameUniforms& u [[buffer(1)]]
) {
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

    float2 ndc;
    ndc.x = (cornerPx.x / u.viewportPx.x) * 2.0 - 1.0;
    ndc.y = 1.0 - (cornerPx.y / u.viewportPx.y) * 2.0;

    VertexOut out;
    out.position = float4(ndc, 0, 1);
    out.uv = inst.uvOrigin + uvs[vid] * inst.uvSize;
    out.fgColor = inst.fgColor;
    out.bgColor = inst.bgColor;
    out.accentColor = u.accentColor;
    // Glyph-less quads carry a zero UV rect and must skip the atlas fetch: texel (0,0) of slot 0
    // holds a real glyph once an atlas saturation flush rewinds to slot 0.
    out.flags = inst.attrs.x
              | ((inst.uvSize.x == 0.0 && inst.uvSize.y == 0.0) ? BB_ATTR_NO_GLYPH : 0u);
    out.underlineColorPacked = inst.attrs.z;
    out.localPx = corners[vid] * inst.quadSizePx;
    out.quadSizePx = inst.quadSizePx;
    out.cellOriginX = inst.cellPosPx.x;
    out.decorationPx = u.decorationPx;
    return out;
}

// CellAttributeMask bits — must stay in lockstep with Sources/Renderer/CellInstance.swift.
constant uint BB_ATTR_LINK_HOVER         = 1u << 0;
constant uint BB_ATTR_STRIKE             = 1u << 1;
constant uint BB_ATTR_UNDERLINE          = 1u << 2;
constant uint BB_ATTR_UNDERLINE_DOUBLE   = 1u << 3;
constant uint BB_ATTR_UNDERCURL          = 1u << 4;
constant uint BB_ATTR_UNDERLINE_DOTTED   = 1u << 5;
constant uint BB_ATTR_UNDERLINE_DASHED   = 1u << 6;
// The glyph lives in the color atlas (BGRA premultiplied), not the coverage-mono atlas.
constant uint BB_ATTR_IS_COLOR_GLYPH     = 1u << 7;
constant uint BB_ATTR_ANY_UNDERLINE      = BB_ATTR_UNDERLINE
                                         | BB_ATTR_UNDERLINE_DOUBLE
                                         | BB_ATTR_UNDERCURL
                                         | BB_ATTR_UNDERLINE_DOTTED
                                         | BB_ATTR_UNDERLINE_DASHED;

static inline float4 premul(float4 c) {
    return float4(c.rgb * c.a, c.a);
}

fragment float4 fragment_cell(
    VertexOut in [[stage_in]],
    texture2d<float> atlas [[texture(0)]],
    texture2d<float> colorAtlas [[texture(1)]]
) {
    // sRGB-encoded colours into a `.bgra8Unorm` (NOT `_srgb`) target: blending is not linear-light.
    constexpr sampler s(coord::normalized, filter::linear, address::clamp_to_edge);
    uint flags = in.flags;

    // PREMULTIPLIED output, blend ONE / ONE_MINUS_SRC_ALPHA. Straight alpha with SRC_ALPHA
    // squares the glyph coverage on default-bg cells (bg.a == 0).
    float4 bg = in.bgColor;
    float3 bgPre = bg.rgb * bg.a;
    float4 base;
    if ((flags & BB_ATTR_IS_COLOR_GLYPH) != 0u) {
        float4 sample = colorAtlas.sample(s, in.uv);
        base = float4(sample.rgb + bgPre * (1.0 - sample.a),
                      sample.a + bg.a * (1.0 - sample.a));
    } else {
        float coverage = 0.0;
        if ((flags & BB_ATTR_NO_GLYPH) == 0u) {
            coverage = atlas.sample(s, in.uv).r * in.fgColor.a;
        }
        base = float4(in.fgColor.rgb * coverage + bgPre * (1.0 - coverage),
                      coverage + bg.a * (1.0 - coverage));
    }

    float distFromBottom = in.quadSizePx.y - in.localPx.y;
    // Undercurl / dotted / dashed phase uses the ABSOLUTE x in points: `localPx.x` restarts at 0
    // in every cell, which breaks the pattern at each cell seam.
    float x = in.cellOriginX + in.localPx.x;

    float4 ulColor = in.fgColor;
    if (in.underlineColorPacked != 0xFFFFFFFFu) {
        float r = float((in.underlineColorPacked >> 16) & 0xFFu) / 255.0;
        float g = float((in.underlineColorPacked >> 8) & 0xFFu) / 255.0;
        float b = float(in.underlineColorPacked & 0xFFu) / 255.0;
        ulColor = float4(r, g, b, 1.0);
    }

    float ulCenter = in.decorationPx.x;
    float ulHalf   = max(0.5, in.decorationPx.y * 0.5);
    float strikeC  = in.decorationPx.z;
    if ((flags & BB_ATTR_STRIKE) != 0u) {
        if (abs(distFromBottom - strikeC) <= ulHalf) {
            return premul(in.fgColor);
        }
    }

    if ((flags & BB_ATTR_LINK_HOVER) != 0u && abs(distFromBottom - ulCenter) <= ulHalf + 0.25) {
        return premul(in.accentColor);
    }

    if ((flags & BB_ATTR_ANY_UNDERLINE) != 0u) {
        if ((flags & BB_ATTR_UNDERLINE) != 0u && abs(distFromBottom - ulCenter) <= ulHalf) {
            return premul(ulColor);
        }
        if ((flags & BB_ATTR_UNDERLINE_DOUBLE) != 0u) {
            float gap = max(1.0, in.decorationPx.y);
            if (abs(distFromBottom - (ulCenter - gap)) <= ulHalf) return premul(ulColor);
            if (abs(distFromBottom - (ulCenter + gap)) <= ulHalf) return premul(ulColor);
        }
        if ((flags & BB_ATTR_UNDERCURL) != 0u) {
            float amp = max(1.0, in.decorationPx.y * 1.2);
            float wave = sin(x * 1.4) * amp;
            if (abs(in.localPx.y - (in.quadSizePx.y - ulCenter + wave)) <= ulHalf) {
                return premul(ulColor);
            }
        }
        if ((flags & BB_ATTR_UNDERLINE_DOTTED) != 0u && abs(distFromBottom - ulCenter) <= ulHalf) {
            uint phase = uint(floor(x / max(1.0, in.decorationPx.y)));
            if ((phase & 1u) == 0u) return premul(ulColor);
        }
        if ((flags & BB_ATTR_UNDERLINE_DASHED) != 0u && abs(distFromBottom - ulCenter) <= ulHalf) {
            uint phase = uint(floor(x / max(1.0, in.decorationPx.y)));
            if ((phase % 4u) < 2u) return premul(ulColor);
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
    // Shape 3 (hidden) never reaches the shader: the CPU path skips the draw entirely.
    if (u.shape == 1u) {
        if (p.x >= 2.0) discard_fragment();
        return u.color;
    }
    if (u.shape == 2u) {
        if ((s.y - p.y) >= 2.0) discard_fragment();
        return u.color;
    }
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
