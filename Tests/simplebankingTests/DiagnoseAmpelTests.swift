import XCTest
@testable import simplebanking

// MARK: - Die Ampel der Bank-Diagnose
//
// Gemeldet am 04.08.2026: „Sparkasse wird grün gezeigt", obwohl der Umsatzabruf auf eine
// Freigabe wartete. Die Zeile las nur `balance` — und der Saldo kam durch. Ein grünes
// Häkchen neben einer Bank, bei der die Hälfte scheitert, ist schlimmer als gar keine
// Anzeige: Es beendet die Fehlersuche an der falschen Stelle.

final class DiagnoseAmpelTests: XCTestCase {

    private typealias Ergebnis = DiagnosticSession.ProbeResult

    private func probe(_ saldo: Ergebnis, _ umsaetze: Ergebnis) -> DiagnosticSession.SlotProbe {
        .init(slotId: "s", bankName: "Sparkasse Siegen", ibanPrefix: "DE085002",
              balance: saldo, transactions: umsaetze)
    }

    /// **Der gemeldete Fall.** Saldo grün, Umsätze rot → die Bank ist rot.
    func test_saldoOkAberUmsaetzeKaputt_istNichtGruen() {
        let p = probe(.ok(durationMs: 800), .failed(message: "consent expired", durationMs: 900))
        XCTAssertEqual(p.gesamt.glyph, "✗",
                       "eine Bank mit gescheitertem Umsatzabruf darf kein Häkchen bekommen")
    }

    /// Die Gegenrichtung zählt genauso — Saldo kaputt, Umsätze ok.
    func test_umgekehrt_ebenfallsRot() {
        let p = probe(.failed(message: "no connectionId yet", durationMs: 5), .ok(durationMs: 700))
        XCTAssertEqual(p.gesamt.glyph, "✗")
    }

    /// Nur wenn beides durchläuft, ist es grün. Sonst wäre die Anzeige wertlos.
    func test_beidesOk_istGruen() {
        XCTAssertEqual(probe(.ok(durationMs: 1), .ok(durationMs: 2)).gesamt.glyph, "✓")
    }

    /// Übersprungen ist nicht in Ordnung, aber auch kein Fehler — es steht dazwischen.
    /// Wichtig, damit „Slot momentan besetzt" nicht als Bankfehler gemeldet wird.
    func test_uebersprungenLiegtZwischenOkUndFehler() {
        XCTAssertEqual(probe(.ok(durationMs: 1), .skipped(reason: "besetzt")).gesamt.glyph, "—")
        XCTAssertEqual(probe(.skipped(reason: "besetzt"),
                             .failed(message: "x", durationMs: 1)).gesamt.glyph, "✗",
                       "ein echter Fehler schlägt ein Überspringen")
    }

    /// Das zusammengefasste Ergebnis muss die Begründung mitnehmen — sie steht im
    /// Bericht, den der Kunde verschickt.
    func test_begruendungGehtNichtVerloren() {
        let p = probe(.ok(durationMs: 800), .failed(message: "consent expired", durationMs: 900))
        guard case .failed(let text, _) = p.gesamt else { return XCTFail("\(p.gesamt)") }
        XCTAssertEqual(text, "consent expired")
    }
}
