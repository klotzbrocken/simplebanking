import Foundation

/// Veränderung des Kontostands seit einem Stichtag — als reine Rechnung.
///
/// **Warum zurückgerechnet und nicht gespeichert:** Die App führt keine
/// Kontostand-Historie. `simplebanking.cachedBalance.<slotId>` ist ein einzelner Wert
/// ohne Zeitstempel, bei jedem Refresh überschrieben. Der Stand am Stichtag ergibt sich
/// deshalb aus den vorhandenen Buchungen:
///
///     Stand am Stichtag = aktueller Stand − Σ(gebuchte Umsätze seit dem Stichtag)
///
/// **Nur gebuchte Umsätze.** Vorgemerkte sind im Bank-Saldo noch gar nicht enthalten
/// (siehe `AvailableBalance`) — sie mitzuzählen verschöbe den Vergangenheitswert
/// systematisch. Der Aufrufer filtert, diese Datei rechnet nur.
enum BalanceChange {

    /// Der Stichtag: **derselbe Kalendertag im Vormonat**.
    ///
    /// Kalendarisch und nicht „vor 30 Tagen" — der entscheidende Unterschied. Ein Konto
    /// läuft im Monatsrhythmus: Gehalt, Miete, Versicherungen, Abos je einmal pro
    /// Kalendermonat. Ein starres 30-Tage-Fenster driftet dagegen; in einem 31-Tage-Monat
    /// rutscht ein Fixposten hinein oder heraus und der Wert springt um dessen vollen
    /// Betrag, ohne dass sich real etwas geändert hätte. Beim Vergleich mit demselben
    /// Kalendertag liegt jeder monatliche Posten genau einmal im Fenster; Gehalt und
    /// Fixkosten heben sich auf, übrig bleibt die echte Drift.
    struct Bezug: Equatable {
        let stichtag: Date

        /// Derselbe Tag im Vormonat. Der 31. wird auf den letzten Tag des Vormonats
        /// gekürzt — `Calendar` macht das von sich aus (31.03. → 28./29.02.).
        static func vormonat(von heute: Date = Date(),
                             kalender: Calendar = .current) -> Bezug {
            let tag = kalender.startOfDay(for: heute)
            return Bezug(stichtag: kalender.date(byAdding: .month, value: -1, to: tag) ?? tag)
        }
    }

    enum Anzeige: Equatable {
        /// Der Normalfall.
        case prozent(Double, Bezug)
        /// Wenn Prozent nicht trägt — siehe `prozentTraegt`.
        case euro(Double, Bezug)
        /// Kein Saldo, oder die lokale Historie reicht nicht bis zum Stichtag.
        /// Bewusst kein geschätzter Wert: lieber nichts als eine Zahl, die zu klein ist,
        /// weil ein Teil der Buchungen fehlt.
        case nichts

        /// Steigt der Stand? Bei `.nichts` bedeutungslos.
        var steigt: Bool {
            switch self {
            case .prozent(let w, _), .euro(let w, _): return w >= 0
            case .nichts: return true
            }
        }

        var bezug: Bezug? {
            switch self {
            case .prozent(_, let b), .euro(_, let b): return b
            case .nichts: return nil
            }
        }
    }

    /// Unterhalb dieser Basis wird nicht mehr in Prozent gerechnet.
    ///
    /// 100 € ist gegriffen, aber nicht willkürlich: Darunter erzeugt jede normale Buchung
    /// dreistellige Prozentwerte (10 € → 110 € sind +1000 %), die zwar richtig gerechnet,
    /// als Aussage neben einem Kontostand aber unbrauchbar sind.
    static let minimaleProzentBasis: Double = 100

    /// Trägt eine Prozentangabe auf dieser Basis?
    ///
    /// Zwei Fälle sagen nein:
    /// - **Basis nahe null** — der Prozentwert explodiert.
    /// - **Basis negativ** — dann dreht das Vorzeichen die Aussage um. Von −100 € auf
    ///   −50 € ist eine *Verbesserung*, die Formel liefert aber −50 %, was wie eine
    ///   Verschlechterung aussieht. Ein Konto im Dispo bekommt deshalb Euro.
    static func prozentTraegt(basis: Double) -> Bool {
        basis >= minimaleProzentBasis
    }

    /// Die Veränderung, fertig für die Anzeige.
    ///
    /// - Parameters:
    ///   - aktuellerStand: der angezeigte (dispo-bereinigte) Saldo. `nil` → `.nichts`.
    ///   - gebuchteSeitStichtag: Beträge der **gebuchten** Umsätze ab Stichtag,
    ///     vorzeichenbehaftet wie in der Buchung (Ausgaben negativ).
    ///   - bezug: Stichtag samt seiner Bedeutung.
    ///   - historieReichtBis: ältestes Datum, für das lokal Buchungen vorliegen. Liegt
    ///     der Stichtag davor, fehlen Umsätze und das Ergebnis wäre stillschweigend
    ///     falsch — dann lieber `.nichts`.
    static func berechne(aktuellerStand: Double?,
                         gebuchteSeitStichtag: [Double],
                         bezug: Bezug,
                         historieReichtBis: Date) -> Anzeige {
        guard let jetzt = aktuellerStand else { return .nichts }
        guard historieReichtBis <= bezug.stichtag else { return .nichts }

        let bewegung = gebuchteSeitStichtag.reduce(0, +)
        let damals = jetzt - bewegung

        guard prozentTraegt(basis: damals) else { return .euro(bewegung, bezug) }
        return .prozent(bewegung / damals * 100, bezug)
    }

