import Foundation

// MARK: - Wie lange eine Lastschrift noch zurückgeholt werden kann
//
// Eine SEPA-Basislastschrift lässt sich acht Wochen nach der Belastung ohne Angabe von
// Gründen zurückgeben. Das steht auf keinem Kontoauszug, und wer es nicht weiß, merkt es
// erst, wenn die Frist vorbei ist.
//
// **Die Auskunft ist bewusst weich formuliert** („Ggfs. rückholbar …"). Für die
// Firmenlastschrift zwischen Unternehmen gilt das Recht nämlich *nicht*, und ob eine
// Belastung Basis- oder Firmenlastschrift ist, sagt der Buchungscode nicht immer eindeutig.
// Ein „ggfs." trägt diese Unsicherheit; eine harte Zusage täte es nicht.
//
// Reine Funktionen, ohne Datum aus der Umgebung — `heute` wird übergeben, damit die
// Grenzfälle prüfbar sind.
enum Rueckholfrist {

    /// Acht Wochen.
    static let tage = 56
    /// Ab hier wird es knapp — dann trägt die Zeile mehr Gewicht.
    static let knappAbTagen = 7

    struct Frist: Equatable {
        /// Wie viele Tage noch bleiben. Immer ≥ 1; abgelaufene Fristen gibt es nicht,
        /// dann liefert `fuer` gar keine.
        let verbleibendeTage: Int
        let endet: Date

        var istKnapp: Bool { verbleibendeTage <= Rueckholfrist.knappAbTagen }
    }

    // MARK: - Ist es überhaupt eine Lastschrift?

    /// ISO-20022: `RDDT` ist die Familie der eingezogenen Lastschriften, darunter liegen
    /// `ESDD` (Basis), `BBDD` (Firmen), `PMDD`, `URDD`.
    static let isoLastschriftFamilie = "RDDT"
    static let isoLastschriftUnterfamilien: Set<String> = ["ESDD", "BBDD", "PMDD", "URDD", "UPDD"]

    /// SWIFT-Transaktionsart. **Das ist der Code, den die Banken hier tatsächlich
    /// liefern:** In den Beständen dieser Installation steht durchweg
    /// `SWIFT:DDT;GVC:105` oder `SWIFT:DDT;GVC:106`, nie ein `ISO:`-Pfad. Wer nur nach
    /// ISO sucht, findet keine einzige Lastschrift.
    static let swiftLastschrift = "DDT"

    /// Deutsche Geschäftsvorfallcodes: 005 allgemein, 105 und 106 Lastschrift,
    /// 107 Firmenlastschrift, 171 Lastschrift.
    static let germanLastschriftGVCs: Set<String> = ["5", "05", "005", "105", "106", "107", "171"]

    static func istLastschrift(code: String?) -> Bool {
        guard let code, !code.isEmpty else { return false }
        for teil in code.uppercased().split(separator: ";") {
            if teil.hasPrefix("ISO:") {
                let stufen = teil.split(separator: "/").map(String.init)
                if stufen.contains(isoLastschriftFamilie) { return true }
                if let letzte = stufen.last, isoLastschriftUnterfamilien.contains(letzte) { return true }
            }
            if teil.hasPrefix("SWIFT:"), String(teil.dropFirst(6)) == swiftLastschrift {
                return true
            }
            if teil.hasPrefix("GVC:"), germanLastschriftGVCs.contains(String(teil.dropFirst(4))) {
                return true
            }
        }
        return false
    }

    /// Die Frist einer Buchung — oder `nil`.
    ///
    /// `nil` bei allem, was keine Lastschrift ist, bei Gutschriften (eine Erstattung holt
    /// man nicht zurück), bei fehlendem oder unlesbarem Datum und bei abgelaufener Frist.
    /// **Ohne belastbaren Buchungscode gibt es keine Frist** — geraten wird hier nicht,
    /// denn die Zeile verleitet zu einer Handlung.
    static func fuer(_ transaction: TransactionsResponse.Transaction,
                     heute: Date = Date()) -> Frist? {
        guard istLastschrift(code: transaction.bankTransactionCode) else { return nil }
        guard transaction.parsedAmount < 0 else { return nil }
        guard let text = transaction.bookingDate ?? transaction.valueDate,
              let belastet = parser.date(from: String(text.prefix(10))) else { return nil }

        let kalender = Calendar(identifier: .gregorian)
        let start = kalender.startOfDay(for: belastet)
        guard let ende = kalender.date(byAdding: .day, value: tage, to: start) else { return nil }

        let verbleibend = kalender.dateComponents([.day],
                                                  from: kalender.startOfDay(for: heute),
                                                  to: ende).day ?? 0
        guard verbleibend > 0 else { return nil }
        return Frist(verbleibendeTage: verbleibend, endet: ende)
    }

    nonisolated(unsafe) private static let parser: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    /// „Ggfs. rückholbar noch 56 Tage · bis 28. Sept."
    static func text(_ frist: Frist) -> String {
        let bis = datumsFormat.string(from: frist.endet)
        return L10n.t("Ggfs. rückholbar noch \(frist.verbleibendeTage) Tage · bis \(bis)",
                      "Possibly reclaimable for \(frist.verbleibendeTage) more days · until \(bis)")
    }

    /// Kein zwischengespeicherter Formatierer: Die Sprache lässt sich in den Einstellungen
    /// umstellen, und ein einmal gebauter Formatierer bliebe auf der alten stehen.
    private static var datumsFormat: DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: AppLanguage.resolved() == .de ? "de_DE" : "en_US")
        f.setLocalizedDateFormatFromTemplate("d MMM")
        return f
    }
}
