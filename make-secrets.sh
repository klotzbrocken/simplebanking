#!/usr/bin/env bash
# make-secrets.sh — Generiert Sources/simplebanking/Secrets.swift aus Klartext-Credentials.
#
# Ausführen (einmalig pro Entwicklungsrechner):
#   ./make-secrets.sh "YAXI_KEY_ID" "YAXI_SECRET_BASE64" \
#                     ["YAXI_TRANSFER_KEY_ID" "YAXI_TRANSFER_SECRET_BASE64"]
#
# 2-arg form: nur Default-Pair (Read-only). Transfer-Pair wird auf das
# Default-Pair gespiegelt — Transfer-Calls scheitern dann an YAXI-Server.
# 4-arg form: separates License-gated Transfer-Pair.
#
# Die erzeugte Secrets.swift ist gitignored und muss NICHT committed werden.
# Bei einem neuen Rechner / CI einfach dieses Script erneut ausführen.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
OUT="$ROOT/Sources/simplebanking/Secrets.swift"

KEY_ID="${1:-}"
SECRET_B64="${2:-}"
TRANSFER_KEY_ID="${3:-$KEY_ID}"
TRANSFER_SECRET_B64="${4:-$SECRET_B64}"

if [[ -z "$KEY_ID" || -z "$SECRET_B64" ]]; then
    echo "Verwendung: ./make-secrets.sh \"YAXI_KEY_ID\" \"YAXI_SECRET_BASE64\" \\"
    echo "                              [\"TRANSFER_KEY_ID\" \"TRANSFER_SECRET_BASE64\"]"
    echo ""
    echo "Beispiel:"
    echo "  ./make-secrets.sh \"api-key-xxxx\" \"base64secret==\" \\"
    echo "                    \"api-key-yyyy\" \"transferB64==\""
    exit 1
fi

# XOR-Schlüssel (8 Bytes). Kann geändert werden – muss dann neu generiert werden.
XOR_KEY="0x4B, 0x9C, 0x33, 0xF7, 0xA1, 0x5E, 0x28, 0xD4"

# Python3 für zuverlässige Byte-Verarbeitung (Base64 enthält +, /, =)
RESULT=$(python3 - "$KEY_ID" "$SECRET_B64" "$TRANSFER_KEY_ID" "$TRANSFER_SECRET_B64" <<'PYEOF'
import sys

key = [0x4B, 0x9C, 0x33, 0xF7, 0xA1, 0x5E, 0x28, 0xD4]

def xor_encode(s):
    b = s.encode('utf-8')
    return ', '.join(f'0x{(byte ^ key[i % len(key)]):02X}' for i, byte in enumerate(b))

print(f"KEY_ID_BYTES={xor_encode(sys.argv[1])}")
print(f"SECRET_BYTES={xor_encode(sys.argv[2])}")
print(f"TKEY_ID_BYTES={xor_encode(sys.argv[3])}")
print(f"TSECRET_BYTES={xor_encode(sys.argv[4])}")
PYEOF
)

KEY_ID_BYTES=$(echo "$RESULT" | grep '^KEY_ID_BYTES=' | cut -d= -f2-)
SECRET_BYTES=$(echo "$RESULT" | grep '^SECRET_BYTES=' | cut -d= -f2-)
TKEY_ID_BYTES=$(echo "$RESULT" | grep '^TKEY_ID_BYTES=' | cut -d= -f2-)
TSECRET_BYTES=$(echo "$RESULT" | grep '^TSECRET_BYTES=' | cut -d= -f2-)

cat > "$OUT" <<SWIFT
// Secrets.swift — AUTO-GENERIERT von make-secrets.sh
// NICHT IN GIT EINCHECKEN — diese Datei ist gitignored.
// Neu generieren: ./make-secrets.sh "KEY_ID" "SECRET_BASE64" ["TRANSFER_KEY_ID" "TRANSFER_SECRET_BASE64"]

enum Secrets {
    private static let xorKey: [UInt8] = [$XOR_KEY]

    private static func xorDecrypt(_ bytes: [UInt8]) -> String {
        let dec = bytes.enumerated().map { idx, byte in
            byte ^ xorKey[idx % xorKey.count]
        }
        return String(bytes: dec, encoding: .utf8) ?? ""
    }

    /// Default-Pair (Read-only Pfad: Balances, Transactions, Accounts).
    static let yaxiKeyId: String     = xorDecrypt([$KEY_ID_BYTES])
    static let yaxiSecretB64: String = xorDecrypt([$SECRET_BYTES])

    /// Transfer-Pair (License-gated). Wird in YaxiTicketMaker.issueTransferTicket()
    /// nur genutzt, wenn LicenseManager.shared.isLicensed (Polar oder Master-Code).
    static let yaxiTransferKeyId: String     = xorDecrypt([$TKEY_ID_BYTES])
    static let yaxiTransferSecretB64: String = xorDecrypt([$TSECRET_BYTES])

    /// Optionaler Master-Code für lokale Dev-Tests (DEBUG-only via LicenseConfig).
    /// Default \`nil\` = kein Bypass. Wenn Du den Polar-Skip willst, ersetze diese
    /// Zeile manuell mit \`static let masterCode: String? = "<dein-test-key>"\` —
    /// diese Datei bleibt gitignored. NICHT Geburtsdatum/Namen nehmen.
    static let masterCode: String? = nil
}
SWIFT

echo "Secrets.swift generiert: $OUT"
