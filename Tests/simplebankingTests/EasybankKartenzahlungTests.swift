import XCTest
@testable import simplebanking

// MARK: - Der easybank-Fall
//
// Gemeldet am 01.08.2026: In JEDER Ausgabenzeile stand der Name des Kontoinhabers statt
// des Händlers. Der Kunde hat unseren CSV-Export und den seiner Bank mitgeschickt.
//
// Ursache, an den Daten belegt: easybank füllt bei Kartenzahlungen die Gegenseite mit
// dem Kontoinhaber UND der eigenen IBAN — 43 von 48 Zeilen. Der Händler steht im
// Verwendungszweck:
//
//     Bezahlung Karte  MC/000025647|LIDL DANKT 3157 D005 31.07. 16:57|LIDL DANKT 517\\WIENER NEUSTA\
//
// Der Resolver kannte das Vorzeichen der Buchung nicht und fiel deshalb auf den
// Debtor zurück — bei einer Ausgabe sind das wir selbst.
//
// Die Zeichenketten hier sind echte Verwendungszwecke aus dem Kundenexport, der Name
// des Kunden ist ersetzt.

final class EasybankKartenzahlungTests: XCTestCase {

    private let eigenerName = "Stefan Salmhofer"
    private let eigeneIban  = "AT911420020010824665"

    override func tearDown() async throws {
        OwnPartyRegistry.leeren()
        try await super.tearDown()
    }

    /// Baut eine Kartenzahlung so, wie easybank sie liefert: kein Creditor, Debtor =
    /// Kontoinhaber mit der eigenen IBAN.
    private func kartenzahlung(_ zweck: String, betrag: String = "-30,08") -> MerchantResolution {
        MerchantResolver.resolve(
            txID: nil,
            slotId: "test-slot",
            empfaenger: nil,
            absender: eigenerName,
            verwendungszweck: zweck,
            additionalInformation: nil,
            endToEndId: nil,
            direction: .from(amount: betrag),
            empfaengerIban: nil,
            absenderIban: eigeneIban
        )
    }

    // MARK: Der gemeldete Fall

    func test_kartenzahlung_zeigtNichtMehrDenKontoinhaber() {
        let ergebnis = kartenzahlung(
            "Bezahlung Karte MC/000025647LIDL DANKT 3157 D005 31.07. 16:57LIDL DANKT 517\\\\WIENER NEUSTA\\")
        XCTAssertFalse(ergebnis.effectiveMerchant.localizedCaseInsensitiveContains("Salmhofer"),
                       "der Kontoinhaber steht wieder in der Zeile")
        XCTAssertTrue(ergebnis.effectiveMerchant.localizedCaseInsensitiveContains("LIDL"),
                      "erwartet LIDL, bekommen: \(ergebnis.effectiveMerchant)")
    }

