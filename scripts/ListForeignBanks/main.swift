import Foundation
import CryptoKit
import Routex

// MARK: - Secrets (inline copy of Sources/simplebanking/Secrets.swift)
// Lives in Secrets.swift via XOR-decoded byte arrays; replicated here so this
// one-off script can run without depending on the gitignored Secrets.swift
// being linked into another target.

private enum Secrets {
    static let xorKey: [UInt8] = [0x4B, 0x9C, 0x33, 0xF7, 0xA1, 0x5E, 0x28, 0xD4]

    static func xorDecrypt(_ bytes: [UInt8]) -> String {
        let dec = bytes.enumerated().map { idx, byte in byte ^ xorKey[idx % xorKey.count] }
        return String(bytes: dec, encoding: .utf8) ?? ""
    }

    static let yaxiKeyId: String     = xorDecrypt([0x2A, 0xEC, 0x5A, 0xDA, 0xCA, 0x3B, 0x51, 0xF9, 0x29, 0xF9, 0x0A, 0xC1, 0x99, 0x3F, 0x1B, 0xE6, 0x66, 0xF9, 0x04, 0x96, 0x97, 0x73, 0x1C, 0xE3, 0x28, 0xFA, 0x1E, 0xCE, 0x96, 0x6F, 0x4D, 0xF9, 0x7F, 0xA4, 0x04, 0x96, 0x96, 0x6E, 0x4B, 0xE0, 0x73, 0xF9, 0x06, 0x92])
    static let yaxiSecretB64: String = xorDecrypt([0x29, 0xCD, 0x06, 0x90, 0xF5, 0x1A, 0x42, 0xFF, 0x24, 0xF5, 0x06, 0xBB, 0x94, 0x12, 0x6E, 0xBF, 0x60, 0xDE, 0x7E, 0xC6, 0xCE, 0x6F, 0x60, 0xA1, 0x7D, 0xC9, 0x18, 0xBD, 0x93, 0x26, 0x1D, 0x9B, 0x33, 0xAA, 0x66, 0xA0, 0x97, 0x2D, 0x50, 0x80, 0x7F, 0xFB, 0x62, 0xC1, 0x97, 0x3A, 0x6E, 0xB9, 0x3E, 0xDB, 0x4B, 0xA6, 0xEB, 0x36, 0x1C, 0x99, 0x28, 0xD7, 0x42, 0xA0, 0xF4, 0x6C, 0x52, 0xE6, 0x24, 0xE6, 0x63, 0xA0, 0xCA, 0x07, 0x60, 0xE6, 0x19, 0xE8, 0x77, 0xB4, 0xD6, 0x6F, 0x58, 0x93, 0x18, 0xFD, 0x78, 0x9B, 0xF8, 0x1F, 0x15, 0xE9])
}

private enum TicketMaker {
    static func b64u(_ d: Data) -> String {
        d.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .trimmingCharacters(in: CharacterSet(charactersIn: "="))
    }

    static func issue(service: String) -> String {
        let id = UUID().uuidString.lowercased()
        let now = Int(Date().timeIntervalSince1970)
        let header: [String: Any] = ["alg": "HS256", "kid": Secrets.yaxiKeyId, "typ": "JWT"]
        let inner: [String: Any] = ["service": service, "id": id, "data": NSNull()]
        let payload: [String: Any] = ["data": inner, "exp": now + 600, "iat": now]
        let hJSON = try! JSONSerialization.data(withJSONObject: header, options: [.sortedKeys])
        let pJSON = try! JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        let signing = "\(b64u(hJSON)).\(b64u(pJSON))"
        let key = SymmetricKey(data: Data(base64Encoded: Secrets.yaxiSecretB64)!)
        let mac = HMAC<SHA256>.authenticationCode(for: Data(signing.utf8), using: key)
        return "\(signing).\(b64u(Data(mac)))"
    }
}

@main
struct ListForeignBanks {
    static func main() async {
        let countries = ["AT", "CH", "FR", "IT", "ES", "NL", "BE", "LU", "GB"]
        let client = RoutexClient()

        for cc in countries {
            var banks: [ConnectionInfo] = []
            let ticket = TicketMaker.issue(service: "Accounts")
            do {
                banks = try await client.search(
                    ticket: ticket,
                    filters: [.countries(countries: [cc])],
                    ibanDetection: false,
                    limit: 500
                )
            } catch {
                FileHandle.standardError.write(Data("[\(cc)] countries-only search failed: \(error)\n".utf8))
            }

            if banks.isEmpty {
                // Some YAXI configurations require at least one positive term.
                // Fall back to a broad "a" term to enumerate.
                let ticket2 = TicketMaker.issue(service: "Accounts")
                do {
                    banks = try await client.search(
                        ticket: ticket2,
                        filters: [.countries(countries: [cc]), .term(term: "a")],
                        ibanDetection: false,
                        limit: 500
                    )
                } catch {
                    FileHandle.standardError.write(Data("[\(cc)] fallback search failed: \(error)\n".utf8))
                }
            }

            let sorted = banks.sorted { $0.displayName.lowercased() < $1.displayName.lowercased() }
            print("\n=== \(cc) — \(sorted.count) Banken ===")
            for b in sorted {
                print("  \(b.displayName)")
            }
        }
    }
}
