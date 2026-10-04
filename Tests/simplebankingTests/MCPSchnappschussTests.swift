import XCTest
@testable import simplebanking

/// `get_fixed_costs` und `get_subscriptions` rechnen nichts — sie lesen, was die App
/// beim letzten Abruf abgelegt hat. Der Grund steht in `MCPSchnappschuss`: Zwei
/// Auswertungen derselben Zahl laufen auseinander, und genau das hat am 01.10.2026 eine
/// Woche gekostet.
///
/// Diese Tests halten die Eigenschaften der Datei fest, auf die sich der Server verlässt.
final class MCPSchnappschussTests: XCTestCase {

    private var gesichert: Data?

    override func setUp() {
        super.setUp()
        gesichert = try? Data(contentsOf: MCPSchnappschuss.dateiURL)
    }

    override func tearDown() {
        if let gesichert {
            try? gesichert.write(to: MCPSchnappschuss.dateiURL, options: .atomic)
        } else {
            try? FileManager.default.removeItem(at: MCPSchnappschuss.dateiURL)
        }
        super.tearDown()
    }

    private func zahlung(_ merchant: String, betrag: Double, zuletzt: String) -> RecurringPayment {
        RecurringPayment(merchant: merchant, groupKey: merchant.lowercased(),
                         averageAmount: betrag, occurrences: 4, months: 4,
                         frequency: .monthly, lastDate: zuletzt,
                         category: .other, confidence: 0.9)
    }

    private func schreibe(slot: String, zahlungen: [RecurringPayment], offen: [RecurringPayment]) {
        MCPSchnappschuss.schreibe(
            slotId: slot, bankName: "Testbank", gehaltstag: 15,
            zyklusStart: Date(timeIntervalSince1970: 1_789_000_000),
            zyklusEnde: Date(timeIntervalSince1970: 1_791_600_000),
            zahlungen: zahlungen, offen: offen, historie: [])
    }