    /// Alle im Kundenexport vorkommenden Händler — 40 Kartenzahlungen, hier die
    /// unterschiedlichen Formate. Jede Zeile muss einen brauchbaren Namen ergeben.
    func test_alleHaendlerAusDemKundenexport() {
        let faelle: [(zweck: String, erwartet: String)] = [
            ("Bezahlung Karte MC/000025647LIDL DANKT 3157 D005 31.07. 16:57LIDL DANKT 517\\\\WIENER NEUSTA\\", "LIDL"),
            ("Bezahlung Karte MC/000025646INTERSPAR 2361 D006 31.07. 15:02INTERSPAR DANKT 8700\\\\WIENER N", "INTERSPAR"),
            ("Bezahlung Karte MC/000025643POST 2705 2362 D005 31.07. 14:20POST 2705\\\\WIENER NEUSTA\\2705", "POST"),
            ("Bezahlung Karte MC/000025642DM-FIL. A09A 3158 K005 31.07. 14:36DM-FIL. A09A\\\\WIENER NEUSTA\\27", "DM"),
            ("Bezahlung Karte MC/000025639POS 4350 D006 30.07. 16:32BILLA DANKT 0002220\\\\WIEN\\1220", "BILLA"),
            ("Bezahlung Karte MC/000025635POS 2900 K006 29.07. 16:33ANKERBROT\\\\WIEN\\1100 0", "ANKERBROT"),
            ("Bezahlung Karte MC/000025630POS 2901 D005 27.07. 17:04FRAMBURI\\\\WIEN\\1010 04", "FRAMBURI"),
            // MUELLER wird über die bestehende Alias-Tabelle zu „Müller" — genau so soll es sein.
            ("Bezahlung Karte MC/000025629POS 6954 D005 27.07. 18:38MUELLER WIEN 1-3 ECC\\\\WIEN\\110", "Müller"),
            ("Bezahlung Karte MC/000025626POS 2902 D005 26.07. 16:03DOENERMEISTER OPERA\\\\WIEN\\1010", "DOENERMEISTER"),
            ("Bezahlung Karte MC/000025616MCDONALDS210 2361 K006 26.07. 19:41MCDONALDS 210\\\\WIEN\\1040", "MCDONALDS"),
            ("Bezahlung Karte MC/000025615STADTHAUS 2362 D005 26.07. 16:27OBERLAA KONDITOREI\\\\WIEN\\1010", "OBERLAA"),
            ("Bezahlung Karte MC/000025619POS 3000 D005 25.07. 14:48STRANDBAR HERRMANN\\\\WIEN\\1030", "STRANDBAR"),
            ("Bezahlung Karte MC/000025603POS 3158 D005 24.07. 14:26INDITEX OSTERREICH\\\\WIEN\\1220", "INDITEX"),
            ("Bezahlung Karte MC/000025602POS 0645 D006 24.07. 12:40HM AT0116\\\\WIEN\\1220 0", "HM"),
            ("Bezahlung Karte MC/000025601STROECK 3119 2360 D006 24.07. 14:22STROCK 3119 DONAUZENTR\\\\WIEN\\1", "STROCK"),
        ]
        for fall in faelle {
            let ergebnis = kartenzahlung(fall.zweck)
            XCTAssertTrue(
                ergebnis.effectiveMerchant.localizedCaseInsensitiveContains(fall.erwartet),
                "erwartet \(fall.erwartet), bekommen \(ergebnis.effectiveMerchant)")
            XCTAssertFalse(ergebnis.effectiveMerchant.localizedCaseInsensitiveContains("Salmhofer"))
        }
    }

    /// Filialnummern gehören nicht in den Namen: Sonst wäre jede BILLA-Filiale ein
    /// eigener Händler — in der Liste unschön, in der Fixkosten-Gruppierung schädlich.
    func test_filialnummernWerdenAbgeschnitten() {
        let a = kartenzahlung("Bezahlung Karte MC/1POS 4350 D006 30.07. 16:32BILLA DANKT 0002220\\\\WIEN\\1220")
        let b = kartenzahlung("Bezahlung Karte MC/2POS 4350 K006 29.07. 16:38BILLA DANKT 0001008\\\\WIEN\\1100")
        XCTAssertEqual(a.effectiveMerchant, b.effectiveMerchant,
                       "zwei BILLA-Filialen müssen derselbe Händler sein")
    }

    func test_filialnummerEntfernen_lässtEchteNamenStehen() {
        XCTAssertEqual(MerchantResolver.filialnummerEntfernen("BILLA DANKT 0002220"), "BILLA DANKT")
        XCTAssertEqual(MerchantResolver.filialnummerEntfernen("MCDONALDS 210"), "MCDONALDS")
        // Kein Buchstabe mehr übrig → nicht weiter kürzen, sonst bliebe nichts.
        XCTAssertEqual(MerchantResolver.filialnummerEntfernen("1010"), "1010")
        // Einstellige Zahlen bleiben — „Klub 2" ist ein Name, keine Terminalnummer.
        XCTAssertEqual(MerchantResolver.filialnummerEntfernen("KLUB 2"), "KLUB 2")
    }

    // MARK: Was unverändert bleiben muss

    /// Die fünf echten Überweisungen aus dem Export haben eine korrekte Gegenseite.
    /// Der Fix darf funktionierende Fälle nicht anfassen.
    ///
    /// Verglichen wird ohne Rücksicht auf Groß-/Kleinschreibung: `cleanMerchantName`
    /// normalisiert Versalien seit jeher zu Kapitälchen („ENTUZIASM" → „Entuziasm").
    /// Das ist Bestandsverhalten und nicht Gegenstand dieser Änderung.
    func test_echteUeberweisungen_bleibenUnveraendert() {
        let faelle = [
            ("ENTUZIASM Kinobetriebs", "000483632758MPAY24 FE/000025648AT231200050163984901 ENTUZIASM Kinobetriebs GmbH"),
            ("Felix Salmhofer", "Abbuchung Echtzeitüberweisung FE/000025641BKAUATWWXXX AT461200010039957864 Felix Salmhofer Taschengeld"),
            ("Stadtgemeinde Gloggnitz", "1222-331089 FE/000025608SPNGAT21XXX AT132024103400000018 Stadtgemeinde Gloggnitz"),
        ]
        for (empfaenger, zweck) in faelle {
            let ergebnis = MerchantResolver.resolve(
                txID: nil, slotId: "test-slot",
                empfaenger: empfaenger, absender: eigenerName,
                verwendungszweck: zweck, additionalInformation: nil, endToEndId: nil,
                direction: .from(amount: "-75,00"),
                empfaengerIban: "AT461200010039957864", absenderIban: eigeneIban
            )
            XCTAssertEqual(ergebnis.effectiveMerchant.lowercased(), empfaenger.lowercased())
        }
    }

