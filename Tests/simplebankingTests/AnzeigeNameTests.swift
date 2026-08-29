import XCTest
@testable import simplebanking

// MARK: - Voller Name in der Anzeige, gekürzter als Schlüssel
//
// Gemeldet am 29.08.2026: In der Liste stand „Dornseifers Frischeb". Der Schnitt kam nicht
// von der Bank — `truncateName` behält die ersten **zwei Wörter**, und der Rest ging beim
// Import verloren.
//
// Der gekürzte Name ist aber nicht bloß Anzeige, sondern **Gruppierungsschlüssel**: An ihm
// hängen Fixkosten, Abo-Erkennung, Zuordnungsregeln und die Ausschlüsse des Nutzers. Ihn
// zu verlängern hätte bestehende Gruppen zerfallen lassen. Deshalb wandert der volle Name
// getrennt mit, und nur die Anzeige nimmt ihn.

final class AnzeigeNameTests: XCTestCase {

    private func aufloesung(_ merchant: String) -> MerchantResolution {
        MerchantResolver.resolve(
            empfaenger: merchant, absender: nil,
            verwendungszweck: nil, additionalInformation: nil
        )
    }

    /// Der gemeldete Fall.
    func test_gekuerzterEmpfaengerWirdDurchDenVollenErsetzt() {
        let a = aufloesung("Dornseifers Frischeb.")
        let name = MerchantResolver.anzeigeName(fuer: a, vollerName: "Dornseifers Frischeb. Siegen")
        XCTAssertEqual(name, "Dornseifers Frischeb. Siegen")
    }

    /// **Die Gegenprobe, auf die es ankommt:** Wurde ein Händler erkannt, ist sein Name
    /// kürzer *und* besser. Den vollen Rohtext zu zeigen wäre ein Rückschritt.
    func test_erkannterHaendlerBehaeltSeinenNamen() {
        let a = aufloesung("REWE SAGT DANKE 12345")
        XCTAssertEqual(a.effectiveMerchant, "Rewe", "Vorbedingung: der Händler wird erkannt")
        let name = MerchantResolver.anzeigeName(fuer: a, vollerName: "REWE SAGT DANKE 12345")
        XCTAssertEqual(name, "Rewe")
    }

    /// Alte Buchungen haben keinen vollen Namen — dort bleibt es beim gekürzten.
    func test_ohneVollenNamenBleibtEsBeimGekuerzten() {
        let a = aufloesung("Dornseifers Frischeb.")
        XCTAssertEqual(MerchantResolver.anzeigeName(fuer: a, vollerName: nil), a.effectiveMerchant)
        XCTAssertEqual(MerchantResolver.anzeigeName(fuer: a, vollerName: ""), a.effectiveMerchant)
    }

    /// Der Schlüssel darf sich nicht bewegen — sonst zerfallen Fixkosten und Abos.
    func test_schluesselBleibtZweiWoerter() {
        XCTAssertEqual(YaxiService.truncateName("Dornseifers Frischeb. Siegen"), "Dornseifers Frischeb.")
        XCTAssertEqual(YaxiService.truncateName("Gothaer Krankenversicherung AG"), "Gothaer Krankenversicherung")
        XCTAssertNil(YaxiService.truncateName(nil))
    }

    /// Beides zusammen an einer Buchung: Anzeige lang, Schlüssel kurz.
    func test_anEinerBuchung() {
        var tx = TransactionsResponse.Transaction(
            bookingDate: "2026-08-20", valueDate: "2026-08-20", status: "booked", endToEndId: nil,
            amount: .init(currency: "EUR", amount: "-24,80"),
            creditor: .init(name: "Dornseifers Frischeb.", fullName: "Dornseifers Frischeb. Siegen",
                            iban: nil, bic: nil),
            debtor: nil, remittanceInformation: nil, additionalInformation: nil, purposeCode: nil)
        tx.slotId = "legacy"

        let a = MerchantResolver.resolve(transaction: tx)
        XCTAssertEqual(a.effectiveMerchant, "Dornseifers Frischeb", "Schlüssel unverändert")
        XCTAssertEqual(MerchantResolver.anzeigeName(fuer: a, vollerName: tx.creditor?.fullName),
                       "Dornseifers Frischeb. Siegen", "Anzeige vollständig")
    }
}
