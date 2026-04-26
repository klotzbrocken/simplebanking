#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"

# Secrets.swift muss existieren (gitignored, generiert via make-secrets.sh)
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

# Universal binary: separat bauen, dann mit lipo zusammenführen
swift build -c release --arch arm64
swift build -c release --arch x86_64

BIN_ARM64="$ROOT/.build/arm64-apple-macosx/release/simplebanking"
BIN_X86="$ROOT/.build/x86_64-apple-macosx/release/simplebanking"
BIN="$ROOT/.build/universal/simplebanking"

mkdir -p "$ROOT/.build/universal"
lipo -create -output "$BIN" "$BIN_ARM64" "$BIN_X86"
echo "Universal binary created: $(lipo -archs "$BIN")"

if [[ ! -x "$BIN" ]]; then
    echo "Error: universal binary not found at $BIN"
    exit 1
fi
OUTDIR="$ROOT/SimpleBankingBuild"
APP="$OUTDIR/simplebanking.app"
ICON_SRC="${ICON_SRC:-$ROOT/Resources/icon_full_black.png}"
VERSION_BASE="${VERSION_BASE:-1.4.0}"

mkdir -p "$OUTDIR"
rm -rf "$APP"

BUILD_NUMBER_FILE="$OUTDIR/.build-number"
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
# Sparkle's version comparator breaks at '-' (treats it as pre-release dash).
# Use dash-free format: YYYYMMDD_HHMMSS_SEQ → Sparkle compares as single number 20260301 > 2026
BUILD_DATE_NODASH="$(date '+%Y%m%d')"
BUILD_TIME_NOCOLON="$(date '+%H%M%S')"
BUILD_NUMBER="${BUILD_DATE_NODASH}_${BUILD_TIME_NOCOLON}_${BUILD_SEQ}"

mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"

# Compile Metal shaders → default.metallib (fallback to precompiled if toolchain unavailable)
METAL_SRC_DIR="$ROOT/Sources/simplebanking"
METAL_WORK="$ROOT/.build/metal-work"
METALLIB_DEST="$APP/Contents/Resources/default.metallib"
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
elif [[ -f "$METALLIB_PRECOMPILED" ]]; then
    cp "$METALLIB_PRECOMPILED" "$METALLIB_DEST"
    echo "Metal shaders copied from precompiled → default.metallib"
else
    echo "Warning: no Metal shaders available — ripple effect will not work"
fi

# Read Sparkle config (generated once via setup-sparkle.sh)
SPARKLE_PUBLIC_KEY=""
SPARKLE_FEED_URL=""
if [[ -f "$ROOT/sparkle-public-key.txt" ]]; then
    SPARKLE_PUBLIC_KEY="$(tr -d '[:space:]' < "$ROOT/sparkle-public-key.txt")"
fi
if [[ -f "$ROOT/sparkle-feed-url.txt" ]]; then
    SPARKLE_FEED_URL="$(tr -d '[:space:]' < "$ROOT/sparkle-feed-url.txt")"
fi

CATEGORIES_JSON_SRC="$ROOT/Sources/simplebanking/Resources/categories_de.json"
CLIPPY_PNG_SRC="$ROOT/Sources/simplebanking/Resources/Clippy.png"
CLIPPY_ANIMATIONS_SRC="$ROOT/Sources/simplebanking/Resources/animations.json"
if [[ -f "$CATEGORIES_JSON_SRC" ]]; then
    cp "$CATEGORIES_JSON_SRC" "$APP/Contents/Resources/categories_de.json"
fi
if [[ -f "$CLIPPY_PNG_SRC" ]]; then
    cp "$CLIPPY_PNG_SRC" "$APP/Contents/Resources/Clippy.png"
fi
if [[ -f "$CLIPPY_ANIMATIONS_SRC" ]]; then
    cp "$CLIPPY_ANIMATIONS_SRC" "$APP/Contents/Resources/animations.json"
fi
BANK_LOGOS_SRC="$ROOT/Sources/simplebanking/Resources/bank-logos"
if [[ -d "$BANK_LOGOS_SRC" ]]; then
    cp -R "$BANK_LOGOS_SRC" "$APP/Contents/Resources/bank-logos"
fi
MERCHANT_LOGOS_SRC="$ROOT/Sources/simplebanking/Resources/merchant-logos"
if [[ -d "$MERCHANT_LOGOS_SRC" ]]; then
    cp -R "$MERCHANT_LOGOS_SRC" "$APP/Contents/Resources/merchant-logos"
fi

