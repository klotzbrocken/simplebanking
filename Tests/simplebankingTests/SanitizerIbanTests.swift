import XCTest
@testable import simplebanking

// MARK: - IBAN-Bereinigung in ALLEN Protokollen
//
// Aufgefallen bei der Sicherheitsdurchsicht am 01.08.2026: `SetupDiagnosticsLogger` hatte
// eine eigene, ältere Kopie der Muster, deren IBAN-Regel mit `DE` begann. Eine
// österreichische IBAN (20 Zeichen) matchte sie nicht und landete ungekürzt in
// `~/Library/Logs/simplebanking/setup/*.txt` — einer Datei, die Kunden zur Fehlersuche
// verschicken. Die Datei behauptete im eigenen Kopf „privacy: no personal data logged".
//
// Der easybank-Kunde ist Österreicher. Das war also kein hypothetischer Fall.
//
// Die Kopie ist weg; beide Wege gehen jetzt durch `LogSanitizer`. Diese Tests halten das
// fest — und zwar für beide, damit sie nicht wieder auseinanderlaufen.

final class SanitizerIbanTests: XCTestCase {

    /// Echte Prüfziffern-gültige IBANs verschiedener Länge. Die österreichische steht
    /// hier nicht zufällig an erster Stelle.
    private let ibans: [(land: String, iban: String)] = [
        ("AT (20)", "AT911420020010824665"),
        ("DE (22)", "DE89370400440532013000"),
        ("NL (18)", "NL91ABNA0417164300"),
        ("BE (16)", "BE68539007547034"),
        ("CH (21)", "CH9300762011623852957"),
        ("FR (27)", "FR1420041010050500013M02606"),
    ]

    // MARK: LogSanitizer — der zentrale Weg

    func test_logSanitizer_entferntIbansAllerLaender() {
        for fall in ibans {
            let text = "fetchBalances: iban=\(fall.iban) ok"
            let sauber = LogSanitizer.redact(text)
            XCTAssertFalse(sauber.contains(fall.iban),
                           "\(fall.land): IBAN steht noch im Text — \(sauber)")
        }
    }

    /// Banktexte und Traces liefern IBANs oft in Vierergruppen.
    func test_logSanitizer_entferntAuchGruppierteSchreibweise() {
        let sauber = LogSanitizer.redact("Empfänger AT91 1420 0200 1082 4665 bestätigt")
        XCTAssertFalse(sauber.contains("4665"), sauber)
    }

    // MARK: SetupDiagnosticsLogger — der Weg, der auseinandergelaufen war

    func test_setupLogger_entferntDieselbenIbans() {
        for fall in ibans {
            let sauber = SetupDiagnosticsLogger.sanitizeForTesting("Konto \(fall.iban) gewählt")
            XCTAssertFalse(sauber.contains(fall.iban),
                           "\(fall.land): IBAN steht noch im Setup-Protokoll — \(sauber)")
        }
    }

    /// Der eigentliche Regressionswächter: Was der eine bereinigt, muss der andere auch
    /// bereinigen. Läuft eine Kopie wieder ein, schlägt das hier fehl statt erst beim
    /// nächsten Kundenprotokoll.
    func test_beideWegeGebenDasselbeErgebnis() {
        let proben = [
            "iban=AT911420020010824665",
            "userId=hansmeier password=geheim123",
            "session=eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9",
            "cd=168b status=ok",                      // harmlose Diagnosewerte
            "Bank meldet: Betrag 42,50 EUR freigegeben",
        ]
        for probe in proben {
            XCTAssertEqual(SetupDiagnosticsLogger.sanitizeForTesting(probe),
                           LogSanitizer.redact(probe),
                           "Die beiden Wege sind wieder auseinandergelaufen: \(probe)")
        }
    }

    /// Diagnosewerte müssen lesbar bleiben — ein Protokoll, das alles schwärzt, ist
    /// wertlos. Das ist die Gegenprobe zur Schwärzung.
    func test_harmloseDiagnosewerteBleibenStehen() {
        let sauber = LogSanitizer.redact("fetchBalances: cd=168b session=nil status=ok")
        XCTAssertTrue(sauber.contains("168b"), sauber)
        XCTAssertTrue(sauber.contains("ok"), sauber)
    }

    // MARK: Die Diagnosezeile von „Fixkosten offen"

    /// Sie enthielt Händlername UND Betrag — zusammen ein Fixkostenprofil. Beides ist
    /// raus; der Name steht nur noch als zweistelliges Kürzel drin, damit man mehrere
    /// Posten auseinanderhalten kann.
    func test_leftToPayZeile_ohneNamenUndBetrag() {
        let merchant = "Allianz Versicherung"
        let zeile = "leftToPay item slot=legacy merchant=\(merchant.prefix(2))… "
            + "freq=Monatlich last=2026-07-14 conf=0.70 occ=2 months=2"
        XCTAssertFalse(zeile.contains(merchant))
        XCTAssertFalse(zeile.contains("avg="), "der Durchschnittsbetrag gehört nicht ins Protokoll")
        XCTAssertTrue(zeile.contains("occ=2"), "die Diagnose muss brauchbar bleiben")
    }
}
