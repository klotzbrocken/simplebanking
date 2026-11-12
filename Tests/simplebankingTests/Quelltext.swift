import Foundation

/// Der eigene Quelltext als Prüfgegenstand.
///
/// Mehrere Tests lesen Quelldateien, weil sie eine Zusage prüfen, die kein Typ
/// erzwingt — dass jede Abruf-Stelle ihren Freigabeauslöser mitgibt, dass ein
/// irreführender Kommentar nicht zurückkommt, dass die ausgelieferte Version
/// Highlights hat. Der Weg von einer Testdatei zur Paketwurzel stand dafür in
/// vier Dateien je eigens hingeschrieben, dreimal davon mit demselben Dreisprung
/// und eigener Kommentarspur.
enum Quelltext {

    /// …/Tests/simplebankingTests/Quelltext.swift → Paketwurzel.
    ///
    /// `#filePath` steht hier und gilt hier: Der Wert wird beim Übersetzen *dieser*
    /// Datei eingesetzt, nicht beim Aufrufen. Darum darf der Dreisprung nur in
    /// dieser Datei stehen — zieht sie um, zieht er mit.
    static let paketwurzel = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // simplebankingTests
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()   // Paketwurzel

    static let verzeichnis = paketwurzel.appendingPathComponent("Sources/simplebanking")

    /// Eine Datei aus `Sources/simplebanking`, auch aus einem Unterordner.
    static func datei(_ name: String) throws -> String {
        try String(contentsOf: verzeichnis.appendingPathComponent(name), encoding: .utf8)
    }

    /// Quelltext ohne Kommentare.
    ///
    /// Zusagen über den eigenen Quelltext müssen den **Code** prüfen, nicht die
    /// Prosa: Eine Datei, die im Kopfkommentar festhält „kein `SELECT *`", enthält
    /// die Zeichenfolge `SELECT *` — und eine Zusage, die danach sucht, schlägt an
    /// ihrer eigenen Dokumentation fehl. Genau das ist beim Importhelfer passiert.
    ///
    /// Grob und absichtlich: `//` in einem Zeichenkettenliteral fällt mit weg. Für
    /// eine Suche nach verbotenen Aufrufen reicht das, für einen Übersetzer nicht.
    static func ohneKommentare(_ quelle: String) -> String {
        var ohneBloecke = ""
        var rest = Substring(quelle)
        while let start = rest.range(of: "/*") {
            ohneBloecke += rest[..<start.lowerBound]
            guard let ende = rest.range(of: "*/", range: start.upperBound..<rest.endIndex) else {
                rest = Substring("")
                break
            }
            rest = rest[ende.upperBound...]
        }
        ohneBloecke += rest
        return ohneBloecke
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { zeile in
                guard let strich = zeile.range(of: "//") else { return String(zeile) }
                return String(zeile[..<strich.lowerBound])
            }
            .joined(separator: "\n")
    }

    /// Der Abschnitt zwischen zwei Markierungen — etwa ein Zielblock in
    /// `Package.swift`. Ohne `bis` bis zum Dateiende.
    static func abschnitt(_ quelle: String, von: String, bis: String? = nil) -> String {
        guard let start = quelle.range(of: von) else { return "" }
        let dahinter = quelle[start.upperBound...]
        guard let bis, let ende = dahinter.range(of: bis) else { return String(dahinter) }
        return String(dahinter[..<ende.lowerBound])
    }

    /// Eine Datei irgendwo im Paket, Pfad ab der Wurzel — für Quelltext außerhalb
    /// von `Sources/simplebanking`, etwa den Importhelfer in seinem eigenen Ziel.
    static func quelle(_ pfadAbWurzel: String) throws -> String {
        try String(contentsOf: paketwurzel.appendingPathComponent(pfadAbWurzel), encoding: .utf8)
    }
}
