#include <metal_stdlib>
#include <SwiftUI/SwiftUI_Metal.h>

using namespace metal;

// The animated honeycomb behind the onboarding hero.
//
// A fragment shader rather than a stack of SwiftUI shapes on purpose: the lattice covers the
// whole screen, every cell of it changes every frame, and the equivalent drawn as views is
// several hundred stroked paths re-laid-out at the display's refresh rate. Here it is one
// full-screen quad, and the per-cell work is a handful of ALU ops — which is what lets it hold
// 120 Hz on ProMotion (`CADisableMinimumFrameDurationOnPhone`, see `project.yml`).
//
// Everything is computed in *lattice space*: screen points divided by `cellSize`, so one unit
// is one hexagon across the flats.

namespace {

/// Positive modulo. Metal's `fmod` keeps the sign of its left operand, so the naive tiling
/// tears along the x = 0 and y = 0 axes — the two lines that run straight through the middle
/// of the screen, which is exactly where a reader is looking.
inline float2 hiveWrap(float2 value, float2 modulus) {
    return value - modulus * floor(value / modulus);
}

/// Distance from a hexagon's centre to its boundary, measured so that the result is exactly
/// 0.5 on the edge of a unit flat-top hexagon.
inline float hiveHexEdge(float2 p) {
    p = abs(p);
    return max(p.x, dot(p, normalize(float2(1.0, 1.7320508))));
}

/// The hexagon containing `uv`: `.xy` is the offset from its centre, `.zw` the centre itself
/// (a stable per-cell identity, which is what the travelling waves are keyed on).
///
/// A honeycomb is two interleaved rectangular lattices offset by half a cell, so the cell a
/// point belongs to is whichever of the two candidate centres it is nearer.
inline float4 hiveHexCell(float2 uv) {
    const float2 spacing = float2(1.0, 1.7320508);
    const float2 half_ = spacing * 0.5;

    float2 a = hiveWrap(uv, spacing) - half_;
    float2 b = hiveWrap(uv - half_, spacing) - half_;
    float2 local = dot(a, a) < dot(b, b) ? a : b;

    return float4(local, uv - local);
}

} // namespace

/// Draws the lattice over whatever the layer already holds.
///
/// - Parameters:
///   - size: the layer's size in points, for the radial falloff.
///   - time: seconds since the view appeared. Frozen by the caller under Reduce Motion.
///   - cellSize: hexagon width in points.
///   - lineColor: the resting lattice.
///   - glowColor: the colour a cell reaches at the crest of a wave.
[[stitchable]] half4 hiveHoneycomb(float2 position,
                                   half4 currentColor,
                                   float2 size,
                                   float time,
                                   float cellSize,
                                   half4 lineColor,
                                   half4 glowColor)
{
    // Lattice space, centred, with a slow drift on both axes so the pattern never reads as a
    // still image even between wave crests. The two rates are deliberately incommensurate:
    // equal ones make the drift look like a single diagonal slide.
    float2 uv = (position - size * 0.5) / cellSize;
    uv += float2(time * 0.030, time * 0.017);

    float4 cell = hiveHexCell(uv);
    float2 local = cell.xy;
    float2 id = cell.zw;

    // Anti-aliasing width taken from `position`, not from the distance field. `fwidth` of the
    // field itself is discontinuous where two cells meet, which lights up every seam in the
    // lattice with a bright thread; `position` varies linearly across the whole quad, so this
    // is one constant and the seams stay clean.
    float pixel = fwidth(position.x) / cellSize;

    float depth = 0.5 - hiveHexEdge(local);
    float stroke = 1.0 - smoothstep(0.013 - pixel, 0.013 + pixel, depth);

    // Two travelling waves at different speeds and headings. Their interference is what stops
    // the loop from reading as a loop: individually each repeats, together they take long
    // enough to come back into phase that nobody watching an onboarding screen sees it.
    float crestA = smoothstep(0.42, 1.0, sin(dot(id, float2(0.34, 0.21)) - time * 0.85));
    float crestB = smoothstep(0.62, 1.0, sin(dot(id, float2(-0.17, 0.30)) - time * 0.52));
    float crest = max(crestA, crestB * 0.85);

    // A slow per-cell shimmer under the waves, so the resting lattice is uneven rather than a
    // flat grey mesh.
    float shimmer = 0.72 + 0.28 * sin(dot(id, float2(0.71, 0.49)) + time * 0.35);

    // The pattern radiates from behind the app mark and falls away toward the edges and the
    // buttons. Corrected for aspect so the falloff is a circle on the glass, not an ellipse.
    float2 aspect = float2(size.x / max(size.y, 1.0), 1.0);
    float radial = 1.0 - smoothstep(0.06, 0.62, distance(position / size * aspect,
                                                         float2(0.5, 0.29) * aspect));

    // The interior wash: crest cells fill with a little light rather than only outlining, which
    // is what makes the wave read as passing *through* the comb.
    float interior = smoothstep(0.0, 0.34, depth) * crest * radial * 0.07;

    float lattice = stroke * shimmer * mix(0.13, 0.20, radial);
    // The wave carries past the radial falloff — gated by it entirely, the crests only ever lit
    // the cells immediately around the mark, and a pattern that moves in one small patch reads
    // as a rendering artefact rather than as the screen breathing.
    float glow = stroke * crest * mix(0.34, 1.0, radial) * 0.80;

    // The lower half of the screen is where the buttons and the community card are, and glass
    // over a lit lattice is glass over noise. Fading toward the bottom reads as depth rather
    // than as a band across the pattern, which is what a straight horizontal scrim looks like.
    float settle = 1.0 - 0.55 * smoothstep(0.42, 1.0, position.y / max(size.y, 1.0));

    half3 tint = mix(lineColor.rgb, glowColor.rgb, half(saturate(crest * radial)));
    half amount = half(saturate((lattice + glow + interior) * settle));

    // Source-over against what is already there, so the shader owns only the pattern and the
    // screen keeps its own background colour.
    return half4(mix(currentColor.rgb, tint, amount), currentColor.a);
}
