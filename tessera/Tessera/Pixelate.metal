// Pixelation, for the second opening: the picture arrives as coarse cells
// that refine into the picture itself.

#include <metal_stdlib>
#include <SwiftUI/SwiftUI_Metal.h>
using namespace metal;

[[ stitchable ]] half4 pixelate(float2 position, SwiftUI::Layer layer, float cell, float2 origin) {
    if (cell <= 1.0) { return layer.sample(position); }
    float2 p = position - origin;
    float2 snapped = floor(p / cell) * cell + cell * 0.5 + origin;
    return layer.sample(snapped);
}