    private func gelesen() throws -> [String: Any] {
        let daten = try Data(contentsOf: MCPSchnappschuss.dateiURL)
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: daten) as? [String: Any])
    }

    private func konto(_ slot: String) throws -> [String: Any] {
        let slots = try XCTUnwrap(try gelesen()["slots"] as? [String: Any])
        return try XCTUnwrap(slots[slot] as? [String: Any])
    }

    // MARK: - Was drinstehen muss

    func test_postenUndSummenLandenInDerDatei() throws {
        try? FileManager.default.removeItem(at: MCPSchnappschuss.dateiURL)
        let a = zahlung("Netflix", betrag: 13.99, zuletzt: "2026-09-08")
        let b = zahlung("Gothaer", betrag: 34.81, zuletzt: "2026-09-01")
        schreibe(slot: "s1", zahlungen: [a, b], offen: [a])

        let k = try konto("s1")
        XCTAssertEqual(k["bank_name"] as? String, "Testbank")
        XCTAssertEqual((k["monthly_total_eur"] as? NSNumber)?.doubleValue ?? 0, 48.80, accuracy: 0.001)
        XCTAssertEqual((k["open_total_eur"] as? NSNumber)?.doubleValue ?? 0, 13.99, accuracy: 0.001)

        let posten = try XCTUnwrap(k["fixed_costs"] as? [[String: Any]])
        XCTAssertEqual(posten.count, 2)
        let netflix = try XCTUnwrap(posten.first { $0["merchant"] as? String == "Netflix" })
        XCTAssertEqual(netflix["open_this_cycle"] as? Bool, true)
        // Fälligkeit, nicht letzte Buchung — das ist die Angabe, nach der gefragt wird.
        XCTAssertEqual(netflix["next_due"] as? String, "2026-10-08")
        let gothaer = try XCTUnwrap(posten.first { $0["merchant"] as? String == "Gothaer" })
        XCTAssertEqual(gothaer["open_this_cycle"] as? Bool, false)
    }

    /// Beträge als Dezimalzahl. `(v * 100).rounded() / 100` liefert für 950,42 den Wert
    /// 950.41999999999996 — und genau so stünde er im JSON.
    func test_betraegeHabenKeineKommastellenreste() throws {
        try? FileManager.default.removeItem(at: MCPSchnappschuss.dateiURL)
        schreibe(slot: "s1",
                 zahlungen: [zahlung("A", betrag: 687.42, zuletzt: "2026-09-30"),
                             zahlung("B", betrag: 263.00, zuletzt: "2026-09-03")],
                 offen: [])
        let text = try String(contentsOf: MCPSchnappschuss.dateiURL, encoding: .utf8)
        XCTAssertTrue(text.contains("950.42"), "erwartet 950.42, Datei enthält:\n\(text)")
        XCTAssertFalse(text.contains("950.419"))
    }

    // MARK: - Mehrere Konten

    /// Der Grund, warum nicht die ganze Datei ersetzt wird: `recomputeLeftToPay` läuft je
    /// nach Ansicht nur über das aktive Konto. Würde es die Datei überschreiben,
    /// verschwänden die anderen bei jedem Abruf.
    func test_einKontoSchreibenLaesstDieAnderenStehen() throws {
        try? FileManager.default.removeItem(at: MCPSchnappschuss.dateiURL)
        schreibe(slot: "s1", zahlungen: [zahlung("A", betrag: 10, zuletzt: "2026-09-01")], offen: [])
        schreibe(slot: "s2", zahlungen: [zahlung("B", betrag: 20, zuletzt: "2026-09-02")], offen: [])

        let slots = try XCTUnwrap(try gelesen()["slots"] as? [String: Any])
        XCTAssertEqual(Set(slots.keys), ["s1", "s2"])
    }

    /// Dasselbe Konto erneut zu schreiben ersetzt es — sonst wüchsen alte Posten mit.
    func test_dasselbeKontoWirdErsetztNichtErgaenzt() throws {
        try? FileManager.default.removeItem(at: MCPSchnappschuss.dateiURL)
        schreibe(slot: "s1", zahlungen: [zahlung("Alt", betrag: 10, zuletzt: "2026-08-01")], offen: [])
        schreibe(slot: "s1", zahlungen: [zahlung("Neu", betrag: 20, zuletzt: "2026-09-01")], offen: [])

        let posten = try XCTUnwrap(try konto("s1")["fixed_costs"] as? [[String: Any]])
        XCTAssertEqual(posten.map { $0["merchant"] as? String }, ["Neu"])
    }

    /// Ein entferntes Konto muss verschwinden. Bliebe es stehen, sähe ein Agent
    /// Händlernamen und Beträge eines Kontos, das der Nutzer gelöscht hat.
    func test_entferntesKontoVerschwindet() throws {
        try? FileManager.default.removeItem(at: MCPSchnappschuss.dateiURL)
        schreibe(slot: "s1", zahlungen: [zahlung("A", betrag: 10, zuletzt: "2026-09-01")], offen: [])
        schreibe(slot: "s2", zahlungen: [zahlung("B", betrag: 20, zuletzt: "2026-09-02")], offen: [])
        MCPSchnappschuss.entferne(slotId: "s1")

        let slots = try XCTUnwrap(try gelesen()["slots"] as? [String: Any])
        XCTAssertEqual(Set(slots.keys), ["s2"])
    }

    /// Jedes Konto trägt seinen Zeitstempel. Ohne ihn kann ein Agent nicht sagen, ob er
    /// gerade den Stand von heute oder von letzter Woche vorliest.
    func test_jedesKontoTraegtSeinenZeitstempel() throws {
        try? FileManager.default.removeItem(at: MCPSchnappschuss.dateiURL)
        schreibe(slot: "s1", zahlungen: [], offen: [])
        let stempel = try XCTUnwrap(try konto("s1")["updated_at"] as? String)
        XCTAssertFalse(stempel.isEmpty)
        XCTAssertNotNil(ISO8601DateFormatter().date(from: stempel))
    }
}
