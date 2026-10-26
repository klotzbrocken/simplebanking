import XCTest
@testable import simplebanking

/// Gemeldet am 25.10.2026: „Import failed Abruf: fehlgeschlagen: no connectionid yes"
/// bei einem PayPal-Slot. Das Import-Fenster schickte „Von der Bank laden" ohne
/// Fallunterscheidung in den YAXI-Weg; ein PayPal-Slot hat dort keine
/// Verbindungskennung. Dieser Test hält die Verzweigung fest — an der Slot-Quelle,
/// nicht an der Oberfläche, denn die ist im Testlauf nicht aufbaubar.
final class ImportHerkunftTests: XCTestCase {

    private func slot(_ quelle: SlotSource?) -> BankSlot {
        BankSlot(id: "t", iban: "DE00", displayName: "Test", logoId: nil, source: quelle)
    }

    func test_paypalSlotIstKeinBankslot() {
        let s = slot(.paypal)
        XCTAssertTrue(s.isPayPal)
        XCTAssertFalse(s.isReceiptSlot, "PayPal ist kein Bon-Slot — der Abruf geht über die NVP-API")
    }

    func test_bonSlotsHabenKeineBankSchnittstelle() {
        for quelle in [SlotSource.rewe, .dm, .amazon] {
            XCTAssertTrue(slot(quelle).isReceiptSlot, "\(quelle) muss als Bon-Slot gelten")
            XCTAssertFalse(slot(quelle).isPayPal)
        }
    }

    func test_echteBankIstWederPaypalNochBon() {
        let s = slot(nil)
        XCTAssertFalse(s.isPayPal)
        XCTAssertFalse(s.isReceiptSlot, "Nur für diese Slots darf der YAXI-Deep-Sync laufen")
    }

    /// Der Grund, warum es den eigenen Importeur überhaupt gibt: PayPals Abruf nimmt
    /// die Tageszahl entgegen. Hätte er das nicht, wäre „180/365 Tage" dort sinnlos.
    func test_paypalAbrufKenntEinenZeitraum() throws {
        let quelle = try Quelltext.datei("PayPalService.swift")
        XCTAssertTrue(quelle.contains("fetchTransactions(days: Int"),
                      "Ohne Tageszahl im Abruf wäre ein Deep-Sync bei PayPal nicht möglich")
    }

    /// Die Verzweigung selbst. Steht sie nicht im Import-Fenster, landet ein
    /// PayPal-Slot wieder im YAXI-Weg — genau der gemeldete Fehler.
    func test_importFensterVerzweigtNachHerkunft() throws {
        let quelle = try Quelltext.datei("ImportSheet.swift")
        XCTAssertTrue(quelle.contains("PayPalDeepSyncImporter"),
                      "PayPal-Slots müssen zum eigenen Importeur gehen")
        XCTAssertTrue(quelle.contains("herkunft != .belege"),
                      "Bon-Slots dürfen „von der Bank laden\" nicht angeboten bekommen")
    }
}
