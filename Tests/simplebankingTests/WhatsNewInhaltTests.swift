import XCTest
@testable import simplebanking

// MARK: - Die Highlights im „Was ist neu"-Fenster
//
// Der Zusammenhang, der leicht auseinanderläuft: `WhatsNewContent.highlights(for:)`
// schaltet über `CFBundleShortVersionString`. Fehlt der `case`, liefert die Funktion nil,
// das Fenster erscheint gar nicht — und mit ihm nicht die Newsletter-Anmeldung in dessen
// Fuß. Nichts schlägt fehl, es passiert einfach nichts. Genau deshalb steht das als
// Schritt 0 in RELEASING; hier ist der Wächter dazu.

@MainActor
final class WhatsNewInhaltTests: XCTestCase {

    /// Die Version, die ausgeliefert wird, muss Highlights haben. Bricht der Test, wurde
    /// `VERSION_BASE` erhöht, ohne den `case` nachzuziehen — genau der Fehler, den
    /// Schritt 0 in RELEASING verhindern soll.
    ///
    /// Gelesen wird `build-app.sh`, nicht `Bundle.main`: Im Testlauf ist das Bundle der
    /// XCTest-Runner, dessen Version („16.0") mit der App nichts zu tun hat.
    func test_auszuliefernedeVersionHatHighlights() throws {
        let repo = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // simplebankingTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // Repo-Wurzel
        let skript = try String(contentsOf: repo.appendingPathComponent("build-app.sh"),
                                encoding: .utf8)
        let zeile = try XCTUnwrap(
            skript.split(separator: "\n").first { $0.hasPrefix("VERSION_BASE=") },
            "VERSION_BASE steht nicht mehr in build-app.sh — dieser Test braucht einen neuen Anker."
        )
        // Die Zeile lautet VERSION_BASE="${VERSION_BASE:-2.0.2}" — gesucht ist der
        // Vorgabewert hinter dem `:-`, nicht die Shell-Ersetzung drumherum.
        let roh = zeile.replacingOccurrences(of: "VERSION_BASE=", with: "")
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"' \t"))
        let version: String
        if let start = roh.range(of: ":-"), let ende = roh.range(of: "}", range: start.upperBound..<roh.endIndex) {
            version = String(roh[start.upperBound..<ende.lowerBound])
        } else {
            version = roh
        }

        XCTAssertFalse(version.isEmpty)
        XCTAssertNotNil(WhatsNewContent.highlights(for: version),
                        "Für \(version) fehlen die Highlights — das Fenster erschiene beim Update nicht, und mit ihm nicht die Newsletter-Anmeldung in dessen Fuß.")
    }

    func test_202_hatDieNeuerungenDieserRunde() throws {
        let items = try XCTUnwrap(WhatsNewContent.highlights(for: "2.0.2"))
        let text = items.map { $0.title + " " + $0.description }.joined(separator: "\n")

        XCTAssertTrue(text.contains("bunq"), "bunq fehlt")
        XCTAssertTrue(text.localizedCaseInsensitiveContains("importieren"), "Theme-Import fehlt")
        XCTAssertTrue(text.localizedCaseInsensitiveContains("Labor"), "das Labor-Feature fehlt")
    }

    /// Ein Labor-Feature ohne den Hinweis, dass es aus ist und wo man es einschaltet,
    /// erzeugt nur Suchen. Beides muss im Text stehen.
    func test_laborFeature_nenntSchalterUndStandard() throws {
        let items = try XCTUnwrap(WhatsNewContent.highlights(for: "2.0.2"))
        let labor = try XCTUnwrap(items.first { $0.description.localizedCaseInsensitiveContains("Labor") })
        XCTAssertTrue(labor.description.localizedCaseInsensitiveContains("aus"),
                      "der Standardzustand fehlt")
        XCTAssertTrue(labor.description.localizedCaseInsensitiveContains("Einstellungen"),
                      "der Weg zum Schalter fehlt")
    }

    /// bunq-Nutzer müssen einmalig neu einrichten — das darf nicht erst auffallen,
    /// wenn der Abruf scheitert.
    func test_bunq_nenntDieNeueinrichtung() throws {
        let items = try XCTUnwrap(WhatsNewContent.highlights(for: "2.0.2"))
        let bunq = try XCTUnwrap(items.first { $0.description.contains("bunq") })
        XCTAssertTrue(bunq.description.localizedCaseInsensitiveContains("neu eingerichtet"),
                      "die nötige Neueinrichtung wird verschwiegen")
    }

    /// Jeder Eintrag braucht Symbol, Titel und Text — ein leeres Feld fällt im Fenster
    /// als Loch auf, nicht als Fehler.
    func test_keineLeerenFelder() throws {
        for version in ["2.0.2", "2.0.1", "1.5.0"] {
            let items = try XCTUnwrap(WhatsNewContent.highlights(for: version), version)
            XCTAssertFalse(items.isEmpty, version)
            for item in items {
                XCTAssertFalse(item.icon.isEmpty, "\(version): Symbol fehlt")
                XCTAssertFalse(item.title.isEmpty, "\(version): Titel fehlt")
                XCTAssertFalse(item.description.isEmpty, "\(version): Text fehlt bei „\(item.title)")
            }
        }
    }

    /// Versionen ohne kuratierte Highlights zeigen bewusst kein Fenster.
    func test_unbekannteVersion_zeigtNichts() {
        XCTAssertNil(WhatsNewContent.highlights(for: "0.0.1"))
    }
}
