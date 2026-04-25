#!/usr/bin/env bash
# build-universal.sh — DEPRECATED.
#
# Dieses Skript baut nur das App-Binary (universal) und kopiert weder
# `simplebanking-mcp` noch `simplebanking-cli` ins Bundle. Wer es für
# Releases nutzt, würde die seit 1.4.0 beworbenen Agenten-Funktionen
# (CLI `sb`, MCP-Server) silent aus dem DMG entfernen. Außerdem ist
# das hard-coded VERSION_BASE hier veraltet (1.3.1).
#
# Stattdessen: `bash build-app.sh` — baut alle 3 Targets (App + MCP + CLI),
# erzeugt universal binary, kopiert alles ins Bundle.

set -euo pipefail

echo ""
echo "build-universal.sh ist deprecated."
echo "Stattdessen 'bash build-app.sh' nutzen — das baut zusätzlich"
echo "simplebanking-mcp und simplebanking-cli und kopiert sie ins Bundle."
echo ""
echo "Falls du das alte Verhalten WIRKLICH brauchst (App-only Build),"
echo "setze FORCE_UNIVERSAL_LEGACY=1 und ruf das Skript erneut."
echo ""
if [[ "${FORCE_UNIVERSAL_LEGACY:-0}" != "1" ]]; then
    exit 1
fi

ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"

SECRETS_FILE="$ROOT/Sources/simplebanking/Secrets.swift"
if [[ ! -f "$SECRETS_FILE" ]]; then
    echo "Fehler: Sources/simplebanking/Secrets.swift fehlt. ./make-secrets.sh aufrufen."
    exit 1
fi

bash "$ROOT/scripts/generate-bank-colors.sh"

echo "[1/3] Build arm64…"
swift build -c release --arch arm64 --scratch-path "$ROOT/.build-arm64"

echo "[2/3] Build x86_64…"
swift build -c release --arch x86_64 --scratch-path "$ROOT/.build-x86_64"

BIN_ARM="$ROOT/.build-arm64/arm64-apple-macosx/release/simplebanking"
BIN_X86="$ROOT/.build-x86_64/x86_64-apple-macosx/release/simplebanking"

OUTDIR="$ROOT/SimpleBankingBuild"
VERSION_BASE="${VERSION_BASE:-1.3.1}"
APP="$OUTDIR/simplebanking-${VERSION_BASE}-universal.app"
ICON_SRC="${ICON_SRC:-$ROOT/Resources/icon_full_black.png}"

mkdir -p "$OUTDIR"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"

echo "[3/3] lipo → Universal binary…"
lipo -create "$BIN_ARM" "$BIN_X86" -output "$APP/Contents/MacOS/simplebanking"

# Metal shaders — compile fresh, or fall back to arm64 build artifact
METAL_SRC_DIR="$ROOT/Sources/simplebanking"
METAL_WORK="$ROOT/.build/metal-work-universal"
METALLIB_DEST="$APP/Contents/Resources/default.metallib"
METALLIB_FALLBACK="$ROOT/SimpleBankingBuild/simplebanking.app/Contents/Resources/default.metallib"
METALLIB_PRECOMPILED="$ROOT/Resources/precompiled/default.metallib"
rm -rf "$METAL_WORK" && mkdir -p "$METAL_WORK"
METAL_AIR_FILES=()
while IFS= read -r -d '' mf; do
    air="$METAL_WORK/$(basename "${mf%.metal}.air")"
    xcrun -sdk macosx metal -c "$mf" -o "$air" 2>/dev/null && METAL_AIR_FILES+=("$air")
