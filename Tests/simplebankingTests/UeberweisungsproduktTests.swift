import XCTest
import RoutexModels
@testable import simplebanking

/// Gemeldet am 20.10.2026: „Überweisungen werden nicht in Echtzeit ausgeführt, sondern
/// erst nach 1-2 Tagen." Der Nutzer merkte an, dass seine ING Echtzeit standardmäßig
/// beherrscht — an der Bank lag es also nicht.
///
/// Lag es auch nicht. Im Aufruf stand fest verdrahtet `product: .sepaCreditTransfer`,
/// also **immer** die langsame Variante. Zwanzig Zeilen darüber behauptete ein Kommentar
/// „nil = sofort (SEPA Instant)" — das war nie wahr und hat die Suche in die Irre geführt.
///
/// YAXI am 21.10.2026: „Das Produkt legt der Aufruf fest. `product:` ist Pflicht. Bei
/// nicht möglichem `.sepaInstantCreditTransfer` ist `UnsupportedProduct` vorgesehen.
/// `.defaultSEPACreditTransfer` fällt auf SCT zurück."
final class UeberweisungsproduktTests: XCTestCase {

    /// Die Voreinstellung muss Echtzeit **versuchen**. `.sepaCreditTransfer` wäre die
    /// alte, immer langsame Wahl; `.sepaInstantCreditTransfer` würde bei jeder Bank ohne
    /// Echtzeit abbrechen. Dazwischen liegt die richtige Antwort.
    func test_voreinstellungVersuchtEchtzeitUndFaelltZurueck() throws {
        let quelle = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Sources/simplebanking/YaxiService.swift"),
            encoding: .utf8)

        XCTAssertTrue(quelle.contains("produkt: PaymentProduct = .defaultSEPACreditTransfer"),
                      "Die Voreinstellung muss Echtzeit versuchen und still zurückfallen.")
        // Auch die beiden Wiederholungsversuche: Dort stand dasselbe fest verdrahtete
        // SCT, eine erzwungene Echtzeitüberweisung wäre beim Retry still langsam geworden.
        XCTAssertFalse(quelle.contains("product: .sepaCreditTransfer"),
                       "Fest verdrahtetes SCT war der gemeldete Fehler.")
        XCTAssertEqual(quelle.components(separatedBy: "product: produkt,").count - 1, 3,
                       "Erstversuch und beide Wiederholungen müssen dasselbe Produkt nehmen.")
    }

    /// Der Kommentar, der die Fehlersuche gekostet hat, darf nicht zurückkommen.
    func test_derFalscheKommentarIstWeg() throws {
        let quelle = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Sources/simplebanking/YaxiService.swift"),
            encoding: .utf8)
        // Auf die Behauptung prüfen, nicht auf den Wortlaut: Der heutige Kommentar
        // zitiert den alten Satz, um zu erklären, warum er falsch war.
        XCTAssertFalse(quelle.contains("/// `requestedExecutionDate` ist optional. nil = sofort"),
                       "`requestedExecutionDate` steuert den Termin, nicht die Geschwindigkeit.")
    }

    /// Die drei Produkte, auf die sich der Code stützt, müssen im SDK auch so heißen.
    /// Benennt das SDK sie um, soll das hier auffallen und nicht beim Nutzer.
    func test_dieBenutztenProdukteExistieren() {
        XCTAssertEqual(PaymentProduct.defaultSEPACreditTransfer.rawValue, "DefaultSepaCreditTransfer")
        XCTAssertEqual(PaymentProduct.sepaInstantCreditTransfer.rawValue, "SepaInstantCreditTransfer")
        XCTAssertEqual(PaymentProduct.sepaCreditTransfer.rawValue, "SepaCreditTransfer")
    }

    /// Termin und Echtzeit schließen einander aus — ein Datum bestimmt den Tag, nicht die
    /// Sekunde. Der Schalter wird bei gesetztem Termin gesperrt, und der Aufruf verlangt
    /// zusätzlich `scheduledDate == nil`, damit beides nicht auseinanderlaufen kann.
    func test_terminUndEchtzeitSchliessenEinanderAus() throws {
        let quelle = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Sources/simplebanking/TransferSheet.swift"),
            encoding: .utf8)
        XCTAssertTrue(quelle.contains("(echtzeitErzwingen && scheduledDate == nil)"))
        XCTAssertTrue(quelle.contains(".disabled(scheduledDate != nil)"))
    }
}
