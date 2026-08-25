import Foundation

/// Grobe Einschätzung, wie gut eine Passphrase ist.
///
/// **Bewusst keine Prozentzahl und kein „sicher".** Was eine Passphrase aushält, hängt
/// davon ab, wie der Angreifer rät — das weiß niemand vorher. Vier Stufen mit einem Satz
/// Klartext sind ehrlicher als eine Zahl, die Genauigkeit vortäuscht.
///
/// Gerechnet wird eine Untergrenze der Entropie: Zeichenvorrat hoch Länge, abzüglich
/// Abschlägen für Muster, die Rateprogramme zuerst probieren. Das überschätzt nie, kann
/// aber unterschätzen — die richtige Richtung für eine Warnung.
enum PassphraseStaerke {

    enum Stufe: Int, Comparable {
        case zuKurz = 0, schwach = 1, brauchbar = 2, gut = 3
        static func < (a: Stufe, b: Stufe) -> Bool { a.rawValue < b.rawValue }
    }

    struct Befund {
        let stufe: Stufe
        let bits: Int
        let text: String
    }

    /// Unterhalb dieser Länge ist alles andere egal.
    static let mindestlaenge = 8

    static func pruefen(_ passphrase: String) -> Befund {
        let zeichen = Array(passphrase)
        guard zeichen.count >= mindestlaenge else {
            return Befund(stufe: .zuKurz, bits: 0,
                          text: L10n.t("Zu kurz — mindestens \(mindestlaenge) Zeichen.",
                                       "Too short — at least \(mindestlaenge) characters."))
        }

        var vorrat = 0
        if passphrase.contains(where: { $0.isLowercase }) { vorrat += 26 }
        if passphrase.contains(where: { $0.isUppercase }) { vorrat += 26 }
        if passphrase.contains(where: { $0.isNumber })    { vorrat += 10 }
        if passphrase.contains(where: { !$0.isLetter && !$0.isNumber }) { vorrat += 30 }

        var bits = Int(Double(zeichen.count) * log2(Double(max(vorrat, 2))))

        // Abschlag für Wiederholungen: „aaaaaaaa" hat rechnerisch dieselbe Länge wie
        // „k7#pQm2z", ist aber in Sekunden geraten.
        let verschiedene = Set(zeichen).count
        if verschiedene <= 4 { bits /= 3 }
        else if verschiedene * 2 <= zeichen.count { bits = bits * 2 / 3 }

        // Abschlag für reine Ziffernfolgen und einfache Tastaturmuster.
        let klein = passphrase.lowercased()
        for muster in ["1234", "abcd", "qwert", "asdf", "password", "passwort", "0000"]
        where klein.contains(muster) {
            bits = bits * 2 / 3
            break
        }

        switch bits {
        case ..<40:
            return Befund(stufe: .schwach, bits: bits,
                          text: L10n.t("Schwach — leicht zu raten. Länger oder mit mehr Zeichenarten.",
                                       "Weak — easy to guess. Make it longer or mix character types."))
        case 40..<70:
            return Befund(stufe: .brauchbar, bits: bits,
                          text: L10n.t("Brauchbar. Mehrere zufällige Wörter wären deutlich besser.",
                                       "Usable. Several random words would be considerably better."))
        default:
            return Befund(stufe: .gut, bits: bits,
                          text: L10n.t("Gut.", "Good."))
        }
    }
}