done < <(find "$METAL_SRC_DIR" -name "*.metal" -print0)
if [[ ${#METAL_AIR_FILES[@]} -gt 0 ]]; then
    xcrun -sdk macosx metallib "${METAL_AIR_FILES[@]}" -o "$METALLIB_DEST"
    echo "Metal shaders compiled → default.metallib"
elif [[ -f "$METALLIB_FALLBACK" ]]; then
    cp "$METALLIB_FALLBACK" "$METALLIB_DEST"
    echo "Metal shaders copied from arm64 build → default.metallib"
elif [[ -f "$METALLIB_PRECOMPILED" ]]; then
    cp "$METALLIB_PRECOMPILED" "$METALLIB_DEST"
    echo "Metal shaders copied from precompiled → default.metallib"
else
    echo "Warning: no Metal shaders — ripple effect will not work"
fi

# Resources
for f in categories_de.json Clippy.png animations.json; do
    src="$ROOT/Sources/simplebanking/Resources/$f"
    [[ -f "$src" ]] && cp "$src" "$APP/Contents/Resources/$f"
done
[[ -d "$ROOT/Sources/simplebanking/Resources/bank-logos" ]]     && cp -R "$ROOT/Sources/simplebanking/Resources/bank-logos"     "$APP/Contents/Resources/bank-logos"
[[ -d "$ROOT/Sources/simplebanking/Resources/merchant-logos" ]] && cp -R "$ROOT/Sources/simplebanking/Resources/merchant-logos" "$APP/Contents/Resources/merchant-logos"

# Icon
if [[ -f "$ICON_SRC" ]]; then
    ICONSET="$ROOT/.build/AppIcon-universal.iconset"
    rm -rf "$ICONSET" && mkdir -p "$ICONSET"
    sips -z 16   16   "$ICON_SRC" --out "$ICONSET/icon_16x16.png"      >/dev/null 2>&1
    sips -z 32   32   "$ICON_SRC" --out "$ICONSET/icon_16x16@2x.png"   >/dev/null 2>&1
    sips -z 32   32   "$ICON_SRC" --out "$ICONSET/icon_32x32.png"       >/dev/null 2>&1
    sips -z 64   64   "$ICON_SRC" --out "$ICONSET/icon_32x32@2x.png"   >/dev/null 2>&1
    sips -z 128  128  "$ICON_SRC" --out "$ICONSET/icon_128x128.png"     >/dev/null 2>&1
    sips -z 256  256  "$ICON_SRC" --out "$ICONSET/icon_128x128@2x.png" >/dev/null 2>&1
    sips -z 256  256  "$ICON_SRC" --out "$ICONSET/icon_256x256.png"     >/dev/null 2>&1
    sips -z 512  512  "$ICON_SRC" --out "$ICONSET/icon_256x256@2x.png" >/dev/null 2>&1
    sips -z 512  512  "$ICON_SRC" --out "$ICONSET/icon_512x512.png"     >/dev/null 2>&1
    sips -z 1024 1024 "$ICON_SRC" --out "$ICONSET/icon_512x512@2x.png" >/dev/null 2>&1
    iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
    rm -rf "$ICONSET"
    ICON_KEY='<key>CFBundleIconFile</key><string>AppIcon</string>'
else
    ICON_KEY=""
fi

# Sparkle
SPARKLE_PUBLIC_KEY=""
SPARKLE_FEED_URL=""
[[ -f "$ROOT/sparkle-public-key.txt" ]] && SPARKLE_PUBLIC_KEY="$(tr -d '[:space:]' < "$ROOT/sparkle-public-key.txt")"
[[ -f "$ROOT/sparkle-feed-url.txt" ]]   && SPARKLE_FEED_URL="$(tr -d '[:space:]' < "$ROOT/sparkle-feed-url.txt")"

SPARKLE_FW_SRC="$(find "$ROOT/.build/apple/Products/Release" -name "Sparkle.framework" -maxdepth 4 2>/dev/null | head -1)"
if [[ -z "$SPARKLE_FW_SRC" ]]; then
    SPARKLE_FW_SRC="$(find "$ROOT/.build" -name "Sparkle.framework" -maxdepth 8 2>/dev/null | grep -v 'checkouts' | grep -v 'artifacts' | head -1)"
fi
if [[ -n "$SPARKLE_FW_SRC" && -d "$SPARKLE_FW_SRC" ]]; then
    cp -R "$SPARKLE_FW_SRC" "$APP/Contents/Frameworks/Sparkle.framework"
    install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP/Contents/MacOS/simplebanking" 2>/dev/null || true
fi

# Info.plist
BUILD_DATE="$(date '+%Y-%m-%d')"
BUILD_TIME="$(date '+%H:%M:%S')"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleDisplayName</key><string>simplebanking</string>
  <key>CFBundleExecutable</key><string>simplebanking</string>
  <key>CFBundleIdentifier</key><string>tech.yaxi.simplebanking</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleName</key><string>simplebanking</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION_BASE}-universal</string>
  <key>CFBundleVersion</key><string>${VERSION_BASE}-universal</string>
  <key>SBBuildDate</key><string>${BUILD_DATE}</string>
  <key>SBBuildTime</key><string>${BUILD_TIME}</string>
  <key>LSUIElement</key><true/>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>SUFeedURL</key><string>${SPARKLE_FEED_URL}</string>
  <key>SUPublicEDKey</key><string>${SPARKLE_PUBLIC_KEY}</string>
  <key>NSRemindersUsageDescription</key><string>simplebanking erstellt Erinnerungen für Buchungen in der Reminders-App.</string>
  $ICON_KEY
</dict>
</plist>
PLIST

# Ad-hoc sign
DEV_ENTITLEMENTS="$ROOT/Sources/simplebanking/simplebanking-dev.entitlements"
if [[ -f "$DEV_ENTITLEMENTS" ]]; then
    codesign --force --deep --sign - --entitlements "$DEV_ENTITLEMENTS" "$APP"
else
    codesign --force --deep --sign - "$APP"
fi

DMG="$OUTDIR/simplebanking-${VERSION_BASE}-universal-$(date '+%Y%m%d-%H%M%S').dmg"
hdiutil create -volname "simplebanking" -srcfolder "$APP" -ov -format UDZO "$DMG" >/dev/null

echo ""
echo "Universal app: $APP"
echo "Universal DMG: $DMG"
echo "Architectures: $(lipo -archs "$APP/Contents/MacOS/simplebanking")"
