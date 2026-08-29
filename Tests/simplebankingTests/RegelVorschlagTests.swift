import XCTest
@testable import simplebanking

// MARK: - „Als Regel speichern" muss auch etwas bewirken
//
// Gemeldet am 29.08.2026: Der Empfängername lässt sich in der Buchung ändern, aber als
// Regel gespeichert passierte nichts.
//
// Die Ursache war der Vorschlag: `suggestedRulePattern` lieferte **nur** bei PayPal-artigen
// Verwendungszwecken („Ihr Einkauf bei …") ein Muster, sonst eine leere Zeichenkette. Bei
// einer gewöhnlichen Kartenzahlung blieb das Feld leer, und das Speichern brach mit
// „Bitte ein Suchmuster angeben" ab — ein Hinweis, den man übersieht.
//
// Dazu kam ein zweiter Fehler: Der Bereich stand fest auf „Verwendungszweck". Selbst mit
// einem Muster aus dem Empfängernamen hätte die Regel dort nie getroffen.

final class RegelVorschlagTests: XCTestCase {

    private func buchung(empfaenger: String?, zweck: String,
                         betrag: String = "-24,80") -> TransactionsResponse.Transaction {
        TransactionsResponse.Transaction(
            bookingDate: "2026-08-20", valueDate: "2026-08-20", status: "booked", endToEndId: nil,
            amount: .init(currency: "EUR", amount: betrag),
            creditor: empfaenger.map { .init(name: $0, fullName: nil, iban: nil, bic: nil) },
            debtor: nil,
            remittanceInformation: [zweck], additionalInformation: nil, purposeCode: nil)
    }

    /// Der gemeldete Fall: Kartenzahlung, kein PayPal-Text.
    func test_kartenzahlungBekommtEinMuster() {
        let v = MerchantResolver.regelVorschlag(
            fuer: buchung(empfaenger: "Dornseifers Frischeb.", zweck: "Dornseifers Frischeb. Siegen, DE"))
        XCTAssertEqual(v.muster, "Dornseifers Frischeb.")
        XCTAssertEqual(v.bereich, .empfaenger, "zum Empfängernamen gehört der Empfänger-Bereich")
    }

    /// PayPal bleibt, wie es war — dort ist der Verwendungszweck die bessere Quelle.
    func test_paypalNimmtWeiterhinDenVerwendungszweck() {
        let v = MerchantResolver.regelVorschlag(
            fuer: buchung(empfaenger: "PayPal Europe", zweck: "PP.1234.PP . Ihr Einkauf bei Steam"))
        XCTAssertTrue(v.muster.contains("steam"), v.muster)
        XCTAssertEqual(v.bereich, .verwendungszweck)
    }

    /// Bei einem Eingang ist die Gegenseite der Absender, nicht der Empfänger.
    func test_eingangNimmtDenAbsender() {
        var tx = buchung(empfaenger: nil, zweck: "Gehalt August", betrag: "2400,00")
        tx = TransactionsResponse.Transaction(
            bookingDate: tx.bookingDate, valueDate: tx.valueDate, status: tx.status,
            endToEndId: nil, amount: tx.amount, creditor: nil,
            debtor: .init(name: "Muster GmbH", fullName: nil, iban: nil, bic: nil),
            remittanceInformation: tx.remittanceInformation,
            additionalInformation: nil, purposeCode: nil)
        let v = MerchantResolver.regelVorschlag(fuer: tx)
        XCTAssertEqual(v.muster, "Muster GmbH")
        XCTAssertEqual(v.bereich, .empfaenger)
    }

    func test_ohneJedeGegenseiteBleibtDasMusterLeer() {
        let v = MerchantResolver.regelVorschlag(fuer: buchung(empfaenger: nil, zweck: ""))
        XCTAssertTrue(v.muster.isEmpty)
    }

    /// **Der Beweis, dass die Regel danach trifft.** Ohne ihn wüssten wir nur, dass ein
    /// Muster entsteht — nicht, dass es wirkt.
    func test_gespeicherteRegelGreiftAufDieBuchung() {
        let tx = buchung(empfaenger: "Dornseifers Frischeb.", zweck: "Dornseifers Frischeb. Siegen, DE")
        let v = MerchantResolver.regelVorschlag(fuer: tx)

        let vorher = MerchantResolver.resolve(transaction: tx).effectiveMerchant
        XCTAssertNotEqual(vorher, "Dornseifer Frischemarkt")

        guard let regel = MerchantResolver.saveRule(pattern: v.muster, merchant: "Dornseifer Frischemarkt",
                                                    scope: v.bereich, matchType: .contains) else {
            return XCTFail("Regel ließ sich nicht speichern")
        }
        defer { _ = MerchantResolver.removeRule(id: regel.id) }

        XCTAssertEqual(MerchantResolver.resolve(transaction: tx).effectiveMerchant,
                       "Dornseifer Frischemarkt", "die Regel muss auf die Buchung wirken")
    }
}
