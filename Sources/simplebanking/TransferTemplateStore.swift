import Foundation

// MARK: - TransferTemplate
//
// Eine vom User gespeicherte Geld-senden-Vorlage. Slot-scoped: Vorlagen aus
// Slot A erscheinen nicht in Slot B (Konto-Trennung respektieren).
//
// `amount` als `Decimal` modelliert; auf der Persistenz-Ebene als String
// (`Decimal.description`) abgelegt, damit kein Locale- oder Floating-Point-
// Drift beim JSON-Roundtrip auftritt.

struct TransferTemplate: Equatable, Identifiable, Sendable {
    let id: String
    let slotId: String
    let name: String
    let recipientName: String
    let recipientIban: String
    let amount: Decimal
    let purpose: String?
    let createdAt: Date

    init(
        id: String = UUID().uuidString,
        slotId: String,
        name: String,
        recipientName: String,
        recipientIban: String,
        amount: Decimal,
        purpose: String?,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.slotId = slotId
        self.name = name
        self.recipientName = recipientName
        self.recipientIban = TransferRequest.normalizeIban(recipientIban)
        self.amount = amount
        self.purpose = purpose?.nilIfEmpty
        self.createdAt = createdAt
    }
}

// MARK: - On-Disk Codable

private struct TransferTemplateDTO: Codable {
    let id: String
    let slotId: String
    let name: String
    let recipientName: String
    let recipientIban: String
    let amount: String           // Decimal.description (locale-stable)
    let purpose: String?
    let createdAt: Double        // timeIntervalSince1970

    init(_ t: TransferTemplate) {
        self.id = t.id
        self.slotId = t.slotId
        self.name = t.name
        self.recipientName = t.recipientName
        self.recipientIban = t.recipientIban
        self.amount = "\(t.amount)"
        self.purpose = t.purpose
        self.createdAt = t.createdAt.timeIntervalSince1970
    }

    func toModel() -> TransferTemplate? {
        guard let dec = Decimal(string: amount, locale: Locale(identifier: "en_US_POSIX")) else {
            return nil
        }
        return TransferTemplate(
            id: id,
            slotId: slotId,
            name: name,
            recipientName: recipientName,
            recipientIban: recipientIban,
            amount: dec,
            purpose: purpose,
            createdAt: Date(timeIntervalSince1970: createdAt)
        )
    }
}

// MARK: - TransferTemplateStore

enum TransferTemplateStore {
    private static let storageKey = "simplebanking.transfer.templates"

    /// Lädt die Vorlagen für einen Slot — alphabetisch sortiert nach Name.
    static func load(slotId: String) -> [TransferTemplate] {
        let all = loadAll()
        return all
            .filter { $0.slotId == slotId }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Persistiert eine neue Vorlage. Bei Kollision auf id wird ersetzt
    /// (idempotent — erlaubt „edit by recreate").
    static func save(_ template: TransferTemplate) {
        var all = loadAll()
        if let idx = all.firstIndex(where: { $0.id == template.id }) {
            all[idx] = template
        } else {
            all.append(template)
        }
        write(all)
    }

    /// Entfernt die Vorlage mit dieser id. Andere Slots bleiben unberührt.
    static func delete(id: String) {
        let all = loadAll().filter { $0.id != id }
        write(all)
    }

    // MARK: - Private

    private static func loadAll() -> [TransferTemplate] {
        guard let data = UserDefaults.standard.data(forKey: storageKey) else { return [] }
        guard let dtos = try? JSONDecoder().decode([TransferTemplateDTO].self, from: data) else {
            return []
        }
        return dtos.compactMap { $0.toModel() }
    }

    private static func write(_ templates: [TransferTemplate]) {
        let dtos = templates.map(TransferTemplateDTO.init)
        guard let data = try? JSONEncoder().encode(dtos) else { return }
        UserDefaults.standard.set(data, forKey: storageKey)
    }
}
