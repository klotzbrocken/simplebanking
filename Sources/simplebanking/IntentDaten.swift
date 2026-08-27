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

    /// Welchen Bestand ein Intent liest.
    ///
    /// Der Demo-Modus hat eine eigene Datenbank. Ohne diese Unterscheidung antwortete ein
    /// Kurzbefehl im Demo-Modus zwiespältig: Salden aus den Demo-Konten, Umsätze aus dem
    /// echten Bestand — zwei Quellen in einer Auskunft.
    static func datenbank(demo: Bool) -> String { demo ? "demo" : "primary" }

    private static var aktuelleDatenbank: String {
        datenbank(demo: UserDefaults.standard.bool(forKey: "demoMode"))
    }

    struct KontoStand {
        let name: String
        let saldo: Double
        let waehrung: String
    }

    /// Ein Betrag in genau einer Währung. Was hier getrennt bleibt, darf nirgends
    /// zusammenaddiert werden.
    struct Betrag {
        let summe: Double
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
                              // Vorher stand hier fest „EUR". Der Slot kennt seine Währung
                              // aus der Balance-Abfrage; sie wegzuwerfen und alles als Euro
                              // auszuweisen war schlicht falsch.
                              waehrung: slot.currency?.nilIfEmpty ?? "EUR")
        }
    }

    /// Summiert eine Liste von Beträgen **je Währung**, absteigend nach Betrag.
    ///
    /// Der Grund für diese Funktion in einem Satz: 1.000 EUR + 1.000 USD sind nicht
    /// 2.000 EUR. Ohne Umrechnungskurs — und den hat diese Anwendung bewusst nicht — gibt
    /// es keine einzelne Zahl, die stimmt.
    static func jeWaehrung(_ posten: [Betrag]) -> [Betrag] {
        var summen: [String: Double] = [:]
        for p in posten { summen[p.waehrung, default: 0] += p.summe }
        return summen
            .map { Betrag(summe: $0.value, waehrung: $0.key) }
            .sorted { abs($0.summe) > abs($1.summe) }
    }

    /// Summe je Währung über alle Konten. Leer, wenn kein einziges einen Stand hat — dann
    /// soll der Intent das sagen und nicht „0 €" behaupten.
    @MainActor
    static func gesamtsaldo() -> [Betrag] {
        jeWaehrung(kontostaende().map { Betrag(summe: $0.saldo, waehrung: $0.waehrung) })
    }

    /// Ausgaben eines Zeitraums je Währung, positiv als Betrag ausgewiesen.
    ///
    /// Vorgemerkte Buchungen zählen mit: Wer fragt „was habe ich diesen Monat ausgegeben",
    /// meint das Geld, das weg ist — nicht das, was die Bank schon verbucht hat.
    static func ausgaben(tage: Int, slots: [String]?) -> [Betrag] {
        let buchungen = (try? TransactionsDatabase.loadUnifiedTransactions(
            slots: slots, days: tage, bankId: aktuelleDatenbank)) ?? []
        let posten = buchungen
            .filter { $0.parsedAmount < 0 }
            .map { Betrag(summe: abs($0.parsedAmount), waehrung: $0.amount?.currency ?? "EUR") }
        return jeWaehrung(posten)
    }

    /// Die letzten Buchungen, neueste zuerst.
    static func letzteBuchungen(anzahl: Int, tage: Int, slots: [String]?)
        -> [TransactionsResponse.Transaction] {
        let buchungen = (try? TransactionsDatabase.loadUnifiedTransactions(
            slots: slots, days: tage, bankId: aktuelleDatenbank)) ?? []
        return Array(buchungen.prefix(max(1, anzahl)))
    }

    // MARK: - Formatierung

    /// Ein Satz, der in einer Benachrichtigung und in Spotlight gleichermaßen trägt.
    ///
    /// Bei mehreren Währungen werden sie nebeneinandergestellt, nicht addiert. Das ist
    /// länger zu lesen und die einzige Fassung, die stimmt.
    static func satz(fuer betraege: [Betrag], konten: Int) -> String {
        guard !betraege.isEmpty else {
            return L10n.t("Noch kein Kontostand abgerufen.", "No balance fetched yet.")
        }
        let text = betraege.map(formatiert).joined(separator: L10n.t(" und ", " and "))
        if konten <= 1 { return text }
        return L10n.t("\(text) über \(konten) Konten", "\(text) across \(konten) accounts")
    }

    static func formatiert(_ betrag: Betrag) -> String {
        formatiert(betrag.summe, waehrung: betrag.waehrung)
    }

    static func formatiert(_ summe: Double, waehrung code: String) -> String {
        let f = formatierer(code)
        return f.string(from: NSNumber(value: summe)) ?? "\(summe) \(code)"
    }

    /// Ein Formatierer je Währung, einmal gebaut und behalten.
    ///
    /// Vorher gab es genau einen, fest auf Euro gestellt — ein Dollarbetrag erschien damit
    /// als Eurobetrag. Ein `NumberFormatter` ist teuer genug, dass sich das Merken lohnt.
    private static func formatierer(_ code: String) -> NumberFormatter {
        formatiererSperre.lock()
        defer { formatiererSperre.unlock() }
        if let vorhanden = formatiererCache[code] { return vorhanden }
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.currencyCode = code
        f.locale = Locale(identifier: "de_DE")
        formatiererCache[code] = f
        return f
    }

    nonisolated(unsafe) private static var formatiererCache: [String: NumberFormatter] = [:]
    nonisolated(unsafe) private static let formatiererSperre = NSLock()
}
