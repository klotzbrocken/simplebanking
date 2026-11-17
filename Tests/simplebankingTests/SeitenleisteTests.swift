import XCTest
@testable import simplebanking

// MARK: - Die Rechenarbeit der Seitenleiste
//
// Sie steht in `Seitenleistenmasse.swift`, damit sie ohne Fenster prüfbar ist: Das
// Umsatzfenster ist ein `NSPanel` mit eigener Zoom-Umwidmung, und seine Breiten sind
// gesperrt (`minSize == maxSize`). Was hier falsch rechnet, fällt sonst erst beim
// Klicken auf.
final class SeitenleisteTests: XCTestCase {

    private let schmal = TransactionsPanel.narrowWidth   // 348
    private let breit  = TransactionsPanel.wideWidth     // 840

    // MARK: Vier Breiten, zwei unabhängige Knöpfe

    /// Der grüne Ampelknopf schaltet den Inhalt, der Seitenleisten-Knopf die Leiste.
    /// Jede der vier Lagen hat ihre eigene Breite, und die Leiste kostet überall
    /// dasselbe.
    func testVierBreiten() {
        XCTAssertEqual(Seitenleiste.fensterbreite(offen: false, breit: false), schmal)
        XCTAssertEqual(Seitenleiste.fensterbreite(offen: false, breit: true), breit)
        XCTAssertEqual(Seitenleiste.fensterbreite(offen: true, breit: false), schmal + Seitenleiste.breite)
        XCTAssertEqual(Seitenleiste.fensterbreite(offen: true, breit: true), breit + Seitenleiste.breite)
    }

    /// Die Leiste ändert die Inhaltsbreite nicht. Ohne das Herausrechnen hielte sich ein
    /// schmales Fenster mit Leiste (578) für breit, und der grüne Knopf schaltete in die
    /// falsche Richtung.
    func testInhaltsbreiteRechnetDieLeisteHeraus() {
        XCTAssertFalse(Seitenleiste.istBreit(fensterbreite: schmal, offen: false))
        XCTAssertTrue(Seitenleiste.istBreit(fensterbreite: breit, offen: false))
        XCTAssertFalse(Seitenleiste.istBreit(fensterbreite: schmal + Seitenleiste.breite, offen: true))
        XCTAssertTrue(Seitenleiste.istBreit(fensterbreite: breit + Seitenleiste.breite, offen: true))
    }

    /// Die Leiste gibt es nur im breiten Fenster. Schmal ist der Schnellblick, den ein
    /// Doppelklick auf das Menüleistensymbol öffnet; 230 pt Navigation davor ließen von
    /// der Liste zu wenig übrig. Der Knopf erscheint dort gar nicht erst, und der grüne
    /// Ampelknopf nimmt die Leiste mit, wenn er auf schmal schaltet.
    func testNurImBreitenFenster() {
        XCTAssertTrue(Seitenleiste.moeglich(breit: true))
        XCTAssertFalse(Seitenleiste.moeglich(breit: false))
    }

    /// Hin und zurück landet wieder bei der Ausgangsbreite.
    func testUmschaltenIstUmkehrbar() {
        for breitZustand in [false, true] {
            let zu = Seitenleiste.fensterbreite(offen: false, breit: breitZustand)
            let auf = Seitenleiste.fensterbreite(offen: true, breit: breitZustand)
            XCTAssertEqual(auf - zu, Seitenleiste.breite)
            XCTAssertEqual(
                Seitenleiste.fensterbreite(
                    offen: false,
                    breit: Seitenleiste.istBreit(fensterbreite: auf, offen: true)),
                zu)
        }
    }

    /// Im breiten Fenster darf gezogen werden, aber nicht unter die Vorgabe. Die
    /// Untergrenze ist genau die Breite, die der Zustand ohnehin hätte.
    func testMindestbreiteIstDieVorgabe() {
        XCTAssertEqual(Seitenleiste.fensterbreite(offen: false, breit: true), breit)
        XCTAssertEqual(Seitenleiste.fensterbreite(offen: true, breit: true), breit + Seitenleiste.breite)
        // Eine selbst gezogene Breite bleibt breit, auch deutlich über der Vorgabe.
        XCTAssertTrue(Seitenleiste.istBreit(fensterbreite: 1600, offen: false))
        XCTAssertTrue(Seitenleiste.istBreit(fensterbreite: 1600, offen: true))
    }

    // MARK: Wohin das Fenster wächst

