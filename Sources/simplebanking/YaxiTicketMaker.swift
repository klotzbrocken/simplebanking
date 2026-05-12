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
    /// - Parameter useTransferKey: Wenn `true`, signiert das Ticket mit dem
    ///   License-gated Transfer-Pair statt dem Default-Pair. Nur für
    ///   `service == "Transfer"` relevant.
    static func issueTicket(service: String, data: Any? = nil, useTransferKey: Bool = false) -> String {
        let id = UUID().uuidString.lowercased()
        let now = Int(Date().timeIntervalSince1970)

        let kid = useTransferKey ? Secrets.yaxiTransferKeyId : Secrets.yaxiKeyId
        let secretB64 = useTransferKey ? Secrets.yaxiTransferSecretB64 : Secrets.yaxiSecretB64

        let header: [String: Any] = [
            "alg": "HS256",
            "kid": kid,
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

        let secretData = Data(base64Encoded: secretB64)!
        let key = SymmetricKey(data: secretData)
        let mac = HMAC<SHA256>.authenticationCode(for: Data(signingInput.utf8), using: key)
        let signature = base64URLEncode(Data(mac))

        return "\(signingInput).\(signature)"
    }

    /// Convenience: Transfer-Ticket. Laut YAXI-Doku
    /// (`docs.yaxi.tech/transfer.html`, „The service does not accept any
    /// ticket data.") trägt das Ticket-Payload kein Daten-Argument; alle
    /// Empfänger-Details werden direkt beim `client.transfer(details:)`
    /// Aufruf übergeben.
    ///
    /// **License-Gating:** signiert mit dem Transfer-Pair, sobald die App
    /// lizenziert ist (Polar oder REMOVE-FOR-RELEASE Master-Code).
    /// Ohne Lizenz fällt es auf das Default-Pair zurück — was YAXI-server-
    /// seitig für `Transfer` ablehnt und damit eine zweite Schutzschicht
    /// neben dem UI-Gate bildet.
    @MainActor
    static func issueTransferTicket() -> String {
        let licensed = LicenseManager.shared.isLicensedOrDemo
        return issueTicket(service: "Transfer", data: nil, useTransferKey: licensed)
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
