import Foundation

// MARK: - TransferRecipientCandidate
//
// Vorschlag aus der lokalen Buchungs-Historie für die Geld-senden-UI.
// `mostFrequentAmount` und `lastRemittance` sind Defaults für Betrag und
// Verwendungszweck — der User kann sie überschreiben.

struct TransferRecipientCandidate: Equatable, Sendable {
    let creditorName: String
    let creditorIban: String
    /// Betrag, der am häufigsten an diesen Empfänger ging (Mode statt Mean,
    /// damit Miete trotz einmaliger Sonderzahlung dominiert). Positiv (€).
    let mostFrequentAmount: Decimal?
    /// Letzter Verwendungszweck an diesen Empfänger.
    let lastRemittance: String?
    /// Anzahl ausgehender Transaktionen an dieses (Name, IBAN)-Paar.
    let frequency: Int
    /// ISO-Datum der letzten Buchung (yyyy-MM-dd).
    let lastBookingDate: String
}

// MARK: - TransferRecipientStore

enum TransferRecipientStore {

    /// Lädt die Top-Empfänger für den aktiven Slot, sortiert nach
    /// `frequency × recencyBoost`. Empfänger ohne IBAN werden ausgelassen
    /// (eine Überweisung ohne IBAN ist nicht möglich).
    ///
    /// `today` ist injizierbar für deterministische Tests.
    static func loadCandidates(
        slotId: String,
        limit: Int = 30,
        today: Date = Date(),
        bankId: String = "primary"
    ) throws -> [TransferRecipientCandidate] {
        // Wir laden 2× limit, um nach Recency-Boost neu zu sortieren ohne dass
        // ein vor 12 Monaten häufig genutzter Empfänger einen heute-aktiven
        // verdrängt.
        let raw = try TransactionsDatabase.loadOutgoingRecipientCandidates(
            slotId: slotId,
            limit: limit * 2,
            bankId: bankId
        )
        let sorted = raw.sorted { score($0, today: today) > score($1, today: today) }
        return Array(sorted.prefix(limit))
    }

    /// Substring-Match auf Name oder IBAN. Case-insensitive.
    static func filter(
        _ candidates: [TransferRecipientCandidate],
        query: String
    ) -> [TransferRecipientCandidate] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return candidates }
        return candidates.filter { c in
            c.creditorName.lowercased().contains(q)
                || c.creditorIban.lowercased().contains(q.replacingOccurrences(of: " ", with: ""))
        }
    }

    /// Ranking-Score = `frequency × recencyBoost`.
    /// `recencyBoost = max(0.1, 1 − daysSinceLast / 365)`. 0.1-Floor damit alte
    /// Empfänger nicht komplett verschwinden, sondern nur abgewertet werden.
    static func score(_ c: TransferRecipientCandidate, today: Date) -> Double {
        let days = daysSince(c.lastBookingDate, today: today)
        let recency = max(0.1, 1.0 - Double(days) / 365.0)
        return Double(c.frequency) * recency
    }

    // MARK: - Helpers

    private static let isoFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    /// Tage zwischen `iso` und `today`. Gibt einen großen Wert zurück bei
    /// unparseable Datum (alter Empfänger fällt ans Ende).
    static func daysSince(_ iso: String, today: Date) -> Int {
        guard let date = isoFormatter.date(from: iso) else { return 9999 }
        let cal = Calendar(identifier: .gregorian)
        let comps = cal.dateComponents([.day], from: date, to: today)
        return max(0, comps.day ?? 9999)
    }
}
