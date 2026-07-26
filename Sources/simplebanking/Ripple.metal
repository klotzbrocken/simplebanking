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
    float2 size,
    float2 origin,
    float time,
    float amplitude,
    float frequency,
    float decay,
    float speed
) {
    // `maxSampleOffset` vergrößert die Zeichenfläche des Effekts über die Ansicht
    // hinaus (hier um 12 pt) — der Shader wird also auch für Positionen AUSSERHALB
    // der Ebene aufgerufen. Vorher fiel das nicht auf: dort lieferte `layer.sample`
    // transparentes Schwarz, es wurde schlicht nichts gezeichnet. Seit die
    // Sample-Position geklemmt wird (gegen Blitz und Doppelkontur, s.u.), landen
    // diese Aufrufe auf der Randzeile und schmieren sie nach außen — im Flyout und
    // in der Umsatzliste sichtbar als Streifen über den Konto-Pillen.
    // Ausserhalb also weiterhin nichts zeichnen.
    if (position.x < 0.0 || position.y < 0.0 || position.x >= size.x || position.y >= size.y) {
        return half4(0.0h);
    }

    float distance = length(position - origin);
    float delay    = distance / speed;

    // Shift time so the wave arrives at `distance` after `delay` seconds.
    time -= delay;
    time  = max(0.0, time);

    // Decaying sine wave — amplitude scales by exp(-decay * time).
    float rippleAmount = amplitude * sin(frequency * time) * exp(-decay * time);

    // Radial unit vector away from origin.
    float2 n = normalize(position - origin);

    // Displace the sample position — aber NIEMALS über den Rand der Ebene hinaus.
    //
    // Zwei Fehler hatte diese Stelle nacheinander, beide mit derselben Wurzel:
    // ein Sample ausserhalb des Inhalts ist premultipliziertes Transparent-Schwarz.
    //   1. Mit der Alpha des Originalpixels versehen wurde daraus ein SCHWARZER
    //      Blitz entlang der Wellenfront.
    //   2. Der erste Fix (in dem Fall die Originalfarbe behalten) schaltete pro
    //      Pixel hart um — an antialiasten Textkanten nahm ein Pixel das Original,
    //      das Nachbarpixel das verschobene Sample. Das Original geisterte als
    //      zweite Kontur mit, im Dark Mode als deutlicher Doppler sichtbar.
    // Wird die Sample-Position geklemmt, gibt es kein Aussen-Sample mehr — und
    // damit weder Schwarz noch Fallunterscheidung.
    float2 maxPos = max(size - float2(1.0, 1.0), float2(0.0, 0.0));
    float2 newPosition = clamp(position + rippleAmount * n, float2(0.0, 0.0), maxPos);

    half4 color = layer.sample(newPosition);

    // Brighten/darken based on wave direction — this is the "liquid glass" look.
    color.rgb += 0.3 * (rippleAmount / amplitude) * color.a;

    return color;
}
