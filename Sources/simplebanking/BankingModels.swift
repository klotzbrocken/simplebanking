import Foundation

// MARK: - API models

struct DiscoveredBank: Codable, Hashable, Sendable {
    let id: String?
    let displayName: String
    let logoId: String?
    let credentials: DiscoveredBankCredentials?
    let userIdLabel: String?
    let advice: String?
}

struct DiscoveredBankCredentials: Codable, Hashable, Sendable {
    let full: Bool
    let userId: Bool
    let none: Bool
}

struct BalancesResponse: Codable, Sendable {
    struct Balance: Codable, Sendable {
        let amount: String
        let currency: String
        let balanceType: String?
    }

    let ok: Bool
    let booked: Balance?
    let expected: Balance?
    let session: String?
    let connectionData: String?
    let error: String?
    let userMessage: String?
    let scaRequired: Bool?
}

struct TransactionsResponse: Codable, Sendable {
    struct Amount: Codable, Hashable, Sendable {
        let currency: String
        let amount: String
    }

    struct Party: Codable, Hashable, Sendable {
        let name: String?
        let iban: String?
        let bic: String?
    }

    struct Transaction: Codable, Hashable, Sendable {
        let bookingDate: String?
        let valueDate: String?
        let status: String?
        let endToEndId: String?
        let amount: Amount?
        let creditor: Party?
        let debtor: Party?
        let remittanceInformation: [String]?
        let additionalInformation: String?  // Buchungstext (z.B. "DAUERAUFTRAG")
        let purposeCode: String?            // Kategorie (z.B. "RINP")
        var category: String? = nil         // Local category label (e.g. "Essen & Alltag")
    }

    let ok: Bool?
    let transactions: [Transaction]?
    let session: String?
    let connectionData: String?
    let error: String?
    let userMessage: String?
    let scaRequired: Bool?
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
