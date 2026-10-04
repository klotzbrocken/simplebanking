import Foundation
import MCPRahmen

// MARK: - Ist simplesend bezahlt?
//
// `prepare_transfer` gibt es nur mit aktiver simplesend-Lizenz. Das ist **keine**
// Sicherheitsschranke — wer den Rechner hat, hat auch den Schlüsselbund. Es ist die
// Antwort auf eine Produktfrage: Der Entwurfsweg gehört zum bezahlten Modul, also
// bietet ihn der Server nur an, wo das Modul auch da ist.
//
// **Gelesen wird der Zeitstempel, nicht der Schlüssel.** Der Lizenzschlüssel liegt im
// Schlüsselbund, und ein zweites Binary, das ihn anfasst, löst beim Nutzer eine
// Freigabe-Abfrage aus — mitten in einer Agenten-Sitzung, ohne erkennbaren Anlass. Der
// Zeitstempel reicht aber ohnehin: `LicenseManager` setzt ihn ausschließlich nach einer
// **erfolgreichen** Server-Bestätigung und löscht ihn in `deactivateLocally()` zusammen
// mit dem Schlüssel. Ein Zeitstempel im Gnadenfenster heißt also: Es gab einen gültigen
// Schlüssel, und das vor höchstens 14 Tagen.
enum Lizenz {

    /// Muss mit `LicenseManager.lastValidatedKey` übereinstimmen. Es gibt keinen
    /// Compiler, der das erzwingt — App und Server bauen getrennt.
    private static let bestaetigtAmSchluessel = "license.lastValidatedAt"

    static func istAktiv(jetzt: Date = Date()) -> Bool {
        let bestaetigtAm = UserDefaults(suiteName: BankingTools.appDomain)?
            .object(forKey: bestaetigtAmSchluessel) as? Date
        return LizenzFenster.istAktiv(bestaetigtAm: bestaetigtAm, jetzt: jetzt)
    }
}
