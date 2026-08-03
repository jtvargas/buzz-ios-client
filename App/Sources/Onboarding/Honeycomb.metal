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
// ## What moves, and what does not
//
// The lattice itself is *still*. Nothing drifts, nothing breathes, nothing pulses as a whole.
// The only thing that moves is light travelling **along the lines**: a comet lights up at some
// point on one cell's outline, runs around that outline, fades out, and another one starts
// somewhere else. At any moment a handful are running in different places at different speeds,
// which is what makes the screen read as alive rather than as an animation on a loop.
//
// An earlier version modulated whole cells with two interfering sine waves over a slowly
// drifting lattice. It was brighter and busier than a first-run screen wants to be, and the
// movement was in the *cells* rather than in the *lines* — the pattern appeared to breathe
// instead of to conduct.
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
/// (a stable per-cell identity, which is what every pulse is keyed on).
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

/// A stable pseudo-random number in 0…1 for a cell, per salt. The lattice never moves, so a
/// cell's identity is fixed for the life of the screen and this is what stands in for the
/// randomness the shader has no other source of: which cells light, when, from where, and
/// which way round.
inline float hiveHash(float2 id, float salt) {
    return fract(sin(dot(id + salt, float2(127.1, 311.7)) + salt * 74.7) * 43758.5453123);
}

} // namespace

/// Draws the lattice over whatever the layer already holds.
///
/// - Parameters:
///   - size: the layer's size in points, for the radial falloff.
///   - time: seconds since the view appeared. Frozen by the caller under Reduce Motion.
///   - cellSize: hexagon width in points.
///   - lineColor: the resting lattice.
///   - glowColor: the colour the head of a travelling pulse reaches.
[[stitchable]] half4 hiveHoneycomb(float2 position,
                                   half4 currentColor,
                                   float2 size,
                                   float time,
                                   float cellSize,
                                   half4 lineColor,
                                   half4 glowColor)
{
    // How long one pulse takes to run its arc, in seconds. Deliberately long — this is the
    // single number that decides whether the screen feels calm or fidgety.
    const float kPeriod = 13.0;
    // Roughly what fraction of cells are conducting in any one cycle. Low enough that a pulse
    // reads as a single travelling light rather than as the whole comb flickering.
    const float kDensity = 0.26;
    // The comet's tail, as a fraction of the way round a cell. Short: a long tail turns the
    // whole outline on and the traversal stops being legible.
    const float kTail = 0.075;

    float2 uv = (position - size * 0.5) / cellSize;

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

    // Where this fragment sits on its cell's outline, as 0…1 once round. Angle rather than arc
    // length, so a pulse eases very slightly at the corners — which costs one `atan2` and
    // reads as a light rounding a bend rather than as a dot on a rail.
    float around = fract(atan2(local.y, local.x) * (1.0 / (2.0 * M_PI_F)) + 0.5);

    // Each cell runs its own cycle, offset so they do not start together, and re-rolls its
    // luck at every wrap: a cell that conducted this time round is no likelier to conduct the
    // next. This is what makes a pulse "appear somewhere else" instead of repeating a fixed
    // circuit — the pattern never comes back around to a state a reader has already seen.
    float cycle = time / kPeriod + hiveHash(id, 1.7);
    float turn = floor(cycle);
    float phase = fract(cycle);

    float luck = hiveHash(id, turn * 13.37 + 4.1);
    float lit = step(luck, kDensity);

    // Where it starts, which way it goes, and how far round it gets before it dies — all three
    // per cycle, so the same cell lighting twice does not trace the same stroke twice.
    float start = hiveHash(id, turn * 13.37 + 21.9);
    float direction = hiveHash(id, turn * 13.37 + 57.3) < 0.5 ? -1.0 : 1.0;
    float travel = mix(0.55, 1.0, hiveHash(id, turn * 13.37 + 88.2));

    float head = start + direction * phase * travel;
    // Distance *behind* the head, measured the way the pulse is running. `fract` closes the
    // loop, so a tail crossing the seam at 0/1 stays whole.
    float behind = fract(direction * (head - around));
    float comet = exp(-behind / kTail);

    // In slowly and out slowly: the pulse must never appear or vanish at full brightness, or
    // the eye reads a blink where the design wants a breath.
    float envelope = smoothstep(0.0, 0.18, phase) * (1.0 - smoothstep(0.62, 1.0, phase));

    float pulse = stroke * comet * envelope * lit;

    // The pattern radiates from behind the app mark and falls away toward the edges and the
    // buttons. Corrected for aspect so the falloff is a circle on the glass, not an ellipse.
    float2 aspect = float2(size.x / max(size.y, 1.0), 1.0);
    float radial = 1.0 - smoothstep(0.06, 0.62, distance(position / size * aspect,
                                                         float2(0.5, 0.29) * aspect));

    // The resting lattice, dim on purpose: it is the ground the light travels over, not the
    // subject. Bright enough to read as a comb behind the type, dark enough that the pulses
    // are the only thing that draws the eye.
    float lattice = stroke * mix(0.055, 0.105, radial);
    // The pulse carries past the radial falloff rather than being gated by it — confined to
    // the cells around the mark, a moving light reads as a rendering artefact rather than as
    // the screen conducting.
    float glow = pulse * mix(0.30, 1.0, radial) * 0.50;

    // The lower half of the screen is where the buttons and the community card are, and glass
    // over a lit lattice is glass over noise. Fading toward the bottom reads as depth rather
    // than as a band across the pattern, which is what a straight horizontal scrim looks like.
    float settle = 1.0 - 0.55 * smoothstep(0.42, 1.0, position.y / max(size.y, 1.0));

    half3 tint = mix(lineColor.rgb, glowColor.rgb, half(saturate(comet * envelope * lit)));
    half amount = half(saturate((lattice + glow) * settle));

    // Source-over against what is already there, so the shader owns only the pattern and the
    // screen keeps its own background colour.
    return half4(mix(currentColor.rgb, tint, amount), currentColor.a);
}
