import Foundation
import RoutexClient

/// Ein Dauerauftrag, wie die Bank ihn führt.
///
/// **Warum es diese Datei gibt.** `SubscriptionDetector` erkennt wiederkehrende
/// Zahlungen an der Vergangenheit: gleicher Empfänger, ähnlicher Betrag, passender
/// Abstand, und ab `confidence >= 10` gilt es als bestätigt. Das ist eine Schätzung,
/// und sie braucht mindestens zwei Buchungen.
///
/// Ein Dauerauftrag ist keine Schätzung. Die Bank kennt ihn, auch bevor er das erste
/// Mal gebucht wurde — mit Betrag, Takt und Empfänger. Seit routex-client-swift 0.6.0
/// (28.10.2026) lässt er sich abrufen.
///
/// Diese Datei hält nur das Modell und die Umrechnung aus der SDK-Form. Beides ist
/// rein, damit es ohne Bank prüfbar ist; der Abruf steht in `YaxiService`.
struct Dauerauftrag: Identifiable, Hashable, Codable {

    /// Die Kennung der Bank (`endToEndId`), sonst eine aus Empfänger, Betrag und
    /// Startdatum gebildete. Ein Dauerauftrag ohne Kennung ist der Normalfall, nicht
    /// die Ausnahme — nur der Auftraggeber setzt sie, und die meisten Banken geben
    /// sie nicht heraus.
    let id: String
    let empfaenger: String
    let empfaengerIban: String?
    /// Betrag je Ausführung, immer positiv. Das Vorzeichen trägt die Richtung, und
    /// die ist bei einem Dauerauftrag immer „raus".
    let betrag: Double
    let waehrung: String
    let takt: PaymentFrequency
    /// Die nächste Ausführung, oder `nil`, wenn der Auftrag ausgelaufen ist oder die
    /// Bank keinen Takt mitgeschickt hat.
    let naechsteFaelligkeit: Date?
    let start: Date
    let ende: Date?
    /// Verwendungszweck, Zeilen mit Leerzeichen verbunden.
    let zweck: String

    // MARK: - Aus der SDK-Form

