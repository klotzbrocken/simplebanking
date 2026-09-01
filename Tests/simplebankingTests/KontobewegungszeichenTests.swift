import XCTest
@testable import simplebanking

// MARK: - Bewegungszeichen in der Menüleiste
//
// Das Zeichen ist ein Hinweis, kein Bericht: genau eins, ohne Betrag und ohne Namen.
// Die Regeln, die dabei leicht kippen, sind der Vorrang des aktiven Kontos und der
// Unified-Mode, in dem es gar kein „anderes Konto" gibt.

final class KontobewegungszeichenTests: XCTestCase {

    private let aktiv = "slot-a"
    private let fremd = "slot-b"

    /// Nichts gilt als gesehen.
    private func nieHingeschaut(_ _: String) -> String { "" }

    private func stand(_ signatur: String, eingang: Bool, am zeitpunkt: String = "2026-08-30")
        -> Bewegungsstand {
        Bewegungsstand(signatur: signatur, istEingang: eingang, zeitpunkt: zeitpunkt)
    }

    func test_eingangAufAktivemKonto() {
        let z = Bewegungszeichenrechner.zeichen(
            stand: [aktiv: stand("sig1", eingang: true)],
            aktiverSlot: aktiv, gesehen: nieHingeschaut)
        XCTAssertEqual(z, .eingang)
    }

    func test_abgangAufAktivemKonto() {
        let z = Bewegungszeichenrechner.zeichen(
            stand: [aktiv: stand("sig1", eingang: false)],
            aktiverSlot: aktiv, gesehen: nieHingeschaut)
        XCTAssertEqual(z, .abgang)
    }

    func test_nurFremdesKontoZeigtKreis() {
        let z = Bewegungszeichenrechner.zeichen(
            stand: [fremd: stand("sig1", eingang: true)],
            aktiverSlot: aktiv, gesehen: nieHingeschaut)
        XCTAssertEqual(z, .fremdesKonto)
    }

    /// Kern der Kollisionsregel: liegt auf beiden etwas, gewinnt das aktive Konto.
    /// Sonst verschwiegen zwei gleichzeitige Bewegungen die für dich wichtigere.
    func test_aktivesKontoSchlaegtFremdes() {
        let z = Bewegungszeichenrechner.zeichen(
            stand: [aktiv: stand("sig1", eingang: false),
                    fremd: stand("sig2", eingang: true)],
            aktiverSlot: aktiv, gesehen: nieHingeschaut)
        XCTAssertEqual(z, .abgang)
    }

    func test_allesGesehenZeigtNichts() {
        let z = Bewegungszeichenrechner.zeichen(
            stand: [aktiv: stand("sig1", eingang: true),
                    fremd: stand("sig2", eingang: false)],
            aktiverSlot: aktiv,
            gesehen: { $0 == self.aktiv ? "sig1" : "sig2" })
        XCTAssertNil(z)
    }

    /// Negativkontrolle zum vorigen Test: Wäre die Gesehen-Prüfung wirkungslos,
    /// bliebe der Test oben auch bei falscher Umsetzung grün.
    func test_nurEinesGesehenZeigtWeiterhinDasAndere() {
        let z = Bewegungszeichenrechner.zeichen(
            stand: [aktiv: stand("sig1", eingang: true),
                    fremd: stand("sig2", eingang: false)],
            aktiverSlot: aktiv,
            gesehen: { $0 == self.aktiv ? "sig1" : "" })
        XCTAssertEqual(z, .fremdesKonto)
    }

    /// Frisch gestartete App: `latestTxSigBySlot` ist leer, bis der erste Abruf
    /// läuft. Ein leerer Eintrag darf kein Zeichen auslösen.
    func test_leereSignaturZaehltNicht() {
        let z = Bewegungszeichenrechner.zeichen(
            stand: [aktiv: stand("", eingang: true)],
            aktiverSlot: aktiv, gesehen: nieHingeschaut)
        XCTAssertNil(z)
    }

    // MARK: Unified-Mode