    /// Gegenprobe Einnahme: Beim Gehalt ist der Creditor die eigene Seite. Die
    /// Richtungslogik darf Eingänge nicht spiegelverkehrt kaputtmachen.
    func test_einnahme_nimmtDenAbsender() {
        let ergebnis = MerchantResolver.resolve(
            txID: nil, slotId: "test-slot",
            empfaenger: eigenerName, absender: "MM Oesterreich",
            verwendungszweck: "Lohn/Gehalt 00027453/202607", additionalInformation: nil, endToEndId: nil,
            direction: .from(amount: "2500,00"),
            empfaengerIban: eigeneIban, absenderIban: "AT741200000696104306"
        )
        XCTAssertEqual(ergebnis.effectiveMerchant.lowercased(), "mm oesterreich")
    }

    /// Ohne Betrag — im Kundenexport betrifft das „Lohn/Gehalt" und „ABRECHNUNG" —
    /// bleibt es beim Bestandsverhalten. Kein Absturz, keine stille Umdeutung.
    func test_ohneBetrag_bleibtBestandsverhalten() {
        XCTAssertEqual(MerchantResolver.TransactionDirection.from(amount: nil), .unknown)
        XCTAssertEqual(MerchantResolver.TransactionDirection.from(amount: ""), .unknown)
        XCTAssertEqual(MerchantResolver.TransactionDirection.from(amount: "0,00"), .unknown)
        XCTAssertEqual(MerchantResolver.TransactionDirection.from(amount: "-1,79"), .outgoing)
        XCTAssertEqual(MerchantResolver.TransactionDirection.from(amount: "150,00"), .incoming)

        let ergebnis = MerchantResolver.resolve(
            txID: nil, slotId: "test-slot",
            empfaenger: nil, absender: eigenerName,
            verwendungszweck: "ABRECHNUNG 2026/07", additionalInformation: nil, endToEndId: nil,
            direction: .unknown, empfaengerIban: nil, absenderIban: eigeneIban
        )
        XCTAssertEqual(ergebnis.effectiveMerchant, eigenerName,
                       "ohne Vorzeichen greift wie bisher der Absender")
    }

    // MARK: Eigenerkennung als Netz

    /// Leeres Register verändert nichts — das ist die Zusage, die den Einbau harmlos
    /// macht.
    func test_leeresRegister_unterdruecktNichts() {
        OwnPartyRegistry.leeren()
        XCTAssertFalse(OwnPartyRegistry.istEigeneSeite(name: eigenerName, iban: eigeneIban, slotId: "x"))
    }

    /// Mit registriertem Konto greift die IBAN — auch dann, wenn die Bank die eigene
    /// Seite fälschlich als Empfänger einträgt und das Vorzeichen sie nicht abfängt.
    func test_eigeneIban_wirdErkannt() {
        OwnPartyRegistry.registrieren(slotId: "test-slot", iban: eigeneIban, inhaber: eigenerName)
        XCTAssertTrue(OwnPartyRegistry.istEigeneSeite(name: "Wer auch immer", iban: eigeneIban, slotId: "test-slot"))
        XCTAssertTrue(OwnPartyRegistry.istEigeneSeite(name: eigenerName, iban: nil, slotId: "test-slot"))
        XCTAssertFalse(OwnPartyRegistry.istEigeneSeite(name: "LIDL", iban: "AT111111111111111111", slotId: "test-slot"))
    }

    /// Namen kommen von YAXI auf zwei Wörter gekürzt an — der Vergleich muss das
    /// aushalten, sonst findet er nie etwas.
    func test_nameVergleich_haeltDieZweiWortKuerzungAus() {
        OwnPartyRegistry.registrieren(slotId: "s", iban: nil, inhaber: "Stefan Salmhofer Dr.")
        XCTAssertTrue(OwnPartyRegistry.istEigeneSeite(name: "stefan salmhofer", iban: nil, slotId: "s"))
    }
}
