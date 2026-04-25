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

SIGN_IDENTITY="${SIGN_IDENTITY:-}"
NOTARY_PROFILE="${NOTARY_PROFILE:-}"
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
    echo "Appcast-Generierung übersprungen (SKIP_APPCAST=1)"
    echo
    echo "Done."
    echo "App: $APP"
    echo "DMG: $DMG_PATH"
    exit 0
fi

echo "[9/9] Generate appcast.xml"
SPARKLE_TOOLS="${SPARKLE_TOOLS:-$ROOT/.sparkle-tools}"
GENERATE_APPCAST="$SPARKLE_TOOLS/bin/generate_appcast"
if [[ -x "$GENERATE_APPCAST" ]]; then
    APPCAST_OUT="$OUTDIR/appcast.xml"
    DOWNLOAD_URL_PREFIX="${DOWNLOAD_URL_PREFIX:-https://simplebanking.de/download/}"
    "$GENERATE_APPCAST" "$OUTDIR" -o "$APPCAST_OUT" --download-url-prefix "$DOWNLOAD_URL_PREFIX"
    echo "Appcast: $APPCAST_OUT"
    echo "Upload $APPCAST_OUT and the .dmg to your server."
else
    echo "Sparkle tools not found at $SPARKLE_TOOLS/bin/generate_appcast"
    echo "Run ./setup-sparkle.sh once to install tools and generate keys."
fi

echo
echo "Done."
echo "App: $APP"
echo "DMG: $DMG_PATH"
