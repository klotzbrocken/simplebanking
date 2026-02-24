#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"

APP="$ROOT/SimpleBankingBuild/simplebanking.app"
OUTDIR="$ROOT/SimpleBankingBuild"
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
STAGE_DIR="$OUTDIR/.dmg-stage-$TIMESTAMP"
DMG_PATH="$OUTDIR/simplebanking-$TIMESTAMP.dmg"

SIGN_IDENTITY="${SIGN_IDENTITY:-}"
NOTARY_PROFILE="${NOTARY_PROFILE:-}"
BUILD_FIRST="${BUILD_FIRST:-1}"

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

    echo "  Signing Sparkle.framework..."
    codesign --force --timestamp --options runtime \
        --sign "$SIGN_IDENTITY" "$SPARKLE_FW"
fi

# Main Swift binary — no special entitlements needed (not sandboxed)
codesign --force --timestamp --options runtime \
    --sign "$SIGN_IDENTITY" \
    "$APP/Contents/MacOS/simplebanking"

# yaxi-backend-node is a Node.js/V8 binary and requires JIT + unsigned-executable-memory.
# Without allow-jit, V8 cannot compile JavaScript and the backend will not function.
codesign --force --timestamp --options runtime \
    --entitlements "$ROOT/entitlements-backend-node.plist" \
    --sign "$SIGN_IDENTITY" \
    "$APP/Contents/Resources/yaxi-backend-node"

# yaxi-backend is a shell script — sign as a resource (no runtime options for scripts)
if [[ -f "$APP/Contents/Resources/yaxi-backend" ]]; then
    codesign --force --sign "$SIGN_IDENTITY" \
        "$APP/Contents/Resources/yaxi-backend"
fi

echo "[4/8] Sign app bundle (no --deep: nested binaries already signed with their own entitlements)"
# Do NOT use --deep here — it would re-sign nested binaries and overwrite
# the JIT entitlements set for yaxi-backend-node above.
codesign --force --timestamp --options runtime --sign "$SIGN_IDENTITY" "$APP"

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

echo "[9/9] Generate appcast.xml"
SPARKLE_TOOLS="${SPARKLE_TOOLS:-$ROOT/.sparkle-tools}"
GENERATE_APPCAST="$SPARKLE_TOOLS/bin/generate_appcast"
if [[ -x "$GENERATE_APPCAST" ]]; then
    APPCAST_OUT="$OUTDIR/appcast.xml"
    "$GENERATE_APPCAST" "$OUTDIR" -o "$APPCAST_OUT"
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
