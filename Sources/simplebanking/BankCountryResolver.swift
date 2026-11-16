import Foundation
import RoutexClient

// MARK: - BankCountryResolver
//
// Die Flagge hinter einem Eintrag in der Bankenliste.
//
// Hier stand bis 2.2.2 eine Heuristik über den Anzeigenamen: eine Tabelle mit
// Mustern je Land („schweiz", „bawag", „kantonalbank"), eine Override-Liste für
// Namen ohne Länderhinweis (Berenberg, HypoVereinsbank), eine Reihenfolge, die
// erklärt werden musste (CH vor AT, sonst gilt „Raiffeisen Schweiz" als
// österreichisch) und ein Rückfall auf Deutschland für alles Übrige. Portugal
// trug damit eine deutsche Flagge, obwohl YAXI dort 22 Verbindungen führt.
//
// Am 14.11.2026 hat ein Nutzer die süddeutsche Zweigniederlassung der
// Raiffeisenlandesbank Oberösterreich eingerichtet und kam nicht durch. In der
// Liste stehen zwei Einträge mit fast demselben Namen, einer für Österreich und
// einer für Deutschland, und beide trafen dasselbe Muster
// („raiffeisenlandesbank" → AT): Sie waren nicht unterscheidbar, und die
// deutsche Niederlassung war als österreichisch ausgezeichnet. Auf die Frage
// nach einem Länderfeld kam am 16.11.2026 von YAXI die Antwort, dass es das
// längst gibt: `ConnectionInfo.countries`.
//
// Deshalb wird hier nicht mehr geraten, sondern gelesen. Die Flagge entsteht
// aus dem ISO-3166-1-Code, nicht aus einer Tabelle — damit gilt sie für jedes
// Land, das YAXI heute oder morgen anbietet.

enum BankCountryResolver {

    /// Flagge für die Länder einer Bankverbindung.
    ///
    /// Mehrere Länder (Revolut führt eine lange Liste) oder ein Code, der keine
    /// Flagge ergibt, werden zum Globus: Eine von zwei Flaggen zu zeigen wäre
    /// eine Aussage, die die Daten nicht tragen.
    static func flagge(fuer codes: [CountryCode]) -> String {
        guard codes.count == 1, let code = codes.first else { return globus }
        return emojiFlagge(code.rawValue) ?? globus
    }

    static let globus = "🌐"

    /// Zwei Buchstaben in die beiden Regional-Indicator-Zeichen übersetzen, aus
    /// denen jede Länderflagge besteht: „DE" → U+1F1E9 U+1F1EA.
    ///
    /// `nil` für alles, was keine zwei ASCII-Buchstaben sind. Das SDK prüft den
    /// Code nicht gegen die ISO-Liste, damit alte Server durchlaufen, also kann
    /// hier alles ankommen.
    private static func emojiFlagge(_ code: String) -> String? {
        let gross = code.uppercased()
        let buchstaben = Array(gross.unicodeScalars)
        guard buchstaben.count == 2 else { return nil }
        var flagge = ""
        for b in buchstaben {
            guard b.value >= 65, b.value <= 90,
                  let zeichen = UnicodeScalar(0x1F1E6 + b.value - 65) else { return nil }
            flagge.unicodeScalars.append(zeichen)
        }
        return flagge
    }
}
