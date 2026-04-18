#!/usr/bin/env bash
# build-mas.sh — Mac App Store Build
# Baut simplebanking.app + simplebanking.pkg für den Mac App Store.
#
# Voraussetzungen:
#   • Certificates in Keychain:
#       "3rd Party Mac Developer Application: Maik Klotz (FTJLR8JRNS)"
#       "3rd Party Mac Developer Installer: Maik Klotz (FTJLR8JRNS)"
#   • Provisioning Profile:
#       ~/Downloads/simplebanking_AppStore.provisionprofile
#       (oder PROV_PROFILE= env-Variable setzen)
#
# Aufruf:
#   ./build-mas.sh
#   VERSION_BASE=1.3.0 ./build-mas.sh

set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"

# Secrets.swift muss existieren
SECRETS_FILE="$ROOT/Sources/simplebanking/Secrets.swift"
if [[ ! -f "$SECRETS_FILE" ]]; then
    echo ""
    echo "Fehler: Sources/simplebanking/Secrets.swift fehlt."
    echo "Einmalig generieren mit:"
    echo "  ./make-secrets.sh \"YAXI_KEY_ID\" \"YAXI_SECRET_BASE64\""
    echo ""
    exit 1
fi

# Generiere GeneratedBankColors.swift aus SVG-Metadaten
bash "$ROOT/scripts/generate-bank-colors.sh"

# Provisioning Profile
PROV_PROFILE="${PROV_PROFILE:-$HOME/Downloads/simplebanking_AppStore.provisionprofile}"
if [[ ! -f "$PROV_PROFILE" ]]; then
    echo ""
    echo "Fehler: Provisioning Profile nicht gefunden: $PROV_PROFILE"
    echo "Lade es unter https://developer.apple.com/account → Profiles herunter"
    echo "oder setze: PROV_PROFILE=/pfad/zum/profil.provisionprofile ./build-mas.sh"
    echo ""
    exit 1
fi

APP_CERT="3rd Party Mac Developer Application: Maik Klotz (FTJLR8JRNS)"
PKG_CERT="3rd Party Mac Developer Installer: Maik Klotz (FTJLR8JRNS)"
ENTITLEMENTS="$ROOT/Sources/simplebanking/simplebanking-mas.entitlements"

# Build (arm64, release)
swift build -c release --arch arm64

BIN="$ROOT/.build/arm64-apple-macosx/release/simplebanking"
if [[ ! -x "$BIN" ]]; then
    echo "Error: built binary not found at $BIN"
    exit 1
fi

OUTDIR="$ROOT/SimpleBankingBuild"
APP="$OUTDIR/simplebanking.app"
ICON_SRC="${ICON_SRC:-$ROOT/Resources/icon_full_black.png}"
VERSION_BASE="${VERSION_BASE:-1.2.4}"

mkdir -p "$OUTDIR"
rm -rf "$APP"

# Build-Nummer
BUILD_NUMBER_FILE="$OUTDIR/.build-number-mas"
PREVIOUS_BUILD="0"
if [[ -f "$BUILD_NUMBER_FILE" ]]; then
    PREVIOUS_BUILD="$(tr -d '[:space:]' < "$BUILD_NUMBER_FILE")"
fi
if [[ ! "$PREVIOUS_BUILD" =~ ^[0-9]+$ ]]; then
    PREVIOUS_BUILD="0"
fi
BUILD_SEQ="$((PREVIOUS_BUILD + 1))"
printf "%s\n" "$BUILD_SEQ" > "$BUILD_NUMBER_FILE"
BUILD_DATE="$(date '+%Y-%m-%d')"
BUILD_TIME="$(date '+%H:%M:%S')"
BUILD_TIMESTAMP="$BUILD_DATE $BUILD_TIME"
BUILD_NUMBER="${BUILD_SEQ}"

mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"

# Compile Metal shaders → default.metallib
METAL_SRC_DIR="$ROOT/Sources/simplebanking"
METAL_WORK="$ROOT/.build/metal-work"
rm -rf "$METAL_WORK" && mkdir -p "$METAL_WORK"
METAL_AIR_FILES=()
while IFS= read -r -d '' mf; do
    air="$METAL_WORK/$(basename "${mf%.metal}.air")"
    xcrun -sdk macosx metal -c "$mf" -o "$air" && METAL_AIR_FILES+=("$air")
