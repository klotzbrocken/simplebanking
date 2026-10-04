import Foundation

/// Fixkosten und Abos für den MCP-Server, berechnet von der App.
///
/// **Warum eine Datei und nicht noch eine Rechnung.** Der MCP-Server ist ein eigenes
/// Programm; er liest die Datenbank direkt und kennt weder `FixedCostsAnalyzer` noch
/// `SubscriptionDetector`. Beide dorthin zu kopieren hieße, zwei Auswertungen zu pflegen,
/// die auseinanderlaufen — genau der Fehler, der am 01.10.2026 eine Woche gekostet hat:
/// Ein Bericht, der seine eigene Rechnung aufstellte, erklärte eine Zahl, die nirgends
/// stand. Deshalb rechnet weiterhin nur die App, und zwar dort, wo sie es ohnehin tut
/// (`BalanceBar.recomputeLeftToPay`). Hier wird das Ergebnis nur abgelegt.
///
/// Der Preis ist Aktualität: Was hier steht, ist so frisch wie der letzte Abruf. Deshalb
/// trägt jeder Eintrag seinen Zeitstempel, und die Werkzeuge geben ihn mit heraus.
enum MCPSchnappschuss {

    static var dateiURL: URL {
        let basis = FileManager.default.urls(for: .applicationSupportDirectory,
                                             in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return basis.appendingPathComponent("simplebanking", isDirectory: true)
            .appendingPathComponent("auswertung.json")
    }

    // Formatter je Aufruf statt als globale Konstante: Dieser Pfad läuft ein paar Mal
    // pro Minute, nicht pro Zeile — ein Lock oder `nonisolated(unsafe)` wäre hier
    // Aufwand für nichts.
    private static func iso() -> ISO8601DateFormatter {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }

    private static func tagesformat() -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd"
        return f
    }

    /// Als Dezimalzahl, nicht als `Double`. `(v * 100).rounded() / 100` liefert für
    /// 950,42 den Wert 950.41999999999996, und genau so landet er im JSON — ein Modell,
    /// das das vorliest, klingt kaputt.
    private static func gerundet(_ v: Double) -> NSDecimalNumber {
        NSDecimalNumber(string: String(format: "%.2f", v))
    }

    /// Schreibt den Stand **eines** Kontos und lässt die übrigen stehen.
    ///
    /// `recomputeLeftToPay` läuft je nach Ansicht nur über das aktive Konto. Würde hier
    /// die ganze Datei ersetzt, verschwänden die anderen Konten bei jedem Abruf und
    /// kämen erst beim nächsten Kontowechsel zurück.
    static func schreibe(slotId: String,
                         bankName: String?,
                         gehaltstag: Int,
                         zyklusStart: Date,
                         zyklusEnde: Date,
                         zahlungen: [RecurringPayment],
                         offen: [RecurringPayment],
                         historie: [TransactionsResponse.Transaction]) {
        let tag = tagesformat()
        let offeneSchluessel = Set(offen.map(\.groupKey))
        let zuordnungen = RecurringAssignments.current()

        let posten: [[String: Any]] = zahlungen.map { z in
            var eintrag: [String: Any] = [
                "merchant": z.merchant,
                "group_key": z.groupKey,
                "amount_eur": gerundet(z.averageAmount),
                "frequency": z.frequency.rawValue,
                "occurrences": z.occurrences,
                "months": z.months,
                "confidence": gerundet(z.confidence),
                "category": z.category.rawValue,
                "last_date": z.lastDate,
                "open_this_cycle": offeneSchluessel.contains(z.groupKey)
            ]
            if let last = tag.date(from: z.lastDate) {
                eintrag["next_due"] = tag.string(
                    from: LeftToPayCalculator.nextExpected(last: last, frequency: z.frequency))
            }
            return eintrag
        }

        // Dieselben Kandidaten wie „Abos & Verträge", inklusive der Korrekturen des
        // Nutzers: ausgeschlossene fliegen raus, ein verschobener Posten trägt seinen
        // Reiter. Sonst zeigte ein Agent eine Liste, die der Nutzer längst korrigiert hat.
        let kandidaten = SubscriptionDetector.detect(in: historie, bankname: bankName)
        let abos: [[String: Any]] = kandidaten.compactMap { k in
            guard !zuordnungen.isExcluded(k.id) else { return nil }
            let reiter = zuordnungen.assignment(for: k.id).tab.flatMap(SubscriptionTab.init(rawValue:))
                ?? k.defaultTab
            var eintrag: [String: Any] = [
                "name": k.displayName,
                "group_key": k.id,
                "amount_eur": gerundet(k.averageAmount),
                "last_amount_eur": gerundet(k.lastAmount),
                "frequency": k.cadence.rawValue,
                "occurrences": k.occurrences,
                "category": k.category.rawValue,
                "tab": reiter.rawValue,
                "last_date": tag.string(from: k.lastDate),
                "next_due": tag.string(
                    from: LeftToPayCalculator.nextExpected(last: k.lastDate, frequency: k.cadence))
            ]
            if let e = k.cancellationEntry {
                eintrag["cancellation_url"] = e.url.absoluteString
                if let n = e.note { eintrag["cancellation_note"] = n }
            }
            return eintrag
        }

        let konto: [String: Any] = [
            "bank_name": bankName ?? "",
            "updated_at": iso().string(from: Date()),
            "salary_day": gehaltstag,
            "cycle_start": tag.string(from: zyklusStart),
            "cycle_end": tag.string(from: zyklusEnde),
            "monthly_total_eur": gerundet(zahlungen.reduce(0) { $0 + $1.averageAmount }),
            "open_total_eur": gerundet(offen.reduce(0) { $0 + $1.averageAmount }),
            "fixed_costs": posten,
            "subscriptions": abos
        ]

        var wurzel: [String: Any] = ["schema": 1, "slots": [String: Any]()]
        if let daten = try? Data(contentsOf: dateiURL),
           let vorhanden = try? JSONSerialization.jsonObject(with: daten) as? [String: Any] {
            wurzel = vorhanden
        }
        var slots = wurzel["slots"] as? [String: Any] ?? [:]
        slots[slotId] = konto
        wurzel["slots"] = slots
        wurzel["schema"] = 1

        do {
            try FileManager.default.createDirectory(
                at: dateiURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let daten = try JSONSerialization.data(withJSONObject: wurzel,
                                                   options: [.prettyPrinted, .sortedKeys])
            try daten.write(to: dateiURL, options: .atomic)
        } catch {
            AppLogger.log("Auswertungs-Schnappschuss nicht geschrieben: \(error.localizedDescription)",
                          category: "MCP", level: "WARN")
        }
    }

    /// Räumt Konten weg, die es nicht mehr gibt. Ohne das bliebe ein gelöschtes Konto
    /// für einen Agenten sichtbar — mit Händlernamen und Beträgen.
    static func entferne(slotId: String) {
        guard let daten = try? Data(contentsOf: dateiURL),
              var wurzel = try? JSONSerialization.jsonObject(with: daten) as? [String: Any],
              var slots = wurzel["slots"] as? [String: Any],
              slots.removeValue(forKey: slotId) != nil else { return }
        wurzel["slots"] = slots
        if let neu = try? JSONSerialization.data(withJSONObject: wurzel,
                                                 options: [.prettyPrinted, .sortedKeys]) {
            try? neu.write(to: dateiURL, options: .atomic)
        }
    }
}
