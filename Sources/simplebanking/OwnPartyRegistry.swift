import Foundation

/// Merkt sich, wer bei den eigenen Konten „ich" ist — IBAN und Kontoinhaber.
///
/// **Netz, nicht Mechanismus.** Die Gegenseite einer Buchung wird über das *Vorzeichen*
/// bestimmt (`MerchantResolver.TransactionDirection`); das allein löst den easybank-Fall.
/// Dieses Register fängt nur den Fall ab, dass eine Bank die eigene Seite dort einträgt,
/// wo die Gegenseite stehen müsste. Es kann deshalb ausschließlich **unterdrücken** —
/// einen Namen erfinden kann es nicht.
///
/// Solange nichts registriert ist, antwortet es immer `false`; das Verhalten ist dann
/// exakt wie ohne diese Datei.
///
/// `nonisolated` und über ein Lock geschützt, weil der Resolver auch außerhalb des
/// MainActors läuft: aus `Task.detached` in `BalanceBar.recomputeLeftToPay()` und aus der
/// Datenbank-Migration `backfillMerchantColumns`.
enum OwnPartyRegistry {

    private struct Eintrag {
        let iban: String?
        let inhaber: String?
    }

    private static let sperre = NSLock()
    nonisolated(unsafe) private static var eintraege: [String: Eintrag] = [:]

    /// Trägt ein Konto ein. Mehrfachaufruf überschreibt — die Slot-Liste ist die Wahrheit.
    static func registrieren(slotId: String, iban: String?, inhaber: String?) {
        sperre.lock(); defer { sperre.unlock() }
        eintraege[slotId] = Eintrag(iban: normalisierteIban(iban), inhaber: normalisierterName(inhaber))
    }

    /// Ersetzt den gesamten Bestand — für den Aufruf beim Laden der Slots.
    static func ersetzen(_ konten: [(slotId: String, iban: String?, inhaber: String?)]) {
        sperre.lock(); defer { sperre.unlock() }
        eintraege = Dictionary(uniqueKeysWithValues: konten.map {
            ($0.slotId, Eintrag(iban: normalisierteIban($0.iban), inhaber: normalisierterName($0.inhaber)))
        })
    }

    static func leeren() {
        sperre.lock(); defer { sperre.unlock() }
        eintraege = [:]
    }

    /// Ist diese Partei in Wahrheit der Kontoinhaber selbst?
    ///
    /// Geprüft wird gegen **alle** eingetragenen Konten, nicht nur gegen `slotId`: Eine
    /// Umbuchung zwischen zwei eigenen Konten ist aus Sicht beider die eigene Seite, und
    /// der Slot einer Buchung ist beim Backfill nicht immer gesetzt.
    static func istEigeneSeite(name: String?, iban: String?, slotId: String) -> Bool {
        sperre.lock(); defer { sperre.unlock() }
        guard !eintraege.isEmpty else { return false }

        // Die IBAN ist das harte Kriterium — sie ist eindeutig, ein Name ist es nie.
        if let iban = normalisierteIban(iban), !iban.isEmpty,
           eintraege.values.contains(where: { $0.iban == iban }) {
            return true
        }

        // Name nur als zweite Instanz. `truncateName` kürzt eingehende Namen auf zwei
        // Wörter (YaxiService), deshalb wird auf beiden Seiten gleich gekürzt verglichen.
        guard let name = normalisierterName(name), !name.isEmpty else { return false }
        return eintraege.values.contains { $0.inhaber == name }
    }

    // MARK: - Normalisierung

    private static func normalisierteIban(_ iban: String?) -> String? {
        guard let iban else { return nil }
        return iban.filter { !$0.isWhitespace }.uppercased()
    }

    /// Kleinschreibung, gestutzt auf die ersten zwei Wörter — dieselbe Kürzung, die
    /// `YaxiService.truncateName` auf ankommende Namen anwendet. Ohne sie verglichen wir
    /// „Stefan Salmhofer" mit „Stefan Salmhofer Dr." und fänden nichts.
    private static func normalisierterName(_ name: String?) -> String? {
        guard let name else { return nil }
        let woerter = name.lowercased()
            .split(whereSeparator: { $0.isWhitespace })
            .prefix(2)
        return woerter.isEmpty ? nil : woerter.joined(separator: " ")
    }
}
