import Foundation

// MARK: - GiroCode (EPC069-12)
//
// Der QR-Code auf deutschen Rechnungen ist fast immer ein GiroCode: ein kurzer,
// zeilenweiser Textblock, den der Rechnungssteller selbst befüllt hat. Er ist damit die
// **verlässlichste** Quelle, die eine Rechnung zu bieten hat — besser als jede Heuristik
// über Fließtext, weil dort geraten wird, was hier jemand ausdrücklich hingeschrieben hat.
//
// Aufbau (Zeilenindizes, EPC069-12):
//
//   0  BCD                    Kennung
//   1  001 / 002              Fassung
//   2  1 / 2                  Zeichensatz (1 = UTF-8)
//   3  SCT                    SEPA Credit Transfer
//   4  BIC                    in Fassung 001 Pflicht, in 002 optional
//   5  Name des Empfängers    max. 70 Zeichen
//   6  IBAN
//   7  EUR<Betrag>            optional, Punkt als Dezimaltrenner
//   8  Zweckcode              optional
//   9  Strukturierte Referenz optional  ┐ es ist immer nur eine
//  10  Verwendungszweck       optional  ┘ der beiden Zeilen gesetzt
//  11  Hinweis an den Zahler  optional
//
// Reine Funktion ohne Vision/PDFKit, damit sie ohne Bild prüfbar ist.
//
// Kein Logging: Der Inhalt ist eine Zahlungsanweisung.

enum GiroCode {

    struct Daten: Equatable {
        var name: String?
        var iban: String
        /// Deutsches Eingabeformat („1234,56"), wie es die Felder erwarten.
        var betrag: String?
        var verwendungszweck: String?
    }

    /// Liest eine GiroCode-Nutzlast. `nil`, wenn es keiner ist — ein QR-Code auf einer
    /// Rechnung kann auch eine Web-Adresse oder eine Sendungsnummer sein.
    static func parse(_ nutzlast: String) -> Daten? {
        let zeilen = nutzlast
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }

        // Ohne Kennung und Auftragsart ist es kein GiroCode. Beides ist Pflicht, und
        // beides zu prüfen kostet nichts — ein falsch erkannter QR-Code führte sonst
        // eine Zahlung in die Irre.
        guard zeilen.count >= 7,
              zeilen[0].uppercased() == "BCD",
              zeilen[3].uppercased() == "SCT" else { return nil }

        guard let iban = IbanClipboardScanner.extractIban(from: zeilen[6]) else { return nil }

        var daten = Daten(name: zeilen[5].nilIfEmpty, iban: iban,
                          betrag: nil, verwendungszweck: nil)

        if zeilen.count > 7 { daten.betrag = betrag(aus: zeilen[7]) }

        // Neun ist die strukturierte Referenz, zehn der freie Text. Gesetzt ist immer
        // nur eines von beidem; der freie Text hat Vorrang, weil er lesbar ist.
        if zeilen.count > 10, let frei = zeilen[10].nilIfEmpty {
            daten.verwendungszweck = frei
        } else if zeilen.count > 9, let referenz = zeilen[9].nilIfEmpty {
            daten.verwendungszweck = referenz
        }

        return daten
    }

    /// „EUR123.45" → „123,45". Ein Betrag von null heißt **kein** Betrag: Der
    /// Rechnungssteller überlässt die Höhe dann dem Zahler, und „0,00 €" ins Feld zu
    /// schreiben wäre schlimmer als es leer zu lassen.
    static func betrag(aus zeile: String) -> String? {
        let roh = zeile.uppercased()
        guard roh.hasPrefix("EUR") else { return nil }
        let zahl = roh.dropFirst(3).trimmingCharacters(in: .whitespaces)
        guard let wert = Double(zahl), wert > 0 else { return nil }
        // Zwei Nachkommastellen, Komma als Trenner — so erwarten es die Eingabefelder.
        return String(format: "%.2f", wert).replacingOccurrences(of: ".", with: ",")
    }

    /// Ergänzt fehlende Felder aus dem Fließtext.
    ///
    /// Name und IBAN bleiben beim QR-Code — dort stehen sie ausdrücklich. Betrag und
    /// Verwendungszweck fehlen dagegen häufig (dieser GiroCode trug `EUR0.0`), und die
    /// stehen im Text der Rechnung. Ergänzt wird nur, wenn der Text **keine andere** IBAN
    /// nennt: Sonst stammte der Betrag womöglich von einer anderen Zahlung auf demselben
    /// Blatt.
    static func ergaenzt(_ ausCode: TransferClipboardParser.Parsed,
                         mit ausText: TransferClipboardParser.Parsed)
        -> TransferClipboardParser.Parsed {
        guard ausText.iban == nil || ausText.iban == ausCode.iban else { return ausCode }
        var out = ausCode
        if out.amount == nil { out.amount = ausText.amount }
        if out.purpose == nil { out.purpose = ausText.purpose }
        if out.name == nil { out.name = ausText.name }
        return out
    }

    /// Übersetzt in das, was die Übernahme-Ansicht ohnehin verarbeitet.
    static func alsParsed(_ d: Daten) -> TransferClipboardParser.Parsed {
        TransferClipboardParser.Parsed(name: d.name, iban: d.iban,
                                       amount: d.betrag, purpose: d.verwendungszweck)
    }
}
