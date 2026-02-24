import CryptoKit
import Foundation
import GRDB

struct TransactionRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "transactions"

    let txID: String
    let endToEndID: String?
    let datum: String
    let buchungsdatum: String
    let betrag: Double
    let waehrung: String
    let empfaenger: String?
    let absender: String?
    let iban: String?
    let verwendungszweck: String?
    let kategorie: String?
    let additionalInformation: String?
    let effectiveMerchant: String
    let normalizedMerchant: String
    let merchantSource: String
    let merchantConfidence: Double
    let searchText: String
    let rawJSON: String
    let updatedAt: String

    enum CodingKeys: String, CodingKey {
        case txID = "tx_id"
        case endToEndID = "end_to_end_id"
        case datum
        case buchungsdatum
        case betrag
        case waehrung
        case empfaenger
        case absender
        case iban
        case verwendungszweck
        case kategorie
        case additionalInformation = "additional_information"
        case effectiveMerchant = "effective_merchant"
        case normalizedMerchant = "normalized_merchant"
        case merchantSource = "merchant_source"
        case merchantConfidence = "merchant_confidence"
        case searchText = "search_text"
        case rawJSON = "raw_json"
        case updatedAt = "updated_at"
    }

    init(transaction: TransactionsResponse.Transaction, updatedAt: String) throws {
        let encoder = JSONEncoder()
        let rawData = try encoder.encode(transaction)
        let rawJSON = String(data: rawData, encoding: .utf8) ?? "{}"

        let valueDate = Self.normalizedDate(transaction.valueDate) ?? Self.normalizedDate(transaction.bookingDate) ?? "1970-01-01"
        let bookingDate = Self.normalizedDate(transaction.bookingDate) ?? valueDate

        self.txID = Self.fingerprint(for: transaction)
        self.endToEndID = Self.clean(transaction.endToEndId)
        self.datum = valueDate
        self.buchungsdatum = bookingDate
        self.betrag = transaction.parsedAmount
        self.waehrung = Self.clean(transaction.amount?.currency) ?? "EUR"
        self.empfaenger = Self.clean(transaction.creditor?.name)
        self.absender = Self.clean(transaction.debtor?.name)
        self.iban = Self.clean(transaction.creditor?.iban) ?? Self.clean(transaction.debtor?.iban)
        self.verwendungszweck = Self.clean((transaction.remittanceInformation ?? []).joined(separator: " "))
        self.additionalInformation = Self.clean(transaction.additionalInformation)
        let resolution = MerchantResolver.resolve(transaction: transaction)
        let category = TransactionCategorizer.category(
            txID: self.txID,
            amount: transaction.parsedAmount,
            empfaenger: self.empfaenger,
            absender: self.absender,
            verwendungszweck: self.verwendungszweck,
            additionalInformation: self.additionalInformation,
            effectiveMerchant: resolution.effectiveMerchant
        )
        self.kategorie = category.displayName
        self.effectiveMerchant = resolution.effectiveMerchant
        self.normalizedMerchant = resolution.normalizedMerchant
        self.merchantSource = resolution.source
        self.merchantConfidence = resolution.confidence
        self.searchText = MerchantResolver.buildSearchText(
            effectiveMerchant: resolution.effectiveMerchant,
            normalizedMerchant: resolution.normalizedMerchant,
            empfaenger: self.empfaenger,
            absender: self.absender,
            verwendungszweck: self.verwendungszweck,
            additionalInformation: self.additionalInformation,
            iban: self.iban
        )
        self.rawJSON = rawJSON
        self.updatedAt = updatedAt
    }

    func toTransaction() -> TransactionsResponse.Transaction? {
        guard let data = rawJSON.data(using: .utf8) else { return nil }
        guard var transaction = try? JSONDecoder().decode(TransactionsResponse.Transaction.self, from: data) else {
            return nil
        }
        if let kategorie, !kategorie.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            transaction.category = kategorie
        }
        return transaction
    }

    static func fingerprint(for transaction: TransactionsResponse.Transaction) -> String {
        let parts: [String] = [
            clean(transaction.endToEndId) ?? "",
            clean(transaction.bookingDate) ?? "",
            clean(transaction.valueDate) ?? "",
            clean(transaction.amount?.amount) ?? "",
            clean(transaction.amount?.currency) ?? "",
            clean(transaction.creditor?.name) ?? "",
            clean(transaction.debtor?.name) ?? "",
            clean((transaction.remittanceInformation ?? []).joined(separator: " ")) ?? "",
            clean(transaction.purposeCode) ?? "",
            clean(transaction.additionalInformation) ?? "",
        ]
        let base = parts.joined(separator: "|").lowercased()
        let digest = SHA256.hash(data: Data(base.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func clean(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func normalizedDate(_ value: String?) -> String? {
        guard let value = clean(value) else { return nil }
        // Input expected as ISO yyyy-MM-dd from backend; keep normalized format.
        return value
    }
}