# Generate .icns from source PNG if available
if [[ -f "$ICON_SRC" ]]; then
    ICONSET="$ROOT/.build/AppIcon.iconset"
    rm -rf "$ICONSET"
    mkdir -p "$ICONSET"
    
    # Generate all required sizes
    sips -z 16 16     "$ICON_SRC" --out "$ICONSET/icon_16x16.png" >/dev/null 2>&1
    sips -z 32 32     "$ICON_SRC" --out "$ICONSET/icon_16x16@2x.png" >/dev/null 2>&1
    sips -z 32 32     "$ICON_SRC" --out "$ICONSET/icon_32x32.png" >/dev/null 2>&1
    sips -z 64 64     "$ICON_SRC" --out "$ICONSET/icon_32x32@2x.png" >/dev/null 2>&1
    sips -z 128 128   "$ICON_SRC" --out "$ICONSET/icon_128x128.png" >/dev/null 2>&1
    sips -z 256 256   "$ICON_SRC" --out "$ICONSET/icon_128x128@2x.png" >/dev/null 2>&1
    sips -z 256 256   "$ICON_SRC" --out "$ICONSET/icon_256x256.png" >/dev/null 2>&1
    sips -z 512 512   "$ICON_SRC" --out "$ICONSET/icon_256x256@2x.png" >/dev/null 2>&1
    sips -z 512 512   "$ICON_SRC" --out "$ICONSET/icon_512x512.png" >/dev/null 2>&1
    sips -z 1024 1024 "$ICON_SRC" --out "$ICONSET/icon_512x512@2x.png" >/dev/null 2>&1
    
    # Convert to .icns
    iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
    rm -rf "$ICONSET"
    
    # CFBundleIconFile (legacy): Finder/Dock zeigen das .icns aus Resources/.
    # CFBundleIconName (post-macOS-11): NSImage(named: "AppIcon") findet das Icon
    # ohne Asset-Catalog. Beide setzen — Finder und SwiftUI gehen auf
    # unterschiedliche Lookup-Pfade.
    ICON_KEY='<key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleIconName</key><string>AppIcon</string>'
    echo "Icon created from $ICON_SRC"
else
    ICON_KEY=""
    echo "Warning: Icon source not found at $ICON_SRC"
fi

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
  <key>LSUIElement</key><true/>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>SUFeedURL</key><string>${SPARKLE_FEED_URL}</string>
  <key>SUPublicEDKey</key><string>${SPARKLE_PUBLIC_KEY}</string>
  <key>NSRemindersUsageDescription</key><string>simplebanking erstellt Erinnerungen für Buchungen in der Reminders-App.</string>
  $ICON_KEY
</dict>
</plist>
PLIST

cp "$BIN" "$APP/Contents/MacOS/simplebanking"

# Build simplebanking-mcp (MCP server — no AppKit, no GRDB)
swift build -c release --arch arm64 --product simplebanking-mcp
swift build -c release --arch x86_64 --product simplebanking-mcp
MCP_ARM64="$ROOT/.build/arm64-apple-macosx/release/simplebanking-mcp"
MCP_X86="$ROOT/.build/x86_64-apple-macosx/release/simplebanking-mcp"
MCP_UNIVERSAL="$ROOT/.build/universal/simplebanking-mcp"
lipo -create -output "$MCP_UNIVERSAL" "$MCP_ARM64" "$MCP_X86"
cp "$MCP_UNIVERSAL" "$APP/Contents/MacOS/simplebanking-mcp"
echo "MCP server bundled: $(lipo -archs "$MCP_UNIVERSAL")"

# Build simplebanking-cli (Terminal CLI — liest DB/UserDefaults direkt)
swift build -c release --arch arm64 --product simplebanking-cli
swift build -c release --arch x86_64 --product simplebanking-cli
CLI_ARM64="$ROOT/.build/arm64-apple-macosx/release/simplebanking-cli"
CLI_X86="$ROOT/.build/x86_64-apple-macosx/release/simplebanking-cli"
CLI_UNIVERSAL="$ROOT/.build/universal/simplebanking-cli"
lipo -create -output "$CLI_UNIVERSAL" "$CLI_ARM64" "$CLI_X86"
cp "$CLI_UNIVERSAL" "$APP/Contents/MacOS/simplebanking-cli"
echo "CLI bundled: $(lipo -archs "$CLI_UNIVERSAL")"

# Embed Sparkle.framework (built by SPM)
SPARKLE_FW_SRC="$(find "$ROOT/.build/apple/Products/Release" -name "Sparkle.framework" -maxdepth 4 2>/dev/null | head -1 || true)"
if [[ -z "$SPARKLE_FW_SRC" ]]; then
    SPARKLE_FW_SRC="$(find "$ROOT/.build" -name "Sparkle.framework" -maxdepth 8 2>/dev/null | { grep -v 'checkouts' || true; } | { grep -v 'artifacts' || true; } | head -1 || true)"
fi
if [[ -n "$SPARKLE_FW_SRC" && -d "$SPARKLE_FW_SRC" ]]; then
    rm -rf "$APP/Contents/Frameworks/Sparkle.framework"
    cp -R "$SPARKLE_FW_SRC" "$APP/Contents/Frameworks/Sparkle.framework"
    # Add rpath so the binary finds Sparkle.framework at runtime inside the bundle
    install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP/Contents/MacOS/simplebanking" 2>/dev/null || true
    echo "Embedded Sparkle.framework from $SPARKLE_FW_SRC"
else
    echo "Warning: Sparkle.framework not found in build output — update checking will not work."
    echo "Run 'swift package resolve' to download Sparkle, then rebuild."
fi

# ad-hoc sign — use dev entitlements (no sandbox; sandbox requires Developer ID)
DEV_ENTITLEMENTS="$ROOT/Sources/simplebanking/simplebanking-dev.entitlements"
if [[ -f "$DEV_ENTITLEMENTS" ]]; then
    codesign --force --deep --sign - --entitlements "$DEV_ENTITLEMENTS" "$APP"
else
    codesign --force --deep --sign - "$APP"
fi

echo "Built app: $APP"
echo "Version: ${VERSION_BASE} (Build ${BUILD_NUMBER})"
echo "Built at: ${BUILD_TIMESTAMP}"
