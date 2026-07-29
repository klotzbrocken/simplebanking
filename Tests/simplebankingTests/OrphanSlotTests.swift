import XCTest
@testable import simplebanking

// MARK: - Verwaiste Konten aus abgebrochener Einrichtung
//
// Gemeldet am 29.07.: Ein Kunde brach den REWE-Login ab. Der Slot war da trotzdem
// angelegt — und weil er das einzige Konto war, ließ er sich weder entfernen noch durch
// ein vollständiges Zurücksetzen loswerden. Drei getrennte Ursachen, hier einzeln
// festgehalten.

@MainActor
final class OrphanSlotTests: XCTestCase {

    private var store: MultibankingStore { MultibankingStore.shared }
    private var gesicherteSlots: [BankSlot] = []

    override func setUp() async throws {
        try await super.setUp()
        gesicherteSlots = store.slots
    }

    override func tearDown() async throws {
        // Ausgangszustand wiederherstellen — die Tests arbeiten am echten Singleton.
        store.replaceAllSlotsForTesting(gesicherteSlots)
        try await super.tearDown()
    }

    // MARK: Zurücksetzen

    /// `performSecurityReset` löscht die UserDefaults-Domain, die Liste lebt aber
    /// zusätzlich im Speicher und schrieb sich beim nächsten `save()` zurück.
    func test_removeAllSlots_leertDieListe() {
        store.replaceAllSlotsForTesting([
            BankSlot.makeNew(iban: "DE02120300000000202051", displayName: "Testbank", logoId: nil),
            BankSlot.makeREWE(),
        ])
        XCTAssertEqual(store.slots.count, 2)

        store.removeAllSlots()

        XCTAssertTrue(store.slots.isEmpty)
        XCTAssertEqual(store.activeIndex, 0)
    }

    /// Nach dem Leeren darf nichts mehr zurückkommen — auch nicht über den
    /// nachgelagerten `save()`/`load()`-Weg, der den Fehler überhaupt erst erzeugte.
    func test_removeAllSlots_ueberlebtEinenNeuenLadevorgang() {
        store.replaceAllSlotsForTesting([BankSlot.makeREWE()])
        store.removeAllSlots()
        store.reloadFromDiskForTesting()
        XCTAssertTrue(store.slots.isEmpty, "Slot kam nach dem Zurücksetzen zurück")
    }

    // MARK: Letztes Konto entfernen

    /// Der Entfernen-Knopf war bei genau einem Konto gesperrt. Wer nur eines hatte —
    /// etwa den verwaisten REWE-Slot — saß darauf fest. Der Store muss das können.
    func test_letztesKonto_laesstSichEntfernen() {
        let einziger = BankSlot.makeREWE()
        store.replaceAllSlotsForTesting([einziger])

        store.removeSlot(id: einziger.id)

        XCTAssertTrue(store.slots.isEmpty)
    }

    /// Ohne Konten muss die App im selben Zustand stehen wie vor der ersten
    /// Einrichtung — kein Zugriff ins Leere.
    func test_ohneKonten_gibtEsKeinAktivesKonto() {
        store.replaceAllSlotsForTesting([])
        XCTAssertNil(store.activeSlot)
        XCTAssertEqual(store.realSlotCount, 0)
    }
}
