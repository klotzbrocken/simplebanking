import Foundation

// MARK: - Datenquelle für App Intents, CLI-nah und ohne Bankaufruf
//
// **Die wichtigste Regel steht hier oben: Intents lösen keinen Bankabruf aus.**
//
// Ein Kurzbefehl, der morgens um acht den Saldo holt, läuft unbeaufsichtigt. Würde er
// die Bank anfragen, stünde je nach Institut eine TAN-Abfrage im Raum — in einer
// Automatisierung, die niemand ansieht, und bei Redirect-Banken sogar ein Browserfenster.
// Gelesen wird deshalb ausschließlich der lokale Bestand, genau wie das CLI es tut.
// Wer wirklich abrufen will, nimmt den ausdrücklichen „Aktualisieren"-Intent.
//
// Die Auswertung liegt hier und nicht in den Intent-Strukturen: Intents sind über ihre
// Hülle kaum sinnvoll zu prüfen, reine Funktionen schon. Dasselbe Muster wie im übrigen
// Code.
enum IntentDaten {

    struct KontoStand {
        let name: String
        let saldo: Double
        let waehrung: String
    }

    /// Salden aller Konten aus dem Zwischenspeicher.
    ///
    /// `nil` als Saldo kommt vor — ein frisch angelegtes Konto hat noch keinen. Solche
    /// Konten bleiben draußen, statt als „0,00 €" zu erscheinen: Ein falscher Kontostand
    /// ist schlimmer als ein fehlender, gerade in einer Automatisierung.
    @MainActor
    static func kontostaende() -> [KontoStand] {
        MultibankingStore.shared.slots.compactMap { slot in
            guard let saldo = UserDefaults.standard
                .object(forKey: "simplebanking.cachedBalance.\(slot.id)") as? Double else { return nil }
            return KontoStand(name: slot.displayName.nilIfEmpty ?? slot.id,
                              saldo: saldo,
                              waehrung: "EUR")
        }
    }

    /// Summe über alle Konten. `nil`, wenn kein einziges einen Stand hat — dann soll der
    /// Intent das sagen und nicht „0 €" behaupten.
    @MainActor
    static func gesamtsaldo() -> Double? {
        let staende = kontostaende()
        guard !staende.isEmpty else { return nil }
        return staende.reduce(0) { $0 + $1.saldo }
    }

    /// Ausgaben eines Zeitraums, positiv als Betrag ausgewiesen.
    ///
    /// Vorgemerkte Buchungen zählen mit: Wer fragt „was habe ich diesen Monat ausgegeben",
    /// meint das Geld, das weg ist — nicht das, was die Bank schon verbucht hat.
    static func ausgaben(tage: Int, slots: [String]?) -> Double {
        let buchungen = (try? TransactionsDatabase.loadUnifiedTransactions(
            slots: slots, days: tage)) ?? []
        return buchungen
            .map(\.parsedAmount)
            .filter { $0 < 0 }
            .reduce(0) { $0 + abs($1) }
    }

    /// Die letzten Buchungen, neueste zuerst.
    static func letzteBuchungen(anzahl: Int, tage: Int, slots: [String]?)
        -> [TransactionsResponse.Transaction] {
        let buchungen = (try? TransactionsDatabase.loadUnifiedTransactions(
            slots: slots, days: tage)) ?? []
        return Array(buchungen.prefix(max(1, anzahl)))
    }

    // MARK: - Formatierung

    /// Ein Satz, der in einer Benachrichtigung und in Spotlight gleichermaßen trägt.
    static func satz(fuer saldo: Double?, konten: Int) -> String {
        guard let saldo else {
            return L10n.t("Noch kein Kontostand abgerufen.", "No balance fetched yet.")
        }
        let betrag = waehrung.string(from: NSNumber(value: saldo)) ?? "\(saldo)"
        if konten <= 1 { return betrag }
        return L10n.t("\(betrag) über \(konten) Konten", "\(betrag) across \(konten) accounts")
    }

    nonisolated(unsafe) static let waehrung: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.currencyCode = "EUR"
        f.locale = Locale(identifier: "de_DE")
        return f
    }()
}
