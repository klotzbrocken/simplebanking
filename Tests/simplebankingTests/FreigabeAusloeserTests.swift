import XCTest
@testable import simplebanking

/// Gemeldet am 01.10.2026: Ein Kunde mit abgelaufener ING-Zustimmung bekam mehrmals
/// täglich ungefragt die Anmeldeseite seiner Bank vorgesetzt — vom Zeitgeber alle vier
/// Stunden, dazu bei jedem Programmstart, jedem Entsperren und jedem Kontowechsel. Er
/// hielt es für Phishing, und das war keine übertriebene Sorge.
///
/// Die Regel seitdem: **Eine Bankseite öffnet sich nur, wenn der Nutzer unmittelbar davor
/// etwas angeklickt hat.** Diese Tests halten die beiden Hälften fest, die sich ohne
/// Bankverbindung prüfen lassen — die Vorgabe des Auslösers und der dauerhafte Vermerk am
/// Konto. Dass der Zeitgeber ihn beachtet, steht in `BalanceBar.autoRefresh`; dass die
/// Freigabe-Zweige ihn beachten, in `YaxiService.handleSCA`.
@MainActor
final class FreigabeAusloeserTests: XCTestCase {

    private var slotId: String = ""

    override func setUp() {
        super.setUp()
        slotId = "test-\(UUID().uuidString.prefix(8))"
    }

    override func tearDown() {
        BankSlotSettingsStore.delete(slotId: slotId)
        super.tearDown()
    }

    // MARK: - Die sichere Vorgabe

    /// Der wichtigste Test der Runde, und der unscheinbarste: Wer den Auslöser zu setzen
    /// vergisst, bekommt das zurückhaltende Verhalten. Stünde hier `.nutzerhandlung`,
    /// wäre jede künftig vergessene Aufrufstelle wieder ein ungefragt geöffneter Browser.
    func test_vorgabeIstHintergrund() {
        // Nachgebildet wie an den Signaturen: Der Vorgabewert ist Teil des Vertrags.
        func beispiel(ausloeser: YaxiService.Freigabeausloeser = .hintergrund) -> YaxiService.Freigabeausloeser {
            ausloeser
        }
        XCTAssertEqual(beispiel(), .hintergrund)
        XCTAssertEqual(beispiel(ausloeser: .nutzerhandlung), .nutzerhandlung)
    }

    // MARK: - Der Vermerk am Konto

    func test_neuesKonto_hatKeinenVermerk() {
        XCTAssertNil(BankSlotSettingsStore.load(slotId: slotId).freigabeFaelligSeit)
    }

    func test_merken_setztDasDatum() {
        AppDelegate.merkeFreigabeFaellig(slotId: slotId)
        XCTAssertNotNil(BankSlotSettingsStore.load(slotId: slotId).freigabeFaelligSeit)
    }

    /// „Seit wann" muss stimmen: Scheitern mehrere Abrufe nacheinander, darf das Datum
    /// nicht bei jedem Versuch nach vorn rutschen.
    func test_mehrfachesMerken_laesstDasDatumStehen() throws {
        AppDelegate.merkeFreigabeFaellig(slotId: slotId)
        let zuerst = try XCTUnwrap(BankSlotSettingsStore.load(slotId: slotId).freigabeFaelligSeit)

        AppDelegate.merkeFreigabeFaellig(slotId: slotId)
        AppDelegate.merkeFreigabeFaellig(slotId: slotId)

        let danach = try XCTUnwrap(BankSlotSettingsStore.load(slotId: slotId).freigabeFaelligSeit)
        XCTAssertEqual(zuerst.timeIntervalSince1970, danach.timeIntervalSince1970, accuracy: 0.001)
    }

    func test_erledigt_nimmtDenVermerkZurueck() {
        AppDelegate.merkeFreigabeFaellig(slotId: slotId)
        AppDelegate.freigabeErledigt(slotId: slotId)
        XCTAssertNil(BankSlotSettingsStore.load(slotId: slotId).freigabeFaelligSeit)
    }

    /// Der Punkt, an dem die bisherigen Sperren versagten: Sie lebten nur im Speicher und
    /// waren nach jedem Programmstart vergessen — weshalb schon der nächste Start wieder
    /// eine Seite öffnete. Dieser Vermerk liegt auf der Platte.
    func test_vermerkUeberstehtDenNeustart() throws {
        AppDelegate.merkeFreigabeFaellig(slotId: slotId)
        let gespeichert = try XCTUnwrap(BankSlotSettingsStore.load(slotId: slotId).freigabeFaelligSeit)

        // Frisch laden heißt hier: aus den Einstellungen neu dekodieren, wie beim Start.
        let nachNeustart = try XCTUnwrap(BankSlotSettingsStore.load(slotId: slotId).freigabeFaelligSeit)
        XCTAssertEqual(gespeichert.timeIntervalSince1970, nachNeustart.timeIntervalSince1970, accuracy: 0.001)
    }

    /// Gegenprobe: Der Vermerk gehört genau einem Konto, nicht allen. Die alte Bremse
    /// (`scaBackoffUntil`) war global — ein Konto mit ausstehender Freigabe hielt den
    /// Abruf aller anderen an.
    func test_vermerkGiltNurFuerSeinKonto() {
        let anderes = "test-\(UUID().uuidString.prefix(8))"
        defer { BankSlotSettingsStore.delete(slotId: anderes) }

        AppDelegate.merkeFreigabeFaellig(slotId: slotId)
        XCTAssertNotNil(BankSlotSettingsStore.load(slotId: slotId).freigabeFaelligSeit)
        XCTAssertNil(BankSlotSettingsStore.load(slotId: anderes).freigabeFaelligSeit,
                     "ein anderes Konto darf davon nichts mitbekommen")
    }
}
