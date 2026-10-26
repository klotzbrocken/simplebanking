import Foundation

/// Der Name, den die Bank ihrem Freigabeverfahren gibt — aufbereitet für einen Satz.
///
/// **Warum es diese Datei gibt.** Bis zum 26.10.2026 stand im Assistenten „Banking-App
/// öffnen und Freigabe bestätigen", und zwar für jede Bank gleich. Der Name des
/// Verfahrens kam die ganze Zeit mit: `handleSCA` wählt aus der Liste der Bank eines
/// aus und schrieb dessen Bezeichnung nur ins Protokoll. Wer zwei Banking-Apps auf dem
/// Telefon hat, musste raten, welche gemeint ist.
///
/// Was die Banken schicken, ist allerdings nicht als Satzbaustein gedacht. Gesehen
/// wurden Formen wie „pushTAN 2.0", „S-pushTAN", „Decoupled TAN" oder nur „PUSHTAN" —
/// Großschreibung, Versionsnummern, technische Kürzel. Darum geht hier nur durch, was
/// sich in „Freigabe in … bestätigen" einsetzen lässt, ohne albern zu klingen.
enum Verfahrensname {

    /// Kürzel, die ein Verfahren bezeichnen statt es zu benennen. Sie in einen Satz
    /// zu setzen („Freigabe in Decoupled TAN bestätigen") hilft keinem.
    private static let technisch: Set<String> = [
        "decoupled", "decoupled tan", "tan", "sca", "app", "mobile", "mobil",
        "freigabe", "approval", "push", "pushtan", "pushtan 2.0"
    ]

    /// - Returns: Den Namen, wie er in einen Satz passt, oder `nil`, wenn die Bank
    ///   nichts Brauchbares geschickt hat. `nil` heißt: beim allgemeinen Text bleiben.
    static func lesbar(aus roh: String?) -> String? {
        guard let roh else { return nil }
        let name = roh.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }

        // Nichts Übermäßiges in die Oberfläche lassen: Manche Banken schicken hier
        // ganze Sätze statt einer Bezeichnung.
        guard name.count <= 40 else { return nil }

        // Eine reine Nummer oder ein Schlüssel wie „M1" benennt nichts. Drei Buchstaben
        // sind die Grenze: Darunter liegen die HBCI-Verfahrenskennungen (M1, M2, …),
        // die die Bank als Schlüssel schickt und nicht als Bezeichnung.
        guard name.filter(\.isLetter).count >= 3 else { return nil }
        guard !technisch.contains(name.lowercased()) else { return nil }

        // „PUSHTAN" wie geliefert anzuzeigen schreit; die gemischte Schreibweise der
        // Banken („S-pushTAN", „photoTAN") bleibt dagegen unangetastet.
        if name == name.uppercased() && name.count > 4 {
            return name.capitalized
        }
        return name
    }

    /// Der Satz, der im Assistenten steht, solange die Bank keinen eigenen schickt.
    static func hinweis(verfahren: String?) -> String {
        guard let name = lesbar(aus: verfahren) else {
            return L10n.t("Banking-App öffnen und Freigabe bestätigen",
                          "Open your banking app and confirm the approval")
        }
        return L10n.t("Freigabe in \(name) bestätigen",
                      "Confirm the approval in \(name)")
    }
}
