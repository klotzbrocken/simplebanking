#include <metal_stdlib>
#include <SwiftUI/SwiftUI.h>
using namespace metal;

/*
 CRT-Shader für das BTX-Theme (Easter-Egg) — im Geist von cool-retro-term,
 als SwiftUI-colorEffect über die bestehende Metal-Pipeline (wie Ripple.metal).

 Bewusst ein reiner FARB-Shader ohne Layer-Sampling: die erste Fassung nutzte
 layerEffect mit Tonnen-Verzerrung, deren Sample-Verschiebung an den Ecken das
 maxSampleOffset-Limit riss — Ergebnis war ein schwarzes Fenster. colorEffect
 transformiert nur den Farbwert des jeweiligen Pixels und kann prinzipbedingt
 nichts schwärzen; die Röhren-Wölbung übernimmt optisch die BTXScreenBezel.

 Bausteine:
   • Scanlines      — abwechselnd helle/dunkle Zeilen (Periode 2 pt)
   • Aperture-Maske — RGB-Subpixel-Streifen wie eine Lochmaske
   • Vignette       — Abdunklung zu den Rändern
   • Flicker        — kaum wahrnehmbares 50-Hz-Zittern der Helligkeit
   • Phosphor-Glow  — leichtes Überstrahlen heller Flächen
*/
[[ stitchable ]]
half4 btxCrtColor(
    float2 position,
    half4 color,
    float2 size,
    float time,
    float strength
) {
    // Normierte Koordinaten -1…1 um die Bildmitte (für die Vignette).
    float2 cc = (position / size) * 2.0 - 1.0;
    float dist2 = dot(cc, cc);

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
    float vignette = 1.0 - 0.18 * strength * dist2;
    float flicker  = 1.0 + 0.012 * strength * sin(time * 100.0 * 3.14159265);

    color.rgb *= mask * half3(scan * vignette * flicker);

    // Leichtes Überstrahlen heller Flächen (Phosphor-Glow, billig genähert).
    half luma = dot(color.rgb, half3(0.299, 0.587, 0.114));
    color.rgb += color.rgb * (luma * luma) * 0.08 * strength;

    return color;
}
