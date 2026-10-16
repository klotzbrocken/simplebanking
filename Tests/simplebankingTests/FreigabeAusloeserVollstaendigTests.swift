import XCTest
@testable import simplebanking

/// Gemeldet am 16.10.2026: Ein ING-Konto brauchte eine neue Freigabe, und sie ließ sich
/// nicht anstoßen. Weder das Öffnen der Umsatzliste noch der ↻ im Listenkopf noch
/// Pull-to-Refresh kamen durch.
///
/// Ursache war meine eigene Änderung vom 01.10.2026. `Freigabeausloeser` hat den
/// Vorgabewert `.hintergrund`, damit eine vergessene Aufrufstelle nie ungefragt eine
/// Bankseite öffnet — die sichere Richtung. Die Kehrseite: Vergisst man ihn an einer
/// Stelle, die sehr wohl eine Nutzerhandlung ist, verstummt sie, und zwar lautlos. Genau
/// das war in `openTransactionsPanel` passiert, dem Pfad, durch den **alles** läuft, was
/// der Nutzer in der Umsatzliste anfasst.
///
/// Kein Compiler warnt davor, weil ein Vorgabewert genau dafür da ist, weggelassen zu
/// werden. Also prüft dieser Test den Quelltext selbst: **Jede** Aufrufstelle von
/// `fetchBalances`, `fetchTransactions` und `fetchAccounts` muss den Auslöser
/// ausdrücklich nennen. Der Vorgabewert bleibt `.hintergrund` — aber niemand soll sich
/// mehr versehentlich auf ihn verlassen.
final class FreigabeAusloeserVollstaendigTests: XCTestCase {

    /// Die drei Dienste, die eine Freigabe auslösen können.
    private let dienste = ["fetchBalances", "fetchTransactions", "fetchAccounts"]

    private var quellenverzeichnis: URL {
        // …/Tests/simplebankingTests/<diese Datei> → …/Sources/simplebanking
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // simplebankingTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // Paketwurzel
            .appendingPathComponent("Sources/simplebanking")
    }

    /// Alle Aufrufstellen mit Datei, Zeile und dem vollständigen Klammerausdruck.
    private func aufrufstellen() throws -> [(datei: String, zeile: Int, dienst: String, argumente: String)] {
        let fm = FileManager.default
        guard let lauf = fm.enumerator(at: quellenverzeichnis, includingPropertiesForKeys: nil) else {
            return []
        }
        var gefunden: [(String, Int, String, String)] = []
        for fall in lauf {
            guard let url = fall as? URL, url.pathExtension == "swift" else { continue }
            let text = try String(contentsOf: url, encoding: .utf8)
            for dienst in dienste {
                var suchStart = text.startIndex
                while let treffer = text.range(of: "YaxiService.\(dienst)(", range: suchStart ..< text.endIndex) {
                    // Vom „(" bis zur passenden „)" zählen, damit mehrzeilige Aufrufe
                    // vollständig erfasst werden.
                    var tiefe = 0
                    var i = text.index(before: treffer.upperBound)
                    let klammerAuf = i
                    while i < text.endIndex {
                        if text[i] == "(" { tiefe += 1 }
                        else if text[i] == ")" {
                            tiefe -= 1
                            if tiefe == 0 { break }
                        }
                        i = text.index(after: i)
                    }
                    let zeile = text[text.startIndex ..< treffer.lowerBound]
                        .filter { $0 == "\n" }.count + 1
                    gefunden.append((url.lastPathComponent, zeile, dienst,
                                     String(text[klammerAuf ... min(i, text.index(before: text.endIndex))])))
                    suchStart = treffer.upperBound
                }
            }
        }
        return gefunden
    }

    // MARK: - Der eigentliche Test

    func test_jedeAufrufstelleNenntDenAusloeserAusdruecklich() throws {
        let stellen = try aufrufstellen()
        XCTAssertFalse(stellen.isEmpty, "Keine Aufrufstelle gefunden — stimmt der Pfad noch?")

        let ohne = stellen.filter { !$0.argumente.contains("ausloeser") }
        XCTAssertTrue(ohne.isEmpty, """
            Diese Aufrufe verlassen sich auf den Vorgabewert `.hintergrund`:
            \(ohne.map { "  \($0.datei):\($0.zeile)  \($0.dienst)" }.joined(separator: "\n"))

            Entscheide bewusst: `.nutzerhandlung`, wenn der Nutzer unmittelbar davor
            etwas angeklickt hat — sonst `.hintergrund`. Beides ist richtig, nur das
            Weglassen nicht.
            """)
    }

    /// Gegenprobe, damit der Test oben nicht aus Versehen leer durchläuft: Der Pfad, der
    /// den Fehler ausgelöst hat, muss ihn ausdrücklich auf `.nutzerhandlung` setzen.
    func test_dieUmsatzlisteGiltAlsNutzerhandlung() throws {
        let quelle = try String(contentsOf: quellenverzeichnis
            .appendingPathComponent("BalanceBar.swift"), encoding: .utf8)
        let panel = try XCTUnwrap(quelle.range(of: "private func openTransactionsPanel"))
        // Bis zum nächsten `private func` auf derselben Ebene schauen.
        let rest = quelle[panel.upperBound...]
        let ende = rest.range(of: "\n    private func ")?.lowerBound ?? rest.endIndex
        let koerper = String(rest[rest.startIndex ..< ende])

        XCTAssertTrue(koerper.contains("ausloeser: .nutzerhandlung"),
                      "Durch `openTransactionsPanel` läuft der ↻ der Umsatzliste. Ohne "
                      + "`.nutzerhandlung` lässt sich ein Konto mit abgelaufener "
                      + "Zustimmung nicht mehr wiederbeleben.")
    }

    /// Und die andere Richtung: Der Nachlauf nach einem Abruf darf **nie** etwas öffnen.
    func test_derNachlaufBleibtHintergrund() throws {
        let quelle = try String(contentsOf: quellenverzeichnis
            .appendingPathComponent("BalanceBar.swift"), encoding: .utf8)
        let fn = try XCTUnwrap(quelle.range(of: "private func checkNewBookings"))
        let rest = quelle[fn.upperBound...]
        let ende = rest.range(of: "\n    private func ")?.lowerBound ?? rest.endIndex
        let koerper = String(rest[rest.startIndex ..< ende])

        XCTAssertTrue(koerper.contains("ausloeser: .hintergrund"))
        XCTAssertFalse(koerper.contains("ausloeser: .nutzerhandlung"),
                       "`checkNewBookings` läuft auch nach dem zeitgesteuerten Abruf.")
    }
}
