#include <metal_stdlib>
#include <SwiftUI/SwiftUI.h>
using namespace metal;

/*
 CRT-Shader für das BTX-Theme (Easter-Egg) — im Geist von cool-retro-term.

 Dritter Anlauf, bewusst als OVERLAY: der Shader läuft per colorEffect auf einem
 eigenen transparenten Rechteck ÜBER dem Inhalt und zeichnet die CRT-Textur als
 halbtransparente Schicht (RetroMac-„CRT lite"-Prinzip).

 Warum nicht direkt auf dem Inhalt?
   • layerEffect + Tonnen-Verzerrung riss das maxSampleOffset-Limit → Schwarzbild.
   • colorEffect auf dem Inhalt muss ihn rastern — AppKit-gestützte Views
     (NSScrollView der Umsatzliste, NSTextField der Suchfelder) können nicht
     gerastert werden: die Liste verschwand, Felder zeigten das Verboten-Symbol.
 Das Overlay berührt den Inhalt nicht — darunter darf beliebiges AppKit liegen.

 Bausteine (alle nur abdunkelnd/tönend, nie deckend):
   • Scanlines       — dunkle Zeilen im 2-pt-Raster
   • Aperture-Maske  — R/G/B-Streifen im 3-pt-Raster (leichte Phosphor-Tönung)
   • Vignette        — Abdunklung zu den Rändern
   • Flicker         — kaum wahrnehmbares 50-Hz-Zittern
*/
[[ stitchable ]]
half4 btxCrtOverlay(
    float2 position,
    half4 color,
    float2 size,
    float time,
    float strength
) {
    // Normierte Koordinaten -1…1 um die Bildmitte (für die Vignette).
    float2 cc = (position / size) * 2.0 - 1.0;
    float dist2 = dot(cc, cc);

    // Abdunkelnde Anteile (Alpha der schwarzen Schicht).
    float flicker = 1.0 + 0.10 * sin(time * 100.0 * 3.14159265);
    float scanA   = 0.13 * strength * (0.5 + 0.5 * sin(position.y * 3.14159265)) * flicker;
    float vigA    = 0.16 * strength * dist2;
    float blackA  = clamp(scanA + vigA * (1.0 - scanA), 0.0, 0.85);

    // Phosphor-Streifen: pro 3-pt-Spalte ein R/G/B-Hauch (additiv wirkende Tönung).
    int px = int(fmod(position.x, 3.0));
    half3 stripe = (px == 0) ? half3(1.0, 0.1, 0.1)
                 : (px == 1) ? half3(0.1, 1.0, 0.1)
                             : half3(0.1, 0.1, 1.0);
    float stripeA = 0.05 * strength;

    // Streifen zuerst, Schwarz darüber (source-over, dann entpremultipliziert).
    float aTotal = stripeA + blackA * (1.0 - stripeA);
    half3 rgbPremul = stripe * stripeA * (1.0 - blackA);
    half3 rgb = aTotal > 0.001 ? rgbPremul / aTotal : half3(0.0);

    return half4(rgb, aTotal);
}