    /// - Parameter heute: Bezugspunkt für `naechsteFaelligkeit`. Als Parameter, damit
    ///   der Test ihn setzen kann.
    static func aus(
        _ o: StandingOrder,
        heute: Date = Date(),
        zeitzone: TimeZone = .current
    ) -> Dauerauftrag {
        let kalender = kalender(zeitzone)
        let start = o.startDate.date(in: zeitzone)
        let ende = o.endDate?.date(in: zeitzone)
        let name = o.creditor?.name?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        let betrag = abs(NSDecimalNumber(decimal: o.amount.amount).doubleValue)

        return Dauerauftrag(
            id: o.endToEndID?.nilIfEmpty
                ?? "\(name ?? "?")|\(betrag)|\(o.startDate.rawValue)",
            empfaenger: name ?? L10n.t("Unbekannter Empfänger", "Unknown recipient"),
            empfaengerIban: o.creditor?.iban?.nilIfEmpty,
            betrag: betrag,
            waehrung: o.amount.currency,
            takt: takt(o.frequency),
            naechsteFaelligkeit: naechsteFaelligkeit(
                start: start, frequenz: o.frequency, tag: o.day,
                ende: ende, heute: heute, kalender: kalender
            ),
            start: start,
            ende: ende,
            zweck: o.remittanceInformation
                .joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    /// Der Takt in der Form, die die Fixkosten-Ansicht kennt.
    ///
    /// `PaymentFrequency` hat vier Werte, die Bank schickt beliebige Abstände. Was
    /// nicht hineinpasst — wöchentlich, halbjährlich — wird `.irregular`. Der genaue
    /// Abstand geht dabei nicht verloren: `naechsteFaelligkeit` rechnet mit der
    /// SDK-Form, nicht mit diesem Wert.
    static func takt(_ f: Frequency?) -> PaymentFrequency {
        switch f {
        case .months(1):  return .monthly
        case .months(3):  return .quarterly
        case .months(12): return .yearly
        case .days(let d):
            // Ein Monat ist keine feste Zahl von Tagen. Die Spannen fangen ab, was
            // Banken als Tagesabstand für „monatlich" schicken.
            switch Int(d) {
            case 28...31:   return .monthly
            case 89...92:   return .quarterly
            case 364...366: return .yearly
            default:        return .irregular
            }
        case .variableMonths(let m):
            switch m.count {
            case 12: return .monthly
            case 4:  return .quarterly
            case 1:  return .yearly
            default: return .irregular
            }
        default:
            return .irregular
        }
    }

    /// Die erste Ausführung ab `heute`.
    ///
    /// Gerechnet wird vom Startdatum vorwärts, nicht von heute rückwärts: Nur so
    /// trifft es den Tag im Monat, den die Bank nennt. Wer stattdessen Monate auf das
    /// heutige Datum addiert, landet bei einem Auftrag zum 31. ab Februar dauerhaft
    /// auf dem 28. — `Calendar` kappt den Tag und gibt ihn nicht wieder her.
    ///
    /// - Returns: `nil`, wenn die Bank keinen Takt mitschickt oder der Auftrag vor
    ///   der nächsten Ausführung endet.
    /// - Note: `ponytail:` Die `executionRule` der Bank (Verschiebung auf den
    ///   nächsten oder vorigen Werktag) bleibt unberücksichtigt — dafür bräuchte es
    ///   einen Feiertagskalender je Bundesland. Die Abweichung sind wenige Tage; wenn
    ///   es auf den Tag ankommt, gehört ein Kalender her.
    static func naechsteFaelligkeit(
        start: Date,
        frequenz: Frequency?,
        tag: UInt8?,
        ende: Date?,
        heute: Date,
        kalender: Calendar
    ) -> Date? {
        guard let frequenz else { return nil }

        // Obergrenze gegen eine Endlosschleife bei krummen Angaben: 600 Schritte sind
        // bei monatlich 50 Jahre und bei täglich knapp zwei.
        let maxSchritte = 600
        let tagesanfang = kalender.startOfDay(for: heute)

        func fertig(_ d: Date) -> Date? {
            if let ende, d > kalender.startOfDay(for: ende) { return nil }
            return d
        }

        switch frequenz {
        case .days(let n) where n > 0:
            for i in 0..<maxSchritte {
                guard let d = kalender.date(byAdding: .day, value: Int(n) * i, to: start) else { return nil }
                if d >= tagesanfang { return fertig(d) }
            }
            return nil

        case .months(let n) where n > 0:
            return monatsschritt(start: start, abstand: Int(n), tag: tag,
                                 erlaubt: nil, abDatum: tagesanfang,
                                 maxSchritte: maxSchritte, kalender: kalender).flatMap(fertig)

        case .variableMonths(let monate) where !monate.isEmpty:
            let erlaubt = Set(monate.map { Int($0.rawValue) })
            return monatsschritt(start: start, abstand: 1, tag: tag,
                                 erlaubt: erlaubt, abDatum: tagesanfang,
                                 maxSchritte: maxSchritte, kalender: kalender).flatMap(fertig)

        default:
            return nil
        }
    }

    /// Geht in Monatsschritten vom Start vorwärts und gibt den ersten Termin ab
    /// `abDatum` zurück.
    ///
    /// Rechnet über den Monatsindex (`jahr * 12 + monat`) statt über wiederholtes
    /// `date(byAdding:)`, damit der Tag im Monat erhalten bleibt — siehe die
    /// Erläuterung bei `naechsteFaelligkeit`.
    private static func monatsschritt(
        start: Date,
        abstand: Int,
        tag: UInt8?,
        erlaubt: Set<Int>?,
        abDatum: Date,
        maxSchritte: Int,
        kalender: Calendar
    ) -> Date? {
        let s = kalender.dateComponents([.year, .month, .day], from: start)
        guard let jahr = s.year, let monat = s.month, let startTag = s.day else { return nil }
        let wunschtag = tag.map { Int($0) } ?? startTag
        let startIndex = jahr * 12 + (monat - 1)

        for i in 0..<maxSchritte {
            let index = startIndex + abstand * i
            let m = index % 12 + 1
            if let erlaubt, !erlaubt.contains(m) { continue }

            var c = DateComponents()
            c.year = index / 12
            c.month = m
            c.day = 1
            guard let monatsanfang = kalender.date(from: c),
                  let spanne = kalender.range(of: .day, in: .month, for: monatsanfang)
            else { continue }
            // Ein Auftrag zum 31. läuft im Februar am 28. — die Bank kappt genauso.
            c.day = min(wunschtag, spanne.count)
            guard let d = kalender.date(from: c) else { continue }

            if d >= abDatum { return d }
        }
        return nil
    }

    private static func kalender(_ zeitzone: TimeZone) -> Calendar {
        var k = Calendar(identifier: .gregorian)
        k.timeZone = zeitzone
        return k
    }
}

// MARK: - Für die Fixkosten-Ansicht

extension Dauerauftrag {

    /// Der Dauerauftrag als Kandidat der Abo-Liste.
    ///
    /// Die Ansicht ist vollständig auf `SubscriptionCandidate` gebaut — Reiter,
    /// Vorschau, Kalender, Statistik. Ein zweiter Datenweg daneben wäre dieselbe
    /// Ansicht ein zweites Mal; also kommt der Dauerauftrag in die vorhandene Form.
    ///
    /// Drei Felder tragen dabei etwas anderes als bei einem erkannten Abo:
    ///
    /// - `confidence: 99` — es ist keine Schätzung. Die Bank führt den Auftrag; die
    ///   Schwelle von 10 für „bestätigt" ist damit nicht knapp überschritten, sondern
    ///   gegenstandslos.
    /// - `lastDate: naechsteFaelligkeit` — hier steht die **nächste**, nicht die letzte
    ///   Ausführung. `AbosForecast.nextPaymentDate` nimmt dieses Datum als Anker und
    ///   gibt den ersten Termin danach zurück; liegt der Anker schon in der Zukunft,
    ///   ist er selbst das Ergebnis. Die Vorschau stimmt also, und `vonDerBank` sorgt
    ///   dafür, dass die Zeile „Nächste" schreibt statt „Zuletzt".
    /// - `matchedTransactions: []` — es gibt keine. Das ist der Gewinn des Abrufs:
    ///   Ein Auftrag, der noch nie gebucht wurde, ist für `SubscriptionDetector`
    ///   unsichtbar und steht hier trotzdem.
    func alsKandidat() -> SubscriptionCandidate {
        SubscriptionCandidate(
            id: "dauerauftrag|\(id)",
            displayName: empfaenger,
            averageAmount: betrag,
            lastAmount: betrag,
            lastDate: naechsteFaelligkeit ?? start,
            cadence: takt,
            occurrences: 1,
            confidence: 99,
            hasCancellationLink: false,
            cancellationEntry: nil,
            category: FixedCostsAnalyzer.categoryForMerchant(empfaenger),
            matchedTransactions: [],
            vonDerBank: true
        )
    }

    /// Ob ein erkanntes Abo derselbe Vorgang ist wie dieser Dauerauftrag.
    ///
    /// Gebraucht fürs Zusammenführen: Die Erkennung sieht einen gebuchten
    /// Dauerauftrag ebenfalls (`BookingType.containsStandingOrder`), und zweimal
    /// „Stadtwerke" in einer Liste wäre ein Fehler, nicht eine Zusatzinformation. Bei
    /// einem Treffer gewinnt die Fassung der Bank.
    ///
    /// Verglichen werden die Namen ohne Satz- und Leerzeichen; einer muss den anderen
    /// enthalten. Die Erkennung kürzt Namen („Stadtwerke München GmbH" → „Stadtwerke
    /// München"), deshalb genügt Gleichheit nicht.
    ///
    /// - Note: `ponytail:` Vier Zeichen als Untergrenze, damit „EON" nicht in
    ///   „Telekom" aufgeht. Wer es genauer braucht, vergleicht die IBAN — die liefert
    ///   aber nicht jede Bank zum Auftrag.
    func passtZu(displayName: String) -> Bool {
        let a = Self.vergleichsform(empfaenger)
        let b = Self.vergleichsform(displayName)
        guard a.count >= 4, b.count >= 4 else { return false }
        return a.contains(b) || b.contains(a)
    }

    private static func vergleichsform(_ s: String) -> String {
        s.lowercased().filter { $0.isLetter || $0.isNumber }
    }
}

// MARK: - Speicher

/// Hält die abgerufenen Daueraufträge je Bank-Zugang.
///
/// **Warum gespeichert wird.** Der Abruf kostet eine Freigabe (siehe
/// `YaxiService.fetchStandingOrders`). Eine Liste, die beim Schließen des Fensters
/// verfällt, wäre damit beim zweiten Blick teurer als beim ersten.
///
/// Geschrieben wird aus `BalanceBar` — nur dort liegt das Hauptpasswort, ohne das es
/// keine Zugangsdaten gibt. Die Ansicht fordert den Abruf über
/// `Notification.Name.dauerauftraegeAnfordern` an und liest hier mit.
@MainActor
final class DauerauftragStore: ObservableObject {
    static let shared = DauerauftragStore()

    @Published private(set) var auftraege: [Dauerauftrag] = []
    @Published private(set) var laeuft = false
    /// Satz für den Nutzer, wenn der Abruf nichts geliefert hat. `nil` = alles gut.
    @Published var meldung: String?

    private init() { laden() }

    private func schluessel(_ slotId: String) -> String { "dauerauftraege.\(slotId)" }

    /// Lädt die Liste des aktiven Zugangs. Beim Zugangswechsel erneut rufen.
    func laden() {
        let slot = YaxiService.activeSlotId
        guard let roh = UserDefaults.standard.data(forKey: schluessel(slot)),
              let liste = try? JSONDecoder().decode([Dauerauftrag].self, from: roh)
        else {
            auftraege = []
            return
        }
        auftraege = liste
    }

    func uebernehmen(_ liste: [Dauerauftrag], slotId: String) {
        if let roh = try? JSONEncoder().encode(liste) {
            UserDefaults.standard.set(roh, forKey: schluessel(slotId))
        }
        guard slotId == YaxiService.activeSlotId else { return }
        auftraege = liste
    }

    func abrufStartet() {
        laeuft = true
        meldung = nil
    }

    func abrufBeendet(meldung: String? = nil) {
        laeuft = false
        self.meldung = meldung
    }

    /// Bittet `BalanceBar` um einen Abruf bei der Bank.
    func anfordern() {
        guard !laeuft else { return }
        NotificationCenter.default.post(name: .dauerauftraegeAnfordern, object: nil)
    }
}

extension Notification.Name {
    static let dauerauftraegeAnfordern = Notification.Name("simplebanking.dauerauftraegeAnfordern")
}

// MARK: - Demo-Modus

extension Dauerauftrag {

    /// Zwei Beispielaufträge für den Demo-Modus.
    ///
    /// Der eine ist monatlich und wurde längst gebucht, der andere jährlich und steht
    /// erst bevor — der zweite ist der Fall, den die Erkennung aus Buchungen nicht
    /// finden könnte.
    static func beispiele(heute: Date = Date(), zeitzone: TimeZone = .current) -> [Dauerauftrag] {
        var k = Calendar(identifier: .gregorian)
        k.timeZone = zeitzone
        let start = k.date(byAdding: .month, value: -14, to: heute) ?? heute
        let spaeter = k.date(byAdding: .month, value: -2, to: heute) ?? heute

        func bauen(_ name: String, _ iban: String, _ betrag: Double,
                   _ takt: Frequency, _ tag: UInt8, _ ab: Date, _ zweck: String) -> Dauerauftrag {
            Dauerauftrag(
                id: "demo|\(name)",
                empfaenger: name,
                empfaengerIban: iban,
                betrag: betrag,
                waehrung: "EUR",
                takt: Dauerauftrag.takt(takt),
                naechsteFaelligkeit: naechsteFaelligkeit(
                    start: ab, frequenz: takt, tag: tag, ende: nil, heute: heute, kalender: k
                ),
                start: ab,
                ende: nil,
                zweck: zweck
            )
        }

        return [
            bauen("Hausverwaltung Meier", "DE02100500000054540402", 980,
                  .months(1), 1, start, "Miete Wohnung 12"),
            bauen("Sportverein Eichenau", "DE02300209000106531065", 144,
                  .months(12), 15, spaeter, "Jahresbeitrag"),
        ]
    }
}
