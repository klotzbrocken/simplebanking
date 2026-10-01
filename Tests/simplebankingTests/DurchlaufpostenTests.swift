import XCTest
@testable import simplebanking

/// Gemeldet am 01.10.2026: „Noch offen" stand bei der Sparkasse Siegen auf 970,37 €, und
/// die Hälfte davon war ein einzelner Posten — „PayPal, 479,80 € monatlich".
///
/// Dahinter lagen zwei fremde Einkäufe: 350,00 € am 26.08. und 609,59 € am 09.09., beide
/// mit dem Verwendungszweck „…/PP.6847.PP/. , Ihr Einkauf bei " — ohne Namen dahinter.
/// `MerchantResolver` konnte keinen Empfänger herausziehen, also blieb der Dienstleister
/// selbst als Händler stehen, und zwei zufällig ähnlich große Beträge ergaben eine
/// „monatliche Fixkostenposition".
///
/// Zwei unabhängige Fehler trafen hier zusammen, und beide sind einzeln wirksam:
/// 1. Ein Zahlungsdienstleister ist kein Empfänger (`istDurchlaufposten`).
/// 2. Zwei Beträge belegen keine Regelmäßigkeit, wenn sie sich um Faktor 1,74
///    unterscheiden (`ErkennungBeiZweiBuchungenTests`).
final class DurchlaufpostenTests: XCTestCase {

    // MARK: - Was ein Durchlaufposten ist

    func test_dieGemeldetenFaelle() {
        XCTAssertTrue(FixedCostsAnalyzer.istDurchlaufposten("PayPal"))
        XCTAssertTrue(FixedCostsAnalyzer.istDurchlaufposten("PayPal Europe"))
        XCTAssertTrue(FixedCostsAnalyzer.istDurchlaufposten("Stichting Mollie"))
    }

    func test_weitereDienstleister() {
        for name in ["Klarna Bank", "Klarna AB", "Adyen", "Stripe", "SumUp",
                     "Amazon Payments", "Google Pay", "Apple Pay", "Concardis",
                     "Unzer GmbH", "Shopify Payments", "Mollie B.V."] {
            XCTAssertTrue(FixedCostsAnalyzer.istDurchlaufposten(name), name)
        }
    }

    func test_schreibweiseUndZeichenEntscheidenNicht() {
        XCTAssertTrue(FixedCostsAnalyzer.istDurchlaufposten("PAYPAL"))
        XCTAssertTrue(FixedCostsAnalyzer.istDurchlaufposten("Pay-Pal") == false,
                      "nur die zusammengeschriebene Marke, nicht jede Trennvariante")
        XCTAssertTrue(FixedCostsAnalyzer.istDurchlaufposten("PayPal (Europe) S.à r.l."))
    }

    // MARK: - Und was keiner ist

    /// Der wichtigste Test hier. Wird der Shop erkannt, heißt die Gruppe nach ihm — und
    /// genau diese Posten sind echte Abos. Im gemeldeten Fall liefen „Google" (27,99 €
    /// über PayPal) und „Anthropic" (über Klarna) so durch und müssen bleiben.
    func test_derErkannteShopBleibt() {
        for name in ["Google", "Google Store", "Anthropic", "Netflix", "Apple",
                     "Amazon", "Zalando", "Rossmann"] {
            XCTAssertFalse(FixedCostsAnalyzer.istDurchlaufposten(name), name)
        }
    }

    /// Teilwörter dürfen nicht treffen.
    func test_teilwoerterTreffenNicht() {
        XCTAssertFalse(FixedCostsAnalyzer.istDurchlaufposten("Paypalooza GmbH"))
        XCTAssertFalse(FixedCostsAnalyzer.istDurchlaufposten("Stripemaster"))
        XCTAssertFalse(FixedCostsAnalyzer.istDurchlaufposten("Nexidental"))
    }

    func test_leererNameIstKeinDurchlaufposten() {
        XCTAssertFalse(FixedCostsAnalyzer.istDurchlaufposten(""))
        XCTAssertFalse(FixedCostsAnalyzer.istDurchlaufposten("   "))
    }

    // MARK: - Am Analysepfad

    private func buchung(_ datum: String, _ betrag: Double, empfaenger: String,
                         zweck: String) -> TransactionsResponse.Transaction {
        TransactionsResponse.Transaction(
            bookingDate: datum, valueDate: datum, status: "booked", endToEndId: nil,
            amount: TransactionsResponse.Amount(currency: "EUR",
                                                amount: String(format: "%.2f", -betrag)),
            creditor: TransactionsResponse.Party(name: empfaenger, iban: "DE02120300000000202051", bic: nil),
            debtor: nil, remittanceInformation: [zweck],
            additionalInformation: nil, purposeCode: nil)
    }

    /// Der gemeldete Fall, Ende zu Ende: Diese beiden Buchungen dürfen keine
    /// Fixkostenposition ergeben.
    func test_zweiFremdeEinkaeufeUeberPayPal_ergebenKeineFixkosten() {
        let tx = [buchung("2026-08-26", 350.00, empfaenger: "PayPal Europe",
                          zweck: "1052577253184/PP.6847.PP/. , Ihr Einkauf bei "),
                  buchung("2026-09-09", 609.59, empfaenger: "PayPal Europe",
                          zweck: "1052917197617/PP.6847.PP/. , Ihr Einkauf bei ")]
        let gefunden = FixedCostsAnalyzer.analyze(transactions: tx)
        XCTAssertTrue(gefunden.isEmpty,
                      "gefunden: \(gefunden.map { "\($0.merchant) \($0.averageAmount)" })")
    }

    /// Auch gleich hohe Beträge ändern daran nichts — die Gruppe ist schon vom Begriff her
    /// keine. Dieser Test hält fest, dass die Dienstleister-Regel **ohne** die Varianz
    /// wirkt und nicht bloß ein Nebeneffekt der engeren Schranke ist.
    func test_auchGleicheBetraegeUeberPayPal_ergebenKeineFixkosten() {
        let tx = [buchung("2026-07-09", 49.99, empfaenger: "PayPal Europe", zweck: "PP.6847.PP/. , Ihr Einkauf bei "),
                  buchung("2026-08-09", 49.99, empfaenger: "PayPal Europe", zweck: "PP.6847.PP/. , Ihr Einkauf bei "),
                  buchung("2026-09-09", 49.99, empfaenger: "PayPal Europe", zweck: "PP.6847.PP/. , Ihr Einkauf bei ")]
        XCTAssertTrue(FixedCostsAnalyzer.analyze(transactions: tx).isEmpty)
    }

    /// Gegenprobe am Analysepfad: Steht der Shop im Verwendungszweck, bleibt der Posten.
    /// Genau so lief „Google, Ihr Einkauf bei Google" über PayPal im echten Konto.
    func test_erkannterShopUeberPayPal_bleibtEineFixkostenposition() {
        let tx = [buchung("2026-08-04", 27.99, empfaenger: "PayPal Europe",
                          zweck: "1052072486374/PP.6847.PP/. Google, Ihr Einkauf bei Google"),
                  buchung("2026-09-03", 27.99, empfaenger: "PayPal Europe",
                          zweck: "1052763383687/PP.6847.PP/. Google, Ihr Einkauf bei Google")]
        let gefunden = FixedCostsAnalyzer.analyze(transactions: tx)
        XCTAssertEqual(gefunden.count, 1, "der erkannte Shop muss bleiben")
        XCTAssertFalse(gefunden.first.map { FixedCostsAnalyzer.istDurchlaufposten($0.merchant) } ?? true)
    }
}