    // MARK: - Aus der Buchungshistorie

    /// Bereitet eine Buchungsliste auf und rechnet. Liefert zusätzlich den Eurobetrag
    /// der Bewegung, weil die Anzeige ein Prozentwert sein kann und der Tooltip den
    /// Betrag nennen soll.
    ///
    /// **Vorgemerkte werden ausgeschlossen, nicht gebuchte eingeschlossen.** Die übrige
    /// App prüft durchgehend auf `status == "pending"` (`AvailableBalance`,
    /// `TransactionsViewModel`); ein Filter auf `== "booked"` liefe daneben, sobald ein
    /// anderer Wert auftaucht. Genau das ist beim Sichttest passiert — die Demo-Daten
    /// schreiben „Booked" mit großem B, und das Abzeichen blieb kommentarlos leer.
    /// Deshalb zusätzlich case-insensitiv.
    static func ausHistorie(_ history: [TransactionsResponse.Transaction],
                            stand: Double?,
                            bezug: Bezug) -> (anzeige: Anzeige, euro: Double) {
        let gebucht = history.filter { ($0.status ?? "").lowercased() != "pending" }
        guard let aeltestes = gebucht.compactMap(buchungsdatum).min() else { return (.nichts, 0) }

        let seitStichtag = gebucht
            .filter { (buchungsdatum($0) ?? .distantPast) >= bezug.stichtag }
            .map { $0.parsedAmount }

        return (berechne(aktuellerStand: stand,
                         gebuchteSeitStichtag: seitStichtag,
                         bezug: bezug,
                         historieReichtBis: aeltestes),
                seitStichtag.reduce(0, +))
    }

    private static let datumsFormat: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    private static func buchungsdatum(_ tx: TransactionsResponse.Transaction) -> Date? {
        (tx.bookingDate ?? tx.valueDate).flatMap { datumsFormat.date(from: String($0.prefix(10))) }
    }

    // MARK: - Welche Historie zählt

    /// Die Buchungen, gegen die gerechnet wird: im Aggregat alle Konten, sonst das
    /// aktive.
    ///
    /// Steht hier und nicht als Zweig in `recomputeLeftToPay`, weil genau diese Auswahl
    /// zweimal danebenging: erst fehlte sie im Demo-Modus ganz, dann nur im
    /// Multi-Banking-Demo — beide Male blieb das Abzeichen kommentarlos leer, und beide
    /// Male fiel es erst jemandem beim Hinsehen auf.
    static func massgeblicheHistorie(
        proKonto: [[TransactionsResponse.Transaction]],
        aktivIndex: Int,
        aggregiert: Bool
    ) -> [TransactionsResponse.Transaction] {
        if aggregiert { return proKonto.flatMap { $0 } }
        guard proKonto.indices.contains(aktivIndex) else { return [] }
        return proKonto[aktivIndex]
    }

    // MARK: - Formatierung

    private static let prozentFormat: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.locale = Locale(identifier: "de_DE")
        f.minimumFractionDigits = 1
        f.maximumFractionDigits = 1
        return f
    }()

    private static let euroFormat: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.locale = Locale(identifier: "de_DE")
        f.currencyCode = "EUR"
        f.maximumFractionDigits = 0
        return f
    }()

    /// „▲ 4,2 %" bzw. „▼ 340 €". Der Pfeil trägt die Richtung, die Zahl bleibt ohne
    /// Vorzeichen — sonst stünde die Information zweimal da.
    static func text(_ anzeige: Anzeige) -> String? {
        let pfeil = anzeige.steigt ? "▲" : "▼"
        switch anzeige {
        case .nichts:
            return nil
        case .prozent(let wert, _):
            let zahl = prozentFormat.string(from: NSNumber(value: abs(wert))) ?? "0,0"
            return "\(pfeil) \(zahl) %"
        case .euro(let wert, _):
            let zahl = euroFormat.string(from: NSNumber(value: abs(wert))) ?? "0 €"
            return "\(pfeil) \(zahl)"
        }
    }

    /// Nennt den Eurobetrag — die Anzeige selbst kann ein Prozentwert sein.
    static func erklaerung(_ anzeige: Anzeige, bewegungEuro: Double) -> String? {
        guard anzeige.bezug != nil else { return nil }
        let betrag = euroFormat.string(from: NSNumber(value: abs(bewegungEuro))) ?? "0 €"
        let richtung = bewegungEuro >= 0
            ? L10n.t("mehr", "more")
            : L10n.t("weniger", "less")
        return L10n.t("\(betrag) \(richtung) als vor einem Monat",
                      "\(betrag) \(richtung) than a month ago")
    }
}
