#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"

OUTDIR="$ROOT/SimpleBankingBuild"
APP="${APP_PATH:-$ROOT/SimpleBankingBuild/simplebanking.app}"
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
STAGE_DIR="$OUTDIR/.dmg-stage-$TIMESTAMP"
APP_BASENAME="$(basename "$APP" .app)"
DMG_PATH="$OUTDIR/${APP_BASENAME}-${TIMESTAMP}.dmg"

# Defaults auf die tatsächlich vorhandenen Artefakte dieser Maschine:
#  - Developer ID: "…(FTJLR8JRNS)" (SHA-1 53CF9A…), Private Key vorhanden.
#  - Notary: das geteilte Keychain-Profil "Retromac" (simplebanking-notary fehlt
#    seit dem Mac-Umzug; "Retromac" nutzt dieselbe Apple-ID/Team FTJLR8JRNS).
SIGN_IDENTITY="${SIGN_IDENTITY:-Developer ID Application: Maik Klotz (FTJLR8JRNS)}"
NOTARY_PROFILE="${NOTARY_PROFILE:-Retromac}"
BUILD_FIRST="${BUILD_FIRST:-1}"
SKIP_APPCAST="${SKIP_APPCAST:-0}"

usage() {
    cat <<EOF
Usage:
  SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" \\
  NOTARY_PROFILE="simplebanking-notary" \\
  ./sign-and-notarize.sh

Optional env vars:
  BUILD_FIRST=1|0   Build app before signing (default: 1)
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    usage
    exit 0
fi

if [[ -z "$SIGN_IDENTITY" || -z "$NOTARY_PROFILE" ]]; then
    usage
    echo
    echo "Error: SIGN_IDENTITY and NOTARY_PROFILE are required."
    exit 1
fi

if [[ "$BUILD_FIRST" == "1" ]]; then
    echo "[1/8] Build app bundle"
    bash "$ROOT/build-app.sh"
fi

if [[ ! -d "$APP" ]]; then
    echo "Error: App bundle not found: $APP"
    exit 1
fi

echo "[2/8] Prepare app bundle"
xattr -cr "$APP"

echo "[3/8] Sign nested executables"

# Sparkle.framework — sign nested components deepest-first, then the framework itself
SPARKLE_FW="$APP/Contents/Frameworks/Sparkle.framework"
if [[ -d "$SPARKLE_FW" ]]; then
    echo "  Signing Sparkle XPC services..."
    while IFS= read -r xpc; do
        [[ -d "$xpc" ]] && codesign --force --timestamp --options runtime \
            --sign "$SIGN_IDENTITY" "$xpc"
    done < <(find "$SPARKLE_FW" -name "*.xpc" | sort -r)

    echo "  Signing Sparkle nested apps..."
    while IFS= read -r nested_app; do
        [[ -d "$nested_app" ]] && codesign --force --timestamp --options runtime \
            --sign "$SIGN_IDENTITY" "$nested_app"
    done < <(find "$SPARKLE_FW" -name "*.app" | sort -r)

    echo "  Signing Sparkle bare executables (Autoupdate etc.)..."
    while IFS= read -r bin; do
        codesign --force --timestamp --options runtime \
            --sign "$SIGN_IDENTITY" "$bin"
    done < <(find "$SPARKLE_FW/Versions/B" -maxdepth 1 -type f -perm +0111 ! -name "*.plist")

    echo "  Signing Sparkle.framework..."
    codesign --force --timestamp --options runtime \
        --sign "$SIGN_IDENTITY" "$SPARKLE_FW"
fi

ENTITLEMENTS="$ROOT/Sources/simplebanking/simplebanking.entitlements"

# MCP helper binary — sign before the main bundle
MCP_BIN="$APP/Contents/MacOS/simplebanking-mcp"
if [[ -f "$MCP_BIN" ]]; then
    codesign --force --timestamp --options runtime \
        --sign "$SIGN_IDENTITY" \
        --entitlements "$ENTITLEMENTS" \
        "$MCP_BIN"
fi

# CLI helper binary (`sb`) — same rules as MCP: Developer ID + hardened runtime + timestamp.
# Ohne diese Signierung lehnt Apple das gesamte Bundle als Invalid ab.
CLI_BIN="$APP/Contents/MacOS/simplebanking-cli"
if [[ -f "$CLI_BIN" ]]; then
    codesign --force --timestamp --options runtime \
        --sign "$SIGN_IDENTITY" \
        --entitlements "$ENTITLEMENTS" \
        "$CLI_BIN"
fi

# Main Swift binary — with sandbox entitlements
codesign --force --timestamp --options runtime \
    --sign "$SIGN_IDENTITY" \
    --entitlements "$ENTITLEMENTS" \
    "$APP/Contents/MacOS/simplebanking"

echo "[4/8] Sign app bundle"
codesign --force --timestamp --options runtime \
    --sign "$SIGN_IDENTITY" \
    --entitlements "$ENTITLEMENTS" \
    "$APP"

echo "[5/8] Verify app signature"
codesign --verify --deep --strict --verbose=2 "$APP"

echo "[6/8] Create DMG"
rm -rf "$STAGE_DIR"
mkdir -p "$STAGE_DIR"
cp -R "$APP" "$STAGE_DIR/"
ln -s /Applications "$STAGE_DIR/Applications"
hdiutil create -volname "simplebanking" -srcfolder "$STAGE_DIR" -ov -format UDZO "$DMG_PATH"
rm -rf "$STAGE_DIR"

echo "[7/8] Notarize DMG"
xcrun notarytool submit "$DMG_PATH" --keychain-profile "$NOTARY_PROFILE" --wait

echo "[8/8] Staple + Gatekeeper checks"
xcrun stapler staple "$APP"
xcrun stapler staple "$DMG_PATH"
spctl --assess --type execute --verbose=4 "$APP" || true
spctl --assess --type open --verbose=4 "$DMG_PATH" || true

if [[ "$SKIP_APPCAST" == "1" ]]; then
    echo "Appcast-Werte übersprungen (SKIP_APPCAST=1)"
    echo
    echo "Done."
    echo "App: $APP"
    echo "DMG: $DMG_PATH"
    exit 0
fi

# ---------------------------------------------------------------------------
# [9/9] Appcast-Werte ausgeben — bewusst KEIN `generate_appcast` mehr.
#
# Hier stand früher `generate_appcast "$OUTDIR"`. Das hatte zwei Fehler, von
# denen der erste Kunden aussperrt:
#
#   1. Es scannt den GANZEN Build-Ordner. Dort liegen alle Wegwerf-Builds (im
#      Juli waren es neun DMGs) und werden zu je einem regulären Eintrag. Vor
#      allem aber kann es den `sparkle:informationalUpdate`/`belowVersion`-Riegel
#      nicht erzeugen — und genau der trennt die Installationen mit dem ALTEN,
#      verlorenen Signaturschlüssel (bis 1.6.1) von denen mit dem neuen. Ohne
#      ihn bekämen 1.6.x-Kunden ein Update angeboten, das sie nicht verifizieren
#      können: Fehlermeldung statt Migrationshinweis, und kein Weg mehr zurück.
#   2. `--download-url-prefix` stand auf https://simplebanking.de/download/ —
#      falscher Pfad (die DMGs liegen unter /assets/) und falscher Host: die
#      Seite liegt hinter einem Cache mit 30 Tagen TTL, der nach einem Upload
#      noch wochenlang die alte Datei ausliefert. Enclosure-URLs zeigen deshalb
#      auf das GitHub-Release.
#
# Der Appcast wird von Hand gepflegt. Dieser Schritt liefert nur die Werte, die
# man dafür braucht, und rechnet sie aus der TATSÄCHLICH gebauten DMG aus —
# damit Build-Nummer, Länge und Signatur nicht auseinanderlaufen können.
# ---------------------------------------------------------------------------
echo "[9/9] Appcast-Werte für den neuen Eintrag"

# Build-Nummer der ersten Fassung mit dem NEUEN Signaturschlüssel (2.0-Beta).
# Alles darunter trägt den alten Schlüssel und darf nur den Hinweis sehen.
# Dieser Wert bleibt konstant — er ist NICHT die Nummer des aktuellen Builds.
OLD_KEY_CUTOFF="${OLD_KEY_CUTOFF:-20260725535}"

SPARKLE_KEY_FILE="${SPARKLE_KEY_FILE:-$HOME/Documents/RetroMac-Sparkle-Key/sparkle-private-key.txt}"
SIGN_UPDATE=""
for candidate in "$ROOT/.sparkle-tools/bin/sign_update" \
                 "$ROOT/.build/artifacts/sparkle/Sparkle/bin/sign_update"; do
    [[ -x "$candidate" ]] && { SIGN_UPDATE="$candidate"; break; }
done

BUNDLE_VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' "$APP/Contents/Info.plist")"
SHORT_VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist")"
DMG_NAME="$(basename "$DMG_PATH")"
DMG_LENGTH="$(stat -f%z "$DMG_PATH")"
ENCLOSURE_URL="https://github.com/klotzbrocken/simplebanking/releases/download/v${SHORT_VERSION}/${DMG_NAME}"

if [[ -z "$SIGN_UPDATE" ]]; then
    echo "  ! sign_update nicht gefunden — einmalig ./setup-sparkle.sh ausführen."
    exit 1
fi
if [[ ! -f "$SPARKLE_KEY_FILE" ]]; then
    echo "  ! Privater Sparkle-Schlüssel fehlt: $SPARKLE_KEY_FILE"
    echo "    (überschreibbar per SPARKLE_KEY_FILE=…)"
    exit 1
fi

ED_SIGNATURE="$("$SIGN_UPDATE" --ed-key-file "$SPARKLE_KEY_FILE" "$DMG_PATH" \
    | sed 's/.*edSignature="\([^"]*\)".*/\1/')"

cat <<EOF

  Release anlegen:
    gh release create v${SHORT_VERSION} "$DMG_PATH"

  Dann diesen Eintrag in appcast.xml einfügen (NACH <title>simplebanking</title>,
  vor dem bisher obersten <item>). Der belowVersion-Riegel MUSS bleiben, solange
  noch Installationen mit dem alten Schlüssel möglich sind:

        <item>
            <title>${SHORT_VERSION}</title>
            <pubDate>$(LC_ALL=C date '+%a, %d %b %Y %H:%M:%S %z')</pubDate>
            <sparkle:version>${BUNDLE_VERSION}</sparkle:version>
            <sparkle:shortVersionString>${SHORT_VERSION}</sparkle:shortVersionString>
            <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
            <sparkle:informationalUpdate>
                <sparkle:belowVersion>${OLD_KEY_CUTOFF}</sparkle:belowVersion>
            </sparkle:informationalUpdate>
            <enclosure url="${ENCLOSURE_URL}" length="${DMG_LENGTH}" type="application/octet-stream" sparkle:edSignature="${ED_SIGNATURE}"/>
            <link>https://github.com/klotzbrocken/simplebanking/releases/latest</link>
            <description><![CDATA[
                <h2>simplebanking ${SHORT_VERSION}</h2>
                <p>TODO: Release-Notizen.</p>
            ]]></description>
        </item>

  Danach: main per Fast-Forward auf den Arbeitsbranch ziehen, pushen, und
  gegenprüfen, dass raw.githubusercontent.com den neuen Stand ausliefert
  (der CDN hängt rund eine Minute nach). Siehe CLAUDE.md.
EOF

OLD_DMG_COUNT=$(( $(ls -1 "$OUTDIR"/*.dmg 2>/dev/null | wc -l) - 1 ))
if (( OLD_DMG_COUNT > 2 )); then
    echo
    echo "  Hinweis: $OLD_DMG_COUNT ältere DMGs liegen noch in $OUTDIR."
fi

echo
echo "Done."
echo "App: $APP"
echo "DMG: $DMG_PATH"
