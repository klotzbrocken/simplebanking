#!/usr/bin/env bash
# One-time setup: download Sparkle tools + generate EdDSA signing keys.
# Run this once before your first signed release.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
TOOLS_DIR="$ROOT/.sparkle-tools"
SPARKLE_VERSION="${SPARKLE_VERSION:-2.6.4}"

# ── 1. Download Sparkle tools ────────────────────────────────────────────────
if [[ -x "$TOOLS_DIR/bin/generate_keys" ]]; then
    echo "Sparkle tools already installed at $TOOLS_DIR/bin/"
else
    echo "Downloading Sparkle $SPARKLE_VERSION tools..."
    TMPDIR_DL="$(mktemp -d)"
    trap 'rm -rf "$TMPDIR_DL"' EXIT

    curl -fL \
        "https://github.com/sparkle-project/Sparkle/releases/download/$SPARKLE_VERSION/Sparkle-$SPARKLE_VERSION.tar.xz" \
        -o "$TMPDIR_DL/Sparkle.tar.xz"

    tar -xJf "$TMPDIR_DL/Sparkle.tar.xz" -C "$TMPDIR_DL"

    mkdir -p "$TOOLS_DIR/bin"
    cp "$TMPDIR_DL/bin/generate_keys"    "$TOOLS_DIR/bin/"
    cp "$TMPDIR_DL/bin/generate_appcast" "$TOOLS_DIR/bin/"
    cp "$TMPDIR_DL/bin/sign_update"      "$TOOLS_DIR/bin/"
    chmod +x "$TOOLS_DIR/bin/"*

    echo "Tools installed to $TOOLS_DIR/bin/"
fi

# ── 2. Generate EdDSA key pair ───────────────────────────────────────────────
echo ""
echo "Generating EdDSA key pair..."
echo "(Private key is stored securely in your macOS Keychain)"
echo "─────────────────────────────────────────────────────────"
"$TOOLS_DIR/bin/generate_keys"
echo "─────────────────────────────────────────────────────────"
echo ""
echo "Copy the public key shown above (labeled 'SUPublicEDKey') and run:"
echo ""
echo "  echo 'PASTE_YOUR_PUBLIC_KEY_HERE' > \"$ROOT/sparkle-public-key.txt\""
echo ""

# ── 3. Create sparkle-feed-url.txt placeholder ───────────────────────────────
if [[ ! -f "$ROOT/sparkle-feed-url.txt" ]]; then
    echo "https://YOUR_SERVER/appcast.xml" > "$ROOT/sparkle-feed-url.txt"
    echo "Created sparkle-feed-url.txt — replace the placeholder with your real URL."
else
    echo "sparkle-feed-url.txt exists: $(cat "$ROOT/sparkle-feed-url.txt")"
fi

echo ""
echo "Next steps:"
echo "  1. Paste your public key into sparkle-public-key.txt (see above)"
echo "  2. Set your appcast URL in sparkle-feed-url.txt"
echo "  3. Run build-app.sh  — embeds the key + URL in Info.plist"
echo "  4. Run sign-and-notarize.sh  — signs everything + generates appcast.xml"
echo "  5. Upload the .dmg and appcast.xml to your server"
