import Foundation

/// Unterscheidet, wonach eine Bank in einem `.selection`-Dialog fragt.
///
/// `handleSCA` beantwortet solche Dialoge selbst, mit einer Heuristik für
/// TAN-**Verfahren** („push", „app", „decoupled", sonst der erste Eintrag). Fragt die
/// Bank stattdessen nach dem **Konto**, wählt dieselbe Heuristik blind — und eine
/// Überweisung ginge womöglich von einem anderen Konto ab als im Formular.
///
/// Seit die App das Quellkonto mit `debtorAccount` benennt, sollte das nicht mehr
/// vorkommen. Sollte es doch, ist eine Zeile im Protokoll der Unterschied zwischen
/// „unerklärlich" und „nachvollziehbar".
enum Auswahlart {

    /// Erkennt eine Kontoauswahl an IBAN-artigen Optionen.
    ///
    /// Eine IBAN beginnt mit zwei Buchstaben und zwei Ziffern und ist mindestens 15
    /// Zeichen lang. Geprüft wird über Schlüssel, Beschriftung und Erläuterung
    /// zusammen, weil Banken die IBAN mal im einen, mal im anderen Feld führen.
    static func sindKonten(_ texte: [String]) -> Bool {
        texte.contains { enthaeltIban($0) }
    }

    static func enthaeltIban(_ text: String) -> Bool {
        // Trennzeichen entfernen, damit „DE89 3704 0044…" genauso trifft wie
        // „DE89370400440532013000".
        let kompakt = text.replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "\u{00A0}", with: "")
            .uppercased()
        let zeichen = Array(kompakt)
        guard zeichen.count >= 15 else { return false }
        for start in 0...(zeichen.count - 15) {
            let f = zeichen[start...]
            guard f.count >= 15 else { break }
            let vier = Array(f.prefix(4))
            if vier[0].isLetter, vier[1].isLetter, vier[2].isNumber, vier[3].isNumber,
               f.prefix(15).allSatisfy({ $0.isLetter || $0.isNumber }) {
                return true
            }
        }
        return false
    }
}


/// Bestimmt das Quellkonto einer Überweisung aus der am Slot hinterlegten IBAN.
///
/// Ohne `debtorAccount` fragt die Bank selbst nach, und diese Rückfrage beantwortet
/// `handleSCA` mit einer Heuristik für TAN-Verfahren — bei mehreren überweisungsfähigen
/// Konten konnte das Geld deshalb von einem anderen Konto abgehen als im Formular.
enum Quellkonto {

    /// - Returns: Die bereinigte IBAN, oder `nil`, wenn keine hinterlegt ist. Dann
    ///   bleibt es beim bisherigen Verhalten — eine geratene IBAN wäre schlimmer als
    ///   die Rückfrage der Bank.
    static func iban(ausGespeicherter roh: String?) -> String? {
        guard let roh else { return nil }
        let kompakt = roh
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "\u{00A0}", with: "")
            .uppercased()
        return kompakt.isEmpty ? nil : kompakt
    }

    /// Währung des Auftraggeberkontos.
    ///
    /// Fest EUR wie der Betrag: Die App überweist ausschließlich SEPA in Euro. Eine
    /// abweichende Kontowährung hier zu melden, würde den Auftrag nur unnötig
    /// einschränken.
    static let waehrung = "EUR"
}
