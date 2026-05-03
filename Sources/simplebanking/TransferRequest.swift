import Foundation

// MARK: - TransferRequest
//
// App-eigenes Modell für einen einzelnen ausgehenden SEPA-Credit-Transfer.
// Bewusst minimalistisch: nur die Felder, die TransferDetails der Routex-API
// tatsächlich braucht, plus app-Konventionen (EUR-only, Klartext-IBAN ohne
// Spaces, normalisierter Großbuchstaben-Country-Code).
//
// Validation läuft im throwing-Initializer, damit das Modell nach Konstruktion
// garantiert sendbar ist. UI-Code kann TransferRequestError fangen und
// ins richtige Eingabefeld zurückzeigen.

struct TransferRequest: Equatable, Sendable {
    let creditorName: String
    /// Normalisiert: keine Leerzeichen, alles Großbuchstaben.
    let creditorIban: String
    let amountEUR: Decimal
    let remittance: String?
    let endToEndId: String?

    init(
        creditorName: String,
        creditorIban: String,
        amountEUR: Decimal,
        remittance: String? = nil,
        endToEndId: String? = nil
    ) throws {
        let trimmedName = creditorName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { throw TransferRequestError.emptyName }
        guard trimmedName.count <= 70 else {
            // SEPA-PAIN.001 begrenzt creditor name auf 70 Zeichen.
            throw TransferRequestError.nameTooLong(actual: trimmedName.count)
        }

        let normalizedIban = TransferRequest.normalizeIban(creditorIban)
        try TransferRequest.validateIban(normalizedIban)

        guard amountEUR > 0 else { throw TransferRequestError.nonPositiveAmount }
        // SEPA-Limit: 999_999_999.99 EUR theoretisch; pragmatisch 100_000 EUR
        // damit ein Tippfehler im UI nicht zur Katastrophe wird.
        guard amountEUR <= Decimal(string: "100000") ?? 0 else {
            throw TransferRequestError.amountTooLarge
        }

        let trimmedRemittance = remittance?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let r = trimmedRemittance, r.count > 140 {
            // SEPA-PAIN.001 limitiert remittance information auf 140 Zeichen.
            throw TransferRequestError.remittanceTooLong(actual: r.count)
        }

        let trimmedEndToEnd = endToEndId?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let e = trimmedEndToEnd, e.count > 35 {
            throw TransferRequestError.endToEndIdTooLong(actual: e.count)
        }

        self.creditorName = trimmedName
        self.creditorIban = normalizedIban
        self.amountEUR = amountEUR
        self.remittance = (trimmedRemittance?.isEmpty == false) ? trimmedRemittance : nil
        self.endToEndId = (trimmedEndToEnd?.isEmpty == false) ? trimmedEndToEnd : nil
    }

    // MARK: - IBAN

    /// Entfernt Whitespace, macht alles Uppercase. User-Eingabe-Kosmetik.
    static func normalizeIban(_ raw: String) -> String {
        raw.uppercased()
            .components(separatedBy: .whitespacesAndNewlines)
            .joined()
    }

    /// IBAN-Validation per ISO 13616 mod-97 plus Längen-Check pro Land.
    /// Wirft `TransferRequestError.invalidIban(reason:)` bei Fehler.
    static func validateIban(_ iban: String) throws {
        guard iban.count >= 15 && iban.count <= 34 else {
            throw TransferRequestError.invalidIban(reason: "Length \(iban.count) outside 15…34")
        }
        let countryCode = String(iban.prefix(2))
        guard countryCode.allSatisfy({ $0.isLetter && $0.isASCII }) else {
            throw TransferRequestError.invalidIban(reason: "Country code must be 2 ASCII letters")
        }
        let checkDigits = iban.dropFirst(2).prefix(2)
        guard checkDigits.allSatisfy({ $0.isNumber }) else {
            throw TransferRequestError.invalidIban(reason: "Check digits must be numeric")
        }
        if let expected = TransferRequest.countryIbanLength[countryCode],
           iban.count != expected {
            throw TransferRequestError.invalidIban(
                reason: "\(countryCode) IBAN must be \(expected) chars, got \(iban.count)"
            )
        }
        let bban = iban.dropFirst(4)
        guard bban.allSatisfy({ $0.isLetter || $0.isNumber }) else {
            throw TransferRequestError.invalidIban(reason: "Non-alphanumeric character in BBAN")
        }
        // mod-97-Check: ersten 4 Zeichen ans Ende, Buchstaben → Zahlen, mod 97 == 1.
        let rearranged = String(iban.dropFirst(4)) + String(iban.prefix(4))
        var numericString = ""
        for char in rearranged {
            if let digit = char.wholeNumberValue {
                numericString.append(String(digit))
            } else if char.isLetter, let ascii = char.asciiValue {
                let value = Int(ascii - Character("A").asciiValue!) + 10
                numericString.append(String(value))
            }
        }
        // Big-Int mod ohne BigInt-Library: chunk-weise reduzieren.
        var remainder = 0
        for char in numericString {
            guard let digit = char.wholeNumberValue else {
                throw TransferRequestError.invalidIban(reason: "mod-97 prep produced non-digit")
            }
            remainder = (remainder * 10 + digit) % 97
        }
        guard remainder == 1 else {
            throw TransferRequestError.invalidIban(reason: "Checksum (mod-97) failed")
        }
    }

    /// Top-EU-IBAN-Längen. Bei nicht-gelisteten Ländern erlauben wir 15…34 generisch.
    private static let countryIbanLength: [String: Int] = [
        "DE": 22, "AT": 20, "CH": 21, "FR": 27, "IT": 27, "ES": 24,
        "NL": 18, "BE": 16, "LU": 20, "PT": 25, "IE": 22, "FI": 18,
        "DK": 18, "SE": 24, "NO": 15, "PL": 28, "CZ": 24, "HU": 28,
        "GB": 22, "GR": 27, "LI": 21, "MT": 31, "MC": 27, "SM": 27,
        "EE": 20, "LV": 21, "LT": 20, "SI": 19, "SK": 24, "BG": 22,
        "RO": 24, "HR": 21, "CY": 28, "IS": 26
    ]
}

// MARK: - Errors

enum TransferRequestError: Error, Equatable {
    case emptyName
    case nameTooLong(actual: Int)
    case invalidIban(reason: String)
    case nonPositiveAmount
    case amountTooLarge
    case remittanceTooLong(actual: Int)
    case endToEndIdTooLong(actual: Int)

    var localizedHint: String {
        switch self {
        case .emptyName:
            return L10n.t("Name des Empfängers fehlt.", "Recipient name is missing.")
        case .nameTooLong:
            return L10n.t("Name zu lang (max. 70 Zeichen).", "Name too long (max 70 chars).")
        case .invalidIban(let reason):
            return L10n.t("IBAN ungültig: \(reason)", "Invalid IBAN: \(reason)")
        case .nonPositiveAmount:
            return L10n.t("Betrag muss größer als 0 sein.", "Amount must be greater than 0.")
        case .amountTooLarge:
            return L10n.t("Betrag zu hoch (max. 100.000 €).", "Amount too high (max 100,000 €).")
        case .remittanceTooLong:
            return L10n.t("Verwendungszweck zu lang (max. 140 Zeichen).",
                          "Purpose too long (max 140 chars).")
        case .endToEndIdTooLong:
            return L10n.t("End-to-End-ID zu lang (max. 35 Zeichen).",
                          "End-to-end ID too long (max 35 chars).")
        }
    }
}
