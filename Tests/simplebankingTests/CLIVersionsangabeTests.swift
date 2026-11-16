import XCTest
@testable import simplebanking

/// `sb --version` darf keine handgepflegte Konstante sein.
///
/// Bis 2.2.2 stand in der `CommandConfiguration` des CLI `version: "1.5.0"`. Die App
/// war längst bei 2.2.2, und niemand hatte die Zahl mitgezogen. Aufgefallen ist es am
/// 16.11.2026 beim Rauchtest eines Builds, nicht durch einen Fehlschlag: Eine falsche
/// Versionsangabe läuft fehlerfrei. Dieselbe Falle wie bei der Routex-Zeile im
/// Fehlerreport, siehe [SDKVersionsangabeTests].
///
/// Das CLI liegt in einem eigenen Ziel, von dem dieses Testziel nicht abhängt (siehe
/// `Package.swift`), also lässt sich die Funktion hier nicht aufrufen. Geprüft wird
/// deshalb der Quelltext, wie bei den anderen Zusagen dieser Art. Das Verhalten selbst
/// ist am gebauten Binary geprüft: im Bundle, über den `sb`-Symlink, als
/// Entwicklungsbuild und in einem fremden Bundle.
final class CLIVersionsangabeTests: XCTestCase {

    private func cliQuelle(_ name: String) throws -> String {
        Quelltext.ohneKommentare(try Quelltext.quelle("Sources/simplebanking-cli/\(name)"))
    }

    /// Keine Versionsnummer als Literal, irgendwo im CLI.
    func testKeineFesteVersionImCLI() throws {
        for name in ["SimplebankingCLI.swift", "CLIVersion.swift"] {
            let quelle = try cliQuelle(name)
            XCTAssertNil(
                quelle.range(of: #""[0-9]+\.[0-9]+\.[0-9]+""#, options: .regularExpression),
                "\(name) trägt wieder eine festgeschriebene Version. Genau die war vier Minor-Versionen lang falsch."
            )
        }
    }

    /// Die Angabe kommt aus der Info.plist des Bundles, in dem das Binary liegt.
    func testDieVersionKommtAusDemBundle() throws {
        let aufrufer = try cliQuelle("SimplebankingCLI.swift")
        XCTAssertTrue(aufrufer.contains("version: CLIVersion.text()"),
                      "Die `CommandConfiguration` soll die Version erfragen, nicht tragen")

        let quelle = try cliQuelle("CLIVersion.swift")
        XCTAssertTrue(quelle.contains("CFBundleShortVersionString"),
                      "Ohne die Plist gibt es keine Quelle für die Zahl")
        XCTAssertTrue(quelle.contains("CFBundleVersion"),
                      "Die Build-Nummer gehört dazu, sonst ist ein Supportfall nicht einem Build zuzuordnen")
    }

    /// Zwei Zusagen, die das Verhalten draußen tragen: `sb` ist ein Symlink ins Bundle
    /// (siehe `CLIInstaller`), und ein fremdes Bundle darf seine Version nicht
    /// unterschieben.
    func testSymlinkWirdAufgeloestUndFremdeBundlesAbgelehnt() throws {
        let quelle = try cliQuelle("CLIVersion.swift")
        XCTAssertTrue(quelle.contains("resolvingSymlinksInPath()"),
                      "Ohne Auflösung des Symlinks findet `sb` die Plist nie")
        XCTAssertTrue(quelle.contains("tech.yaxi.simplebanking"),
                      "Die Bundle-Kennung muss geprüft werden, sonst meldet das CLI die Version eines fremden Bundles")
    }
}