    /// Nach links: Der Inhalt rechts behält seine Stelle, Saldo und Liste springen beim
    /// Einblenden nicht unter dem Zeiger weg.
    func testWaechstNachLinks() {
        let sichtbar = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let vorher = CGRect(x: 800, y: 100, width: schmal, height: 620)
        let nachher = Seitenleiste.rahmen(aktuell: vorher, sichtbar: sichtbar,
                                          zielbreite: schmal + Seitenleiste.breite)
        XCTAssertEqual(nachher.maxX, vorher.maxX, "die rechte Kante bleibt stehen")
        XCTAssertEqual(nachher.origin.x, vorher.origin.x - Seitenleiste.breite)
        XCTAssertEqual(nachher.height, vorher.height)
    }

    /// Am linken Bildschirmrand gibt es nichts mehr zu wachsen, also wächst es nach
    /// rechts. Sonst stünde das halbe Fenster neben dem Bildschirm.
    func testAmLinkenRandWaechstEsNachRechts() {
        let sichtbar = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let vorher = CGRect(x: 10, y: 100, width: schmal, height: 620)
        let nachher = Seitenleiste.rahmen(aktuell: vorher, sichtbar: sichtbar,
                                          zielbreite: schmal + Seitenleiste.breite)
        XCTAssertEqual(nachher.origin.x, sichtbar.minX)
        XCTAssertEqual(nachher.width, schmal + Seitenleiste.breite)
    }

    /// Passt es überhaupt nicht, klebt es am linken Rand und ragt rechts hinaus. Die
    /// Alternative wäre, es links hinausragen zu lassen, und dort sind die Knöpfe.
    func testZuSchmalerBildschirm() {
        let sichtbar = CGRect(x: 0, y: 0, width: 500, height: 800)
        let vorher = CGRect(x: 0, y: 0, width: schmal, height: 620)
        let nachher = Seitenleiste.rahmen(aktuell: vorher, sichtbar: sichtbar,
                                          zielbreite: breit + Seitenleiste.breite)
        XCTAssertEqual(nachher.origin.x, sichtbar.minX)
    }

    /// Ein Fenster auf dem rechten Bildschirm (negativer oder großer Ursprung) bleibt
    /// auf seinem Bildschirm.
    func testZweiterBildschirmRechts() {
        let sichtbar = CGRect(x: 1920, y: 0, width: 1920, height: 1080)
        let vorher = CGRect(x: 1930, y: 100, width: schmal, height: 620)
        let nachher = Seitenleiste.rahmen(aktuell: vorher, sichtbar: sichtbar,
                                          zielbreite: schmal + Seitenleiste.breite)
        XCTAssertEqual(nachher.origin.x, sichtbar.minX)
    }

    // MARK: Wo eine Auswertung erscheint

    func testOhneLeisteEigenesFenster() {
        for reiter in DashboardTab.allCases {
            XCTAssertEqual(
                Seitenleiste.auswertungsPlatz(seitenleisteOffen: false, ansicht: .auswertung(reiter)),
                .eigenesFenster(reiter))
        }
    }

    func testMitLeisteEingebettet() {
        for reiter in DashboardTab.allCases {
            XCTAssertEqual(
                Seitenleiste.auswertungsPlatz(seitenleisteOffen: true, ansicht: .auswertung(reiter)),
                .eingebettet(reiter))
        }
    }

    /// Umsätze sind keine Auswertung, in beiden Zuständen nicht.
    func testUmsaetzeHabenKeinenPlatz() {
        XCTAssertEqual(Seitenleiste.auswertungsPlatz(seitenleisteOffen: true, ansicht: .umsaetze), .keiner)
        XCTAssertEqual(Seitenleiste.auswertungsPlatz(seitenleisteOffen: false, ansicht: .umsaetze), .keiner)
    }

    /// Geld senden ist auch keine: Es hat kein zweites Zuhause im Dashboard-Fenster,
    /// sondern sein eigenes Überweisungsfenster.
    func testSendenIstKeineAuswertung() {
        for art in Sendeart.allCases {
            XCTAssertEqual(
                Seitenleiste.auswertungsPlatz(seitenleisteOffen: true, ansicht: .senden(art)),
                .keiner)
        }
    }

    /// Drei Einträge, drei Beschriftungen, drei Symbole. Ein Tippfehler im `switch`
    /// gäbe sonst zwei gleiche Zeilen in der Leiste.
    func testSendeartenSindUnterscheidbar() {
        XCTAssertEqual(Set(Sendeart.allCases.map(\.label)).count, Sendeart.allCases.count)
        XCTAssertEqual(Set(Sendeart.allCases.map(\.icon)).count, Sendeart.allCases.count)
    }
}
