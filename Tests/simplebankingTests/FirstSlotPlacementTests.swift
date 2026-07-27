import XCTest
@testable import simplebanking

// MARK: - Erstkonto anlegen, ohne vorhandene Slots zu zerstören
//
// Kundenmeldung: „Hab's neu aufgesetzt, erst REWE, dann amazon. Anschließend war
// REWE weg." Ursache war `replaceFirstSlot`, das schlicht `slots[0] = slot` machte —
// mit der stillschweigenden Annahme, an Index 0 stehe ein Platzhalter oder das
// Erstkonto. Wer vor der Bankeinrichtung einen eBon-Slot anlegte, hatte dort aber
// REWE stehen, und die Bankeinrichtung überschrieb ihn spurlos: kein Hinweis, kein
// Log, und die zugehörigen Bons blieben verwaist in der Datenbank liegen (dieser
// Pfad räumt nichts auf, anders als `removeSlot`).

final class FirstSlotPlacementTests: XCTestCase {

    private func bankSlot(id: String = "legacy", iban: String = "DE02120300000000202051") -> BankSlot {
        BankSlot(id: id, iban: iban, displayName: "Testbank", logoId: nil)
    }

    /// Der Fall aus der Meldung. War vor dem Fix rot.
    func test_eBonSlotsUeberlebenDieBankeinrichtung() {
        let rewe = BankSlot.makeREWE()
        let amazon = BankSlot.makeAmazon()
        let bank = bankSlot()

        let result = MultibankingStore.applyingFirstSlot(bank, to: [rewe, amazon])

        XCTAssertEqual(result.slots.count, 3, "Kein vorhandener Slot darf verschwinden")
        XCTAssertTrue(result.slots.contains { $0.id == rewe.id }, "REWE muss erhalten bleiben")
        XCTAssertTrue(result.slots.contains { $0.id == amazon.id }, "Amazon muss erhalten bleiben")
        XCTAssertEqual(result.slots[0].id, bank.id, "Das Erstkonto steht vorne")
        XCTAssertEqual(result.activeIndex, 0)
    }

    /// Der Normalfall: der Assistent läuft erneut und aktualisiert sein eigenes Konto.
    func test_bestehendesErstkontoWirdErsetzt_nichtDupliziert() {
        let alt = bankSlot(iban: "DE02120300000000202051")
        let neu = bankSlot(iban: "DE02100500000054540402")

        let result = MultibankingStore.applyingFirstSlot(neu, to: [alt])

        XCTAssertEqual(result.slots.count, 1, "Gleiche ID → ersetzen, nicht anhängen")
        XCTAssertEqual(result.slots[0].iban, "DE02100500000054540402")
        XCTAssertEqual(result.activeIndex, 0)
    }

    /// Wird das Erstkonto ersetzt, während eBon-Slots davor liegen, muss der Index auf
    /// das Erstkonto zeigen — nicht blind auf 0.
    func test_aktiverIndexZeigtAufDasErsetzteKonto() {
        let rewe = BankSlot.makeREWE()
        let bank = bankSlot()

        let result = MultibankingStore.applyingFirstSlot(bank, to: [rewe, bank])

        XCTAssertEqual(result.slots.count, 2)
        XCTAssertEqual(result.activeIndex, 1, "Das Erstkonto steht an Index 1, nicht an 0")
        XCTAssertEqual(result.slots[result.activeIndex].id, bank.id)
    }

    func test_leereListe_legtDasErstkontoAn() {
        let bank = bankSlot()

        let result = MultibankingStore.applyingFirstSlot(bank, to: [])

        XCTAssertEqual(result.slots.map(\.id), [bank.id])
        XCTAssertEqual(result.activeIndex, 0)
    }

    /// Gegenprobe zur Reihenfolge: ein zweiter eBon-Slot darf nicht nach vorne rutschen.
    func test_reihenfolgeDerBestehendenSlotsBleibt() {
        let rewe = BankSlot.makeREWE()
        let dm = BankSlot.makeDM()
        let amazon = BankSlot.makeAmazon()

        let result = MultibankingStore.applyingFirstSlot(bankSlot(), to: [rewe, dm, amazon])

        XCTAssertEqual(Array(result.slots.dropFirst()).map(\.id), [rewe.id, dm.id, amazon.id])
    }
}