    /// Im Unified-Mode sind alle Konten sichtbar. Ein Kreis („anderes Konto")
    /// wäre dort schlicht gelogen — es gewinnt die jüngste Bewegung.
    func test_unifiedZeigtNieKreis() {
        let z = Bewegungszeichenrechner.zeichen(
            stand: [fremd: stand("sig1", eingang: true, am: "2026-08-30")],
            aktiverSlot: aktiv, alleAktiv: true, gesehen: nieHingeschaut)
        XCTAssertEqual(z, .eingang)
    }

    func test_unifiedJuengsteGewinnt() {
        let z = Bewegungszeichenrechner.zeichen(
            stand: [aktiv: stand("sig1", eingang: true, am: "2026-08-28"),
                    fremd: stand("sig2", eingang: false, am: "2026-08-30")],
            aktiverSlot: aktiv, alleAktiv: true, gesehen: nieHingeschaut)
        XCTAssertEqual(z, .abgang, "Die jüngere Buchung liegt auf dem nicht-aktiven Konto")
    }

    /// Bei gleichem Datum darf nicht die zufällige Dictionary-Reihenfolge
    /// entscheiden — sonst flackerte das Zeichen zwischen zwei Abrufen,
    /// ohne dass eine neue Buchung eingetroffen wäre.
    func test_unifiedGleichstandIstStabil() {
        let eingabe: [String: Bewegungsstand] = [
            "slot-a": stand("sig1", eingang: true, am: "2026-08-30"),
            "slot-b": stand("sig2", eingang: false, am: "2026-08-30"),
            "slot-c": stand("sig3", eingang: false, am: "2026-08-30"),
        ]
        let ergebnisse = (0..<50).map { _ in
            Bewegungszeichenrechner.zeichen(stand: eingabe, aktiverSlot: "slot-b",
                                            alleAktiv: true, gesehen: nieHingeschaut)
        }
        XCTAssertEqual(Set(ergebnisse.map { $0?.rawValue ?? "-" }).count, 1,
                       "Das Zeichen muss bei unverändertem Zustand identisch bleiben")
        XCTAssertEqual(ergebnisse.first, .eingang, "slot-a gewinnt den Gleichstand")
    }

    func test_glyphenSindMonochromUndVerschieden() {
        let alle = [Kontobewegungszeichen.eingang, .abgang, .fremdesKonto].map { $0.glyph }
        XCTAssertEqual(Set(alle).count, 3)
        XCTAssertEqual(alle, ["▲", "▼", "●"])
    }
}

// MARK: - Saldodifferenz als Auslöser
//
// Das Zeichen hängt am Saldo, nicht am Buchungsabruf: Letzterer läuft nur mit
// eingeschaltetem „Umsätze automatisch laden", das ab Werk aus ist.

final class SaldobewegungTests: XCTestCase {

    /// Der wichtigste Fall: Ohne Vorwert darf nichts gemeldet werden, sonst
    /// begrüßte eine frische Installation den Nutzer sofort mit einem Pfeil.
    func test_ersterSaldoIstKeineBewegung() {
        XCTAssertNil(Saldobewegung.richtung(vorher: nil, jetzt: 1234.56))
    }

    func test_unveraenderterSaldoIstKeineBewegung() {
        XCTAssertNil(Saldobewegung.richtung(vorher: 1234.56, jetzt: 1234.56))
    }

    /// Salden kommen als Fließkommazahl; ein Rundungsrest darf kein Zeichen setzen.
    func test_rundungsrestZaehltNicht() {
        XCTAssertNil(Saldobewegung.richtung(vorher: 1234.56, jetzt: 1234.5601))
    }

    func test_einCentMehrIstEingang() {
        XCTAssertEqual(Saldobewegung.richtung(vorher: 1234.56, jetzt: 1234.57), true)
    }

    func test_wenigerIstAbgang() {
        XCTAssertEqual(Saldobewegung.richtung(vorher: 1234.56, jetzt: 1200.00), false)
    }

    /// Negativer Saldo bleibt negativ, wird aber kleiner → das ist ein Abgang.
    func test_imDispoWeiterInsMinusIstAbgang() {
        XCTAssertEqual(Saldobewegung.richtung(vorher: -100.00, jetzt: -150.00), false)
    }
}
