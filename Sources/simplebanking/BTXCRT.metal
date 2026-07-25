#include <metal_stdlib>
#include <SwiftUI/SwiftUI.h>
using namespace metal;

/*
 CRT-Shader für das BTX-Theme (Easter-Egg) — im Geist von cool-retro-term,
 aber als SwiftUI-layerEffect über die bestehende Metal-Pipeline (wie Ripple.metal):
 kein Overlay-Fenster, kein ScreenCaptureKit, wirkt nur auf die eigene View.

 Bausteine:
   • Tonnen-Verzerrung (barrel) — die Wölbung der Bildröhre
   • Scanlines             — abwechselnd helle/dunkle Zeilen (Periode 2 pt)
   • Aperture-Maske        — RGB-Subpixel-Streifen wie eine Lochmaske
   • Vignette              — Abdunklung zu den Rändern
   • Flicker               — kaum wahrnehmbares 50-Hz-Zittern der Helligkeit

 `strength` (0…1) skaliert alle Anteile gemeinsam; die Alpha bleibt die des
 Original-Pixels, damit außerhalb des Inhalts keine Löcher entstehen (gleiche
 Vorsichtsmaßnahme wie im Ripple-Shader).
*/
[[ stitchable ]]
half4 btxCrt(
    float2 position,
    SwiftUI::Layer layer,
    float2 size,
    float time,
    float strength
) {
    // Normierte Koordinaten -1…1 um die Bildmitte.
    float2 uv = position / size;
    float2 cc = uv * 2.0 - 1.0;

    // Tonnen-Verzerrung: Samples wandern zum Rand hin nach außen.
    float dist2 = dot(cc, cc);
    float2 warped = cc * (1.0 + 0.045 * strength * dist2);
    float2 wuv = (warped + 1.0) * 0.5;

    half4 original = layer.sample(position);

    // Außerhalb der gewölbten Fläche: Schwarz (Röhrenrand), Alpha des Originals.
    if (wuv.x < 0.0 || wuv.x > 1.0 || wuv.y < 0.0 || wuv.y > 1.0) {
        return half4(0.0, 0.0, 0.0, original.a);
    }

    half4 color = layer.sample(wuv * size);
    color.a = original.a;

    // Scanlines: Periode 2 pt (Retina: 4 px) — deutlich, aber nicht dominant.
    float scan = 1.0 - 0.14 * strength * (0.5 + 0.5 * sin(position.y * 3.14159265));

    // Aperture-Maske: RGB-Streifen im 3-pt-Raster.
    int px = int(fmod(position.x, 3.0));
    half3 mask = half3(1.0);
    float m = 0.06 * strength;
    if (px == 0)      { mask = half3(1.0 + m, 1.0 - m, 1.0 - m); }
    else if (px == 1) { mask = half3(1.0 - m, 1.0 + m, 1.0 - m); }
    else              { mask = half3(1.0 - m, 1.0 - m, 1.0 + m); }

    // Vignette + Flicker (50 Hz, sehr dezent).
    float vignette = 1.0 - 0.22 * strength * dist2;
    float flicker  = 1.0 + 0.012 * strength * sin(time * 100.0 * 3.14159265);

    color.rgb *= mask * half3(scan * vignette * flicker);

    // Leichtes Überstrahlen heller Flächen (Phosphor-Glow, billig genähert).
    half luma = dot(color.rgb, half3(0.299, 0.587, 0.114));
    color.rgb += color.rgb * (luma * luma) * 0.08 * strength;

    return color;
}
