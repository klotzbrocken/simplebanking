#!/usr/bin/env bash
# make-secrets.sh — Generiert Sources/simplebanking/Secrets.swift aus Klartext-Credentials.
#
# Ausführen (einmalig pro Entwicklungsrechner):
#   ./make-secrets.sh "YAXI_KEY_ID" "YAXI_SECRET_BASE64"
#
# Die erzeugte Secrets.swift ist gitignored und muss NICHT committed werden.
# Bei einem neuen Rechner / CI einfach dieses Script erneut ausführen.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
OUT="$ROOT/Sources/simplebanking/Secrets.swift"

KEY_ID="${1:-}"
SECRET_B64="${2:-}"

if [[ -z "$KEY_ID" || -z "$SECRET_B64" ]]; then
    echo "Verwendung: ./make-secrets.sh \"YAXI_KEY_ID\" \"YAXI_SECRET_BASE64\""
    echo ""
    echo "Beispiel:"
    echo "  ./make-secrets.sh \"api-key-xxxx\" \"base64secret==\""
    exit 1
fi

# XOR-Schlüssel (8 Bytes). Kann geändert werden – muss dann neu generiert werden.
XOR_KEY="0x4B, 0x9C, 0x33, 0xF7, 0xA1, 0x5E, 0x28, 0xD4"

# Python3 für zuverlässige Byte-Verarbeitung (Base64 enthält +, /, =)
RESULT=$(python3 - "$KEY_ID" "$SECRET_B64" <<'PYEOF'
import sys

key = [0x4B, 0x9C, 0x33, 0xF7, 0xA1, 0x5E, 0x28, 0xD4]

def xor_encode(s):
    b = s.encode('utf-8')
    out = []
    for i, byte in enumerate(b):
        out.append(byte ^ key[i % len(key)])
    return ', '.join(f'0x{x:02X}' for x in out)

key_id = sys.argv[1]
secret = sys.argv[2]

print(f"KEY_ID_BYTES={xor_encode(key_id)}")
print(f"SECRET_BYTES={xor_encode(secret)}")
PYEOF
)

KEY_ID_BYTES=$(echo "$RESULT" | grep '^KEY_ID_BYTES=' | cut -d= -f2-)
SECRET_BYTES=$(echo "$RESULT" | grep '^SECRET_BYTES=' | cut -d= -f2-)

cat > "$OUT" <<SWIFT
// Secrets.swift — AUTO-GENERIERT von make-secrets.sh
// NICHT IN GIT EINCHECKEN — diese Datei ist gitignored.
// Neu generieren: ./make-secrets.sh "KEY_ID" "SECRET_BASE64"

enum Secrets {
    private static let xorKey: [UInt8] = [$XOR_KEY]

    private static func xorDecrypt(_ bytes: [UInt8]) -> String {
        let dec = bytes.enumerated().map { idx, byte in
            byte ^ xorKey[idx % xorKey.count]
        }
        return String(bytes: dec, encoding: .utf8) ?? ""
    }

    static let yaxiKeyId: String     = xorDecrypt([$KEY_ID_BYTES])
    static let yaxiSecretB64: String = xorDecrypt([$SECRET_BYTES])
}
SWIFT

echo "Secrets.swift generiert: $OUT"