done < <(find "$METAL_SRC_DIR" -name "*.metal" -print0)
if [[ ${#METAL_AIR_FILES[@]} -gt 0 ]]; then
    xcrun -sdk macosx metallib "${METAL_AIR_FILES[@]}" -o "$APP/Contents/Resources/default.metallib"
    echo "Metal shaders compiled → default.metallib"
fi

# Resources kopieren
CATEGORIES_JSON_SRC="$ROOT/Sources/simplebanking/Resources/categories_de.json"
CLIPPY_PNG_SRC="$ROOT/Sources/simplebanking/Resources/Clippy.png"
CLIPPY_ANIMATIONS_SRC="$ROOT/Sources/simplebanking/Resources/animations.json"
[[ -f "$CATEGORIES_JSON_SRC" ]] && cp "$CATEGORIES_JSON_SRC" "$APP/Contents/Resources/categories_de.json"
[[ -f "$CLIPPY_PNG_SRC" ]] && cp "$CLIPPY_PNG_SRC" "$APP/Contents/Resources/Clippy.png"
[[ -f "$CLIPPY_ANIMATIONS_SRC" ]] && cp "$CLIPPY_ANIMATIONS_SRC" "$APP/Contents/Resources/animations.json"
BANK_LOGOS_SRC="$ROOT/Sources/simplebanking/Resources/bank-logos"
[[ -d "$BANK_LOGOS_SRC" ]] && cp -R "$BANK_LOGOS_SRC" "$APP/Contents/Resources/bank-logos"
MERCHANT_LOGOS_SRC="$ROOT/Sources/simplebanking/Resources/merchant-logos"
[[ -d "$MERCHANT_LOGOS_SRC" ]] && cp -R "$MERCHANT_LOGOS_SRC" "$APP/Contents/Resources/merchant-logos"

# Icon
if [[ -f "$ICON_SRC" ]]; then
    ICONSET="$ROOT/.build/AppIcon.iconset"
    rm -rf "$ICONSET" && mkdir -p "$ICONSET"
    sips -z 16 16     "$ICON_SRC" --out "$ICONSET/icon_16x16.png"     >/dev/null 2>&1
    sips -z 32 32     "$ICON_SRC" --out "$ICONSET/icon_16x16@2x.png"  >/dev/null 2>&1
    sips -z 32 32     "$ICON_SRC" --out "$ICONSET/icon_32x32.png"     >/dev/null 2>&1
    sips -z 64 64     "$ICON_SRC" --out "$ICONSET/icon_32x32@2x.png"  >/dev/null 2>&1
    sips -z 128 128   "$ICON_SRC" --out "$ICONSET/icon_128x128.png"   >/dev/null 2>&1
    sips -z 256 256   "$ICON_SRC" --out "$ICONSET/icon_128x128@2x.png" >/dev/null 2>&1
    sips -z 256 256   "$ICON_SRC" --out "$ICONSET/icon_256x256.png"   >/dev/null 2>&1
    sips -z 512 512   "$ICON_SRC" --out "$ICONSET/icon_256x256@2x.png" >/dev/null 2>&1
    sips -z 512 512   "$ICON_SRC" --out "$ICONSET/icon_512x512.png"   >/dev/null 2>&1
    sips -z 1024 1024 "$ICON_SRC" --out "$ICONSET/icon_512x512@2x.png" >/dev/null 2>&1
    iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
    rm -rf "$ICONSET"
    ICON_KEY='<key>CFBundleIconFile</key><string>AppIcon</string>'
    echo "Icon created from $ICON_SRC"
else
    ICON_KEY=""
    echo "Warning: Icon source not found at $ICON_SRC"
fi

# Info.plist — KEIN Sparkle (SUFeedURL / SUPublicEDKey) für MAS
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
  <key>CFBundleShortVersionString</key><string>${VERSION_BASE}</string>
  <key>CFBundleVersion</key><string>${BUILD_NUMBER}</string>
  <key>SBBuildDate</key><string>${BUILD_DATE}</string>
  <key>SBBuildTime</key><string>${BUILD_TIME}</string>
  <key>SBBuildTimestamp</key><string>${BUILD_TIMESTAMP}</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.finance</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSRemindersUsageDescription</key><string>simplebanking erstellt Erinnerungen für Buchungen in der Reminders-App.</string>
  ${ICON_KEY}
</dict>
</plist>
PLIST

cp "$BIN" "$APP/Contents/MacOS/simplebanking"

# Provisioning Profile einbetten
cp "$PROV_PROFILE" "$APP/Contents/embedded.provisionprofile"
echo "Embedded provisioning profile: $(basename "$PROV_PROFILE")"

# Quarantine-Attribute entfernen (App Store erlaubt diese nicht)
xattr -cr "$APP"

# App signieren mit MAS-Zertifikat + MAS-Entitlements
echo "Signing app with: $APP_CERT"
codesign --force --deep --sign "$APP_CERT" \
    --entitlements "$ENTITLEMENTS" \
    --options runtime \
    "$APP"

# Signierung prüfen
codesign --verify --deep --strict "$APP" && echo "Signature: OK"

# .pkg erstellen und signieren
PKG="$OUTDIR/simplebanking-${VERSION_BASE}.pkg"
rm -f "$PKG"

echo "Building pkg..."
xcrun productbuild \
    --component "$APP" /Applications \
    --sign "$PKG_CERT" \
    "$PKG"

echo ""
echo "✓ MAS Build fertig!"
echo "  App:     $APP"
echo "  Package: $PKG"
echo "  Version: ${VERSION_BASE} (Build ${BUILD_NUMBER})"
echo ""
echo "Nächste Schritte:"
echo "  1. App Store Connect öffnen: https://appstoreconnect.apple.com"
echo "  2. Neue Version unter 'Apps → simplebanking' anlegen"
echo "  3. PKG über Transporter hochladen:"
echo "     open -a Transporter"
echo "     → Drag & drop: $PKG"
echo ""
