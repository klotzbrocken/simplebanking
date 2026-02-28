import Foundation
import CryptoKit

// MARK: - JWT ticket signing for the YAXI API
// Format mirrors the Node.js jsonwebtoken-based issueTicket() in backend/server.js.

enum YaxiTicketMaker {

    private static func base64URLEncode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .trimmingCharacters(in: CharacterSet(charactersIn: "="))
    }

    /// Issues a signed JWT ticket for the given YAXI service.
    /// - Parameter service: YAXI service name, e.g. "Balances", "Transactions", "Accounts".
    /// - Parameter data: Optional structured payload data (serialised as JSON). Pass nil for null.
    static func issueTicket(service: String, data: Any? = nil) -> String {
        let id = UUID().uuidString.lowercased()
        let now = Int(Date().timeIntervalSince1970)

        let header: [String: Any] = [
            "alg": "HS256",
            "kid": Secrets.yaxiKeyId,
            "typ": "JWT"
        ]

        let dataValue: Any = data ?? NSNull()
        let innerData: [String: Any] = [
            "service": service,
            "id": id,
            "data": dataValue
        ]
        let payload: [String: Any] = [
            "data": innerData,
            "exp": now + 600,
            "iat": now
        ]

        let headerJSON = try! JSONSerialization.data(withJSONObject: header, options: [.sortedKeys])
        let payloadJSON = try! JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])

        let headerEncoded = base64URLEncode(headerJSON)
        let payloadEncoded = base64URLEncode(payloadJSON)
        let signingInput = "\(headerEncoded).\(payloadEncoded)"

        let secretData = Data(base64Encoded: Secrets.yaxiSecretB64)!
        let key = SymmetricKey(data: secretData)
        let mac = HMAC<SHA256>.authenticationCode(for: Data(signingInput.utf8), using: key)
        let signature = base64URLEncode(Data(mac))

        return "\(signingInput).\(signature)"
    }

    /// Convenience: Transactions ticket including account and date range in the payload.
    static func issueTransactionsTicket(iban: String, currency: String = "EUR", from: String? = nil, to: String? = nil) -> String {
        var range: [String: Any] = [:]
        if let from { range["from"] = from }
        if let to { range["to"] = to }

        let data: [String: Any] = [
            "account": ["iban": iban, "currency": currency] as [String: Any],
            "range": range as [String: Any]
        ]
        return issueTicket(service: "Transactions", data: data as Any)
    }
}
