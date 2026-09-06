// The record onto the platter.
//
// A distortion shader: for every pixel of the record's box on screen it
// works out, through the inverse of the platter's projective map, which
// point of the flat pressing is under it, turns that point by the record's
// angle, and samples the pressing there. The pressing is a plain square
// picture; this is what puts it on the platter in perspective and keeps it
// turning without redrawing anything.

#include <metal_stdlib>
#include <SwiftUI/SwiftUI_Metal.h>
using namespace metal;

[[ stitchable ]] float2 recordWarp(float2 position, float2 size, float2 origin,
                                   float3 r0, float3 r1, float3 r2, float angle) {
    float2 p = position + origin;                          // this pixel, in the room's coordinates
    float w = r2.x * p.x + r2.y * p.y + r2.z;
    float u = (r0.x * p.x + r0.y * p.y + r0.z) / w;        // where it is on the flat disc, 0...1
    float v = (r1.x * p.x + r1.y * p.y + r1.z) / w;
    float x = 2.0 * u - 1.0, y = 1.0 - 2.0 * v;            // the disc, y up
    float c = cos(angle), s = sin(angle);
    float xr = c * x - s * y, yr = s * x + c * y;          // the pressing turned clockwise by angle
    return float2((xr + 1.0) * 0.5 * size.x, (1.0 - yr) * 0.5 * size.y);
}

// Reflections stay aligned with the room while the pressing rotates below.
[[ stitchable ]] half4 recordSheen(float2 position, half4 color, float2 origin,
                                 float3 r0, float3 r1, float3 r2) {
    float3 p = float3(position + origin, 1.0);
    float w = dot(r2, p);
    float2 disc = float2(dot(r0, p), dot(r1, p)) / w * 2.0 - 1.0;
    float radius = length(disc);
    if (radius > 1.0) return half4(0.0);
    float angle = atan2(disc.y, disc.x);
    float reflection = pow(abs(cos(angle + 0.65)), 24.0) * 0.10;
    reflection *= smoothstep(0.34, 0.43, radius);
    half3 rgb = mix(color.rgb, half3(color.a), half(reflection));
    return half4(rgb, color.a);
}
