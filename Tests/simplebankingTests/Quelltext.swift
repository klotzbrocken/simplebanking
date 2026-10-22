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
}
