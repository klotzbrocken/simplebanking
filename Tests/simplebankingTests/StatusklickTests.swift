import XCTest
import AppKit
@testable import simplebanking

// MARK: - Das Menüleisten-Symbol ohne Maus
//
// Gemeldet am 07.11.2026 von einem blinden Nutzer: Das Symbol ist mit VoiceOver
// erreichbar, aber nicht bedienbar. Ursache war der einleitende `guard` in
// `statusItemClicked` — ein Druck über die Bedienungshilfen trägt kein Mausereignis und
// fiel durch jeden Zweig.
//
// Dass VoiceOver die Action überhaupt erreicht, kann dieser Test nicht prüfen; dazu
// bräuchte es eine laufende VoiceOver-Sitzung. Was er festhält, ist die Regel, die
// danach entscheidet — und damit den Fehler, der nicht zurückkommen darf.

final class StatusklickTests: XCTestCase {

    func testEchteMausklicks() {
        XCTAssertTrue(Statusklick.istMausklick(.leftMouseUp))
        XCTAssertTrue(Statusklick.istMausklick(.rightMouseUp))
    }

    /// Der gemeldete Fall: kein Ereignis. Bis 2.1.0 endete die Behandlung hier.
    func testOhneEreignis() {
        XCTAssertFalse(Statusklick.istMausklick(nil))
    }

    /// Und jedes andere Ereignis, das zufällig gerade in `NSApp.currentEvent` steht.
    func testAndereEreignisseZaehlenNicht() {
        for typ: NSEvent.EventType in [.keyDown, .keyUp, .applicationDefined,
                                       .mouseMoved, .leftMouseDown, .rightMouseDown,
                                       .scrollWheel, .flagsChanged] {
            XCTAssertFalse(Statusklick.istMausklick(typ), "\(typ.rawValue) ist kein Klick")
        }
    }

    /// `.leftMouseDown` ist ausdrücklich kein Klick: Der Button schickt seine Action auf
    /// `.leftMouseUp` / `.rightMouseUp` (`sendAction(on:)`), und nur darauf stützt sich
    /// die Doppelklick-Erkennung.
    func testNurDieBeidenUpEreignisse() {
        XCTAssertFalse(Statusklick.istMausklick(.leftMouseDown))
        XCTAssertFalse(Statusklick.istMausklick(.otherMouseUp))
    }

    // MARK: - Zusagen am Quelltext

    /// Der alte `guard` darf nicht zurückkommen — er ist der gemeldete Fehler.
    func testDerAlteGuardIstWeg() throws {
        let quelle = try Quelltext.datei("BalanceBar.swift")
        let klick = try XCTUnwrap(rumpf(von: "@objc private func statusItemClicked() {",
                                        in: quelle))
        XCTAssertTrue(klick.contains("Statusklick.istMausklick"),
                      "statusItemClicked entscheidet nicht mehr über Statusklick")
        XCTAssertFalse(klick.hasPrefix("\n        guard let ev = NSApp.currentEvent else { return }"),
                       "der Abbruch ohne Mausereignis steht wieder als erste Anweisung")
    }

    /// Ein Titel ohne Beschriftung ist genau, wie VoiceOver „— €" vorlas. Alle Schreiber
    /// gehen darum über `setButtonTitle` oder `setzeLeistentitel`.
    func testKeinDirekterTitelSchreiber() throws {
        let quelle = try Quelltext.datei("BalanceBar.swift")
        XCTAssertFalse(quelle.contains("statusItem.button?.title ="),
                       "direkte Titelzuweisung umgeht den Vorlesetext")
    }

    /// Die drei Einträge, die den Klick-Funktionen entsprechen, müssen im Aufbau **und**
    /// in der Übersetzung stehen — fehlt das zweite, bleibt der Titel beim Sprachwechsel
    /// stehen.
    func testNeueMenueeintraegeSindUebersetzt() throws {
        let quelle = try Quelltext.datei("BalanceBar.swift")
        for tag in ["310", "320", "330"] {
            XCTAssertTrue(quelle.contains("\(tag)\n") || quelle.contains(".tag = \(tag)"),
                          "Tag \(tag) fehlt im Menüaufbau")
            XCTAssertTrue(quelle.contains("menu.item(withTag: \(tag))"),
                          "Tag \(tag) fehlt in applyLocalizedMenuTitles")
        }
    }

    /// Rumpf einer Funktion, von der Signatur bis zur passenden schließenden Klammer.
    private func rumpf(von signatur: String, in quelle: String) -> String? {
        guard let start = quelle.range(of: signatur) else { return nil }
        var tiefe = 0
        var index = quelle.index(before: start.upperBound)   // die öffnende Klammer
        while index < quelle.endIndex {
            if quelle[index] == "{" { tiefe += 1 }
            if quelle[index] == "}" {
                tiefe -= 1
                if tiefe == 0 {
                    return String(quelle[start.upperBound..<index])
                }
            }
            index = quelle.index(after: index)
        }
        return nil
    }
}
