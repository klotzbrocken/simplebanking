import XCTest
@testable import simplebanking

// MARK: - Welche Art von Ort?
//
// Die Startzeile im Protokoll soll die Frage beantworten, die bei jeder Update-Meldung
// zuerst zu klären ist: Läuft die App von einem Ort, an dem Sparkle überhaupt
// installieren darf? Aus „Downloads", von einem gemounteten DMG und aus der
// App-Translocation verweigert es das.
//
// Der Pfad selbst darf dafür **nicht** ins Protokoll: Der `LogSanitizer` ersetzt ihn als
// langen opaken Token vollständig — die Zeile stand bereits einmal nutzlos im Protokoll —
// und er trägt den Benutzernamen in eine Datei, die per Mail zu uns kommt.

final class InstallationsortTests: XCTestCase {

    private func ort(_ pfad: String) -> String {
        Doppelinstallation.ort(URL(fileURLWithPath: pfad))
    }

    func testProgrammeordner() {
        XCTAssertEqual(ort("/Applications/simplebanking.app"), "Programme")
    }

    /// Die drei Orte, an denen Sparkle nicht installieren kann — sie müssen in der Zeile
    /// erkennbar sein, sonst ist sie für den Zweck wertlos.
    func testTranslokationIstErkennbar() {
        let pfad = "/private/var/folders/ab/AppTranslocation/1234-5678/d/simplebanking.app"
        XCTAssertEqual(ort(pfad), "App-Translocation")
    }

    func testGemountetesVolumeIstErkennbar() {
        XCTAssertEqual(ort("/Volumes/simplebanking 2.1.0/simplebanking.app"),
                       "gemountetes Volume (DMG?)")
    }

    func testDownloadsIstErkennbar() {
        XCTAssertEqual(ort(NSHomeDirectory() + "/Downloads/simplebanking.app"), "Downloads")
    }

    func testEntwicklungsBuild() {
        XCTAssertEqual(ort("/Users/jemand/projekt/SimpleBankingBuild/simplebanking.app"),
                       "Entwicklungs-Build")
    }

    func testUnbekannterOrtFaelltNichtDurch() {
        XCTAssertEqual(ort("/opt/irgendwo/simplebanking.app"), "anderer Ort")
    }

    /// Der Grund, warum hier kein Pfad steht: Er käme im Protokoll nicht an.
    func testKeinOrtEnthaeltDenBenutzernamen() {
        let pfade = ["/Applications/simplebanking.app",
                     NSHomeDirectory() + "/Downloads/simplebanking.app",
                     "/Volumes/DMG/simplebanking.app"]
        for p in pfade {
            let beschriftung = ort(p)
            XCTAssertFalse(beschriftung.contains("/"), "ein Pfad hat sich eingeschlichen: \(beschriftung)")
            XCTAssertEqual(LogSanitizer.redact(beschriftung), beschriftung,
                           "die Säuberung darf die Ortsangabe nicht verschlucken")
        }
    }
}
