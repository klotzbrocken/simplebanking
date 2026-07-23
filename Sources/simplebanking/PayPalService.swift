import Foundation

/// PayPal-Anbindung über die klassische **NVP-API** mit API-Signatur
/// (`GetBalance` + `TransactionSearch`). Das ist der einzige Weg für PRIVATE
/// PayPal-Konten — die offizielle REST-Reporting-API ist Business-only.
///
/// ⚠️ Diese NVP-Endpunkte sind von PayPal seit 2017 als *deprecated* markiert
/// und können künftig abgeschaltet werden. Read-only (Saldo + Umsätze).
///
/// Aufbau bewusst wie `YaxiService`: dünne Netzwerk-Schicht + reine, testbare
/// Parser/Mapper (kein Netzwerk in den `static`-Funktionen unten).
enum PayPalService {

    static let apiVersion = "204"

    /// Signature-Endpoint (Live vs. Sandbox). Zertifikats-Endpoint (api.paypal.com)
    /// wird NICHT genutzt — wir authentifizieren per Signatur.
    static func endpoint(sandbox: Bool) -> URL {
        URL(string: sandbox ? "https://api-3t.sandbox.paypal.com/nvp"
                            : "https://api-3t.paypal.com/nvp")!
    }

    struct Credentials: Sendable {
        let user: String        // API-Username
        let pwd: String         // API-Passwort
        let signature: String   // API-Signature
        var sandbox: Bool = false
    }

    enum PayPalError: LocalizedError {
        case apiError(String)
        case badResponse
        var errorDescription: String? {
            switch self {
            case .apiError(let m): return "PayPal: \(m)"
            case .badResponse: return "PayPal: Ungültige Antwort."
            }
        }
    }

    // MARK: - Reine NVP-Verarbeitung (testbar, kein Netzwerk)

    /// Parst einen `key=value&key2=value2`-NVP-Body in ein Dictionary
    /// (URL-dekodiert, `+` → Leerzeichen).
    static func parseNVP(_ body: String) -> [String: String] {
        var result: [String: String] = [:]
        for pair in body.split(separator: "&", omittingEmptySubsequences: true) {
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard let rawKey = parts.first else { continue }
            let key = decode(String(rawKey))
            let value = parts.count > 1 ? decode(String(parts[1])) : ""
            result[key] = value
        }
        return result
    }

    private static func decode(_ s: String) -> String {
        s.replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? s
    }

    /// Kontostand aus einer `GetBalance`-Antwort. Primärwährung = `L_AMT0`.
    static func balance(fromNVP nvp: [String: String]) -> Double? {
        guard let raw = nvp["L_AMT0"] ?? nvp["AMT"], let v = Double(raw) else { return nil }
        return v
    }

    /// Ob die NVP-Antwort erfolgreich war (`ACK` = Success / SuccessWithWarning).
    static func isSuccess(_ nvp: [String: String]) -> Bool {
        let ack = (nvp["ACK"] ?? "").lowercased()
        return ack == "success" || ack == "successwithwarning"
    }

    /// Fehlermeldung aus einer NVP-Antwort (Long- vor Short-Message).
    static func errorMessage(_ nvp: [String: String]) -> String {
        nvp["L_LONGMESSAGE0"] ?? nvp["L_SHORTMESSAGE0"] ?? "Unbekannter Fehler"
    }

    /// Mappt eine `TransactionSearch`-Antwort auf das normale Transaktionsmodell.
    /// PayPal liefert indizierte Felder `L_*0, L_*1, …`.
    static func transactions(fromNVP nvp: [String: String], slotId: String) -> [TransactionsResponse.Transaction] {
        var result: [TransactionsResponse.Transaction] = []
        var i = 0
        while let ts = nvp["L_TIMESTAMP\(i)"] {
            defer { i += 1 }
            let amtStr = nvp["L_AMT\(i)"] ?? "0"
            let amtValue = Double(amtStr) ?? 0
            let currency = nvp["L_CURRENCYCODE\(i)"] ?? "EUR"
            let type = nvp["L_TYPE\(i)"]?.nilIfEmpty
            let name = (nvp["L_NAME\(i)"]?.nilIfEmpty) ?? nvp["L_EMAIL\(i)"]?.nilIfEmpty
            let txid = nvp["L_TRANSACTIONID\(i)"]?.nilIfEmpty
            let status = nvp["L_STATUS\(i)"]?.nilIfEmpty
            let day = String(ts.prefix(10))   // ISO "yyyy-MM-dd…" → "yyyy-MM-dd"

            let party = TransactionsResponse.Party(name: name, iban: nil, bic: nil)
            // Bank-Semantik: Ausgabe (negativ) → Gegenpartei ist Kreditor (Empfänger),
            // Eingang (positiv) → Gegenpartei ist Debitor (Absender).
            let creditor = amtValue < 0 ? party : nil
            let debtor = amtValue >= 0 ? party : nil
            let remittance = [type, name].compactMap { $0 }.joined(separator: " · ")

            result.append(TransactionsResponse.Transaction(
                bookingDate: day,
                valueDate: day,
                status: status,
                endToEndId: txid,
                amount: .init(currency: currency, amount: amtStr),
                creditor: creditor,
                debtor: debtor,
                remittanceInformation: remittance.isEmpty ? nil : [remittance],
                additionalInformation: type,
                purposeCode: nil,
                category: nil,
                slotId: slotId
            ))
        }
        return result
    }

    // MARK: - Netzwerk

    /// Führt einen NVP-Call aus und liefert das geparste Antwort-Dictionary.
    /// Wirft `PayPalError.apiError` wenn `ACK` nicht Success ist.
    static func call(method: String, params: [String: String], creds: Credentials) async throws -> [String: String] {
        var fields: [String: String] = [
            "USER": creds.user,
            "PWD": creds.pwd,
            "SIGNATURE": creds.signature,
            "VERSION": apiVersion,
            "METHOD": method
        ]
        for (k, v) in params { fields[k] = v }

        var request = URLRequest(url: endpoint(sandbox: creds.sandbox))
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = encodeForm(fields).data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let body = String(data: data, encoding: .utf8) else {
            throw PayPalError.badResponse
        }
        let nvp = parseNVP(body)
        guard isSuccess(nvp) else { throw PayPalError.apiError(errorMessage(nvp)) }
        return nvp
    }

    static func fetchBalance(creds: Credentials) async throws -> Double {
        let nvp = try await call(method: "GetBalance", params: ["RETURNALLCURRENCIES": "0"], creds: creds)
        guard let bal = balance(fromNVP: nvp) else { throw PayPalError.badResponse }
        return bal
    }

    static func fetchTransactions(days: Int, slotId: String, creds: Credentials) async throws -> [TransactionsResponse.Transaction] {
        let start = Date().addingTimeInterval(-Double(max(1, days)) * 86_400)
        let fmt = ISO8601DateFormatter()
        let nvp = try await call(method: "TransactionSearch",
                                 params: ["STARTDATE": fmt.string(from: start)],
                                 creds: creds)
        return transactions(fromNVP: nvp, slotId: slotId)
    }

    /// Form-Encoding (RFC 3986) für den NVP-Body.
    private static func encodeForm(_ fields: [String: String]) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return fields.map { key, value in
            let k = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key
            let v = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
            return "\(k)=\(v)"
        }.joined(separator: "&")
    }
}
