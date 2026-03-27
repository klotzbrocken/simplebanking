#include <metal_stdlib>
#include <SwiftUI/SwiftUI.h>
using namespace metal;

/*
 Water-ripple shader — based on Apple's WWDC24 reference implementation.
 Applies a sine wave displacement that decays over time, plus a brightness
 adjustment that creates the "liquid glass" light-refraction look.
*/
[[ stitchable ]]
half4 ripple(
    float2 position,
    SwiftUI::Layer layer,
    float2 origin,
    float time,
    float amplitude,
    float frequency,
    float decay,
    float speed
) {
    float distance = length(position - origin);
    float delay    = distance / speed;

    // Shift time so the wave arrives at `distance` after `delay` seconds.
    time -= delay;
    time  = max(0.0, time);

    // Decaying sine wave — amplitude scales by exp(-decay * time).
    float rippleAmount = amplitude * sin(frequency * time) * exp(-decay * time);

    // Radial unit vector away from origin.
    float2 n = normalize(position - origin);

    // Displace the sample position.
    float2 newPosition = position + rippleAmount * n;

    // Sample the layer at the displaced position.
    half4 color = layer.sample(newPosition);

    // Brighten/darken based on wave direction — this is the "liquid glass" look.
    color.rgb += 0.3 * (rippleAmount / amplitude) * color.a;

    return color;
}
