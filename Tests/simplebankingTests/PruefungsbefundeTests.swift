import XCTest
import AppKit
@testable import simplebanking

// MARK: - Welche Bank der TAN-Dialog nennt (P1)
//
// Gemeldet: Beim Hinzufügen eines Kontos konnte im TAN-Dialog die falsche Bank stehen —
// ein Kunde sah „REWE", während er die HypoVereinsbank einrichtete. Ursache war, dass der
// Name über den *aktiven* Slot ermittelt wurde; beim Hinzufügen ist das das bisherige
// Konto. Behoben, aber ungetestet — und genau dieser Fall kommt leicht zurück.

final class SCABanknameTests: XCTestCase {

    // MARK: Bestehendes Konto abrufen

    /// Der Nutzer hat sein Konto benannt. Diese Benennung muss gewinnen, sonst
    /// überschreibt der Katalogname der Bank sie bei jeder Freigabe.
    func test_slotnameGewinntBeimAbrufEinesKontos() {
        XCTAssertEqual(
            YaxiService.scaBankLabel(slotName: "Mein Girokonto",
                                     connectionName: "UniCredit Bank - HypoVereinsbank"),
            "Mein Girokonto")
    }

    // MARK: Konto hinzufügen — der gemeldete Fall

    /// Beim Hinzufügen ist der Slot noch nicht im Store, `slotName` also nil. Dann muss
    /// der Name der gerade eingerichteten Verbindung erscheinen — nicht der des Kontos,
    /// das gerade angezeigt wird.
    func test_beimHinzufuegen_gewinntDieNeueVerbindung() {
        XCTAssertEqual(
            YaxiService.scaBankLabel(slotName: nil,
                                     connectionName: "UniCredit Bank - HypoVereinsbank"),
            "UniCredit Bank - HypoVereinsbank")
    }

    /// Ein leerer Anzeigename ist genauso gut wie keiner — frisch angelegte Slots tragen
    /// `displayName: ""`, und der darf den Dialog nicht auf „Bank" zurückfallen lassen,
    /// solange die Verbindung einen Namen hat.
    func test_leererSlotnameZaehltNicht() {
        XCTAssertEqual(YaxiService.scaBankLabel(slotName: "", connectionName: "Sparkasse"), "Sparkasse")
        XCTAssertEqual(YaxiService.scaBankLabel(slotName: "   ", connectionName: "Sparkasse"), "Sparkasse")
    }

    func test_ohneBeideNamen_bleibtEinNeutralerPlatzhalter() {
        XCTAssertEqual(YaxiService.scaBankLabel(slotName: nil, connectionName: nil), "Bank")
        XCTAssertEqual(YaxiService.scaBankLabel(slotName: "", connectionName: "  "), "Bank")
    }

    /// Der vollständige gemeldete Ablauf: Konto A liegt im Store, die Einrichtung läuft
    /// unter der noch unsichtbaren ID B. Die Abfrage nach B darf A nicht finden — genau
    /// darauf beruhte der falsche Bankname.
    @MainActor
    func test_gemeldeterAblauf_kontoAAktivKontoBWirdEingerichtet() {
        let store = MultibankingStore.shared
        let gesichert = store.slots
        defer { store.replaceAllSlotsForTesting(gesichert) }

        let kontoA = BankSlot.makeNew(iban: "DE02120300000000202051", displayName: "Sparkasse", logoId: nil)
        store.replaceAllSlotsForTesting([kontoA])
        let idB = UUID().uuidString   // vorläufige ID der laufenden Einrichtung

        let nameAusStore = store.slots.first(where: { $0.id == idB })?.displayName
        XCTAssertNil(nameAusStore, "Die vorläufige ID darf im Store nicht auffindbar sein")
        XCTAssertEqual(
            YaxiService.scaBankLabel(slotName: nameAusStore,
                                     connectionName: "UniCredit Bank - HypoVereinsbank"),
            "UniCredit Bank - HypoVereinsbank",
            "Der Dialog nennt das falsche Konto")
    }
}

// MARK: - Freigabe-Weiterleitung: ein Fenster je Vorgang (P2)
//
// Die Drossel verglich früher die vollständige URL und lag damit in beide Richtungen
// falsch: bunq verlangt je Dienst eine eigene Freigabe und wurde verschluckt, während ein
// Wiederholungsversuch mit geändertem `state` ein zweites Fenster geöffnet hätte. Der
// Schlüssel ist jetzt der Vorgang (Konto + Ticket), nicht die Adresse.

final class RedirectCoordinatorTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    func test_ersterAufruf_darfOeffnen() async {
        let k = RedirectCoordinator()
        let erlaubt = await k.darfOeffnen(vorgang: "slot|1", jetzt: t0)
        XCTAssertTrue(erlaubt)
    }

    /// Derselbe Vorgang, egal wie oft gefragt wird — ein Fenster.
    func test_selberVorgang_oeffnetNurEinmal() async {
        let k = RedirectCoordinator()
        _ = await k.darfOeffnen(vorgang: "slot|1", jetzt: t0)
        let nachZweiSekunden = await k.darfOeffnen(vorgang: "slot|1", jetzt: t0.addingTimeInterval(2))
        let kurzVorFristende = await k.darfOeffnen(vorgang: "slot|1", jetzt: t0.addingTimeInterval(289))
        XCTAssertFalse(nachZweiSekunden)
        XCTAssertFalse(kurzVorFristende)
    }

    /// Der bunq-Fall: Salden sind ein eigener Dienstaufruf mit eigenem Ticket, also ein
    /// eigener Vorgang — auch wenn er Sekunden später kommt. Genau das wurde vorher
    /// verschluckt und ließ die Einrichtung in den Timeout laufen.
    func test_neuerDienstaufruf_bekommtEinEigenesFenster() async {
        let k = RedirectCoordinator()
        _ = await k.darfOeffnen(vorgang: "slot|konten", jetzt: t0)
        let saldenDarf = await k.darfOeffnen(vorgang: "slot|salden", jetzt: t0.addingTimeInterval(3))
        XCTAssertTrue(saldenDarf, "Der zweite Dienstaufruf wurde verschluckt — der bunq-Fehler")
    }

    /// Zwei Konten dürfen sich nicht gegenseitig blockieren.
    func test_zweiKonten_stoerenSichNicht() async {
        let k = RedirectCoordinator()
        _ = await k.darfOeffnen(vorgang: "slotA|1", jetzt: t0)
        let kontoBDarf = await k.darfOeffnen(vorgang: "slotB|1", jetzt: t0.addingTimeInterval(1))
        XCTAssertTrue(kontoBDarf)
    }

    /// Nach Ablauf der Frist ist ein neuer Versuch erlaubt — sonst käme jemand, dessen
    /// Freigabe abgelaufen ist, nie wieder an ein Fenster.
    func test_nachAblaufDerFrist_wiederErlaubt() async {
        let k = RedirectCoordinator()
        _ = await k.darfOeffnen(vorgang: "slot|1", jetzt: t0)
        let nachFrist = await k.darfOeffnen(vorgang: "slot|1", jetzt: t0.addingTimeInterval(291))
        XCTAssertTrue(nachFrist)
    }

    /// Der Vorgangsschlüssel darf das Ticket nicht im Klartext enthalten — es ist ein
    /// signiertes Token.
    func test_vorgangsschluessel_enthaeltDasTicketNichtImKlartext() {
        let ticket = "eyJhbGciOiJIUzI1NiJ9.geheim.signatur"
        let key = YaxiService.redirectVorgang(slotId: "legacy", ticket: ticket)
        XCTAssertFalse(key.contains("geheim"))
        XCTAssertFalse(key.contains(ticket))
        XCTAssertTrue(key.hasPrefix("legacy|"))
    }

    /// Verschiedene Tickets müssen verschiedene Schlüssel ergeben, sonst wäre die
    /// Unterscheidung wertlos.
    func test_verschiedeneTickets_ergebenVerschiedeneSchluessel() {
        let a = YaxiService.redirectVorgang(slotId: "s", ticket: "ticket-a")
        let b = YaxiService.redirectVorgang(slotId: "s", ticket: "ticket-b")
        XCTAssertNotEqual(a, b)
    }
}

// MARK: - Theme-Logos bleiben im Theme-Ordner (P2)
//
// `logo`/`logoDark` stehen in einer bearbeitbaren Datei, und Themes sind ausdrücklich zum
// Weitergeben gedacht. Ohne Prüfung genügte `logo=../../Pictures/privat.png`, um ein
// beliebiges Bild des Nutzers in die App zu holen — `appendingPathComponent` normalisiert
// nicht, das Dateisystem löst `..` erst beim Öffnen auf.

final class ThemeLogoPfadTests: XCTestCase {

    func test_einfacheDateinamenSindErlaubt() {
        for name in ["firma.png", "logo-hell.PNG", "marke.pdf", "zeichen.svg", "a.png"] {
            XCTAssertTrue(ThemeChrome.isValidLogoFileName(name), "abgewiesen: \(name)")
        }
    }

    /// Der gemeldete Angriffsweg.
    func test_verzeichnisaufstiegWirdAbgewiesen() {
        for name in [
            "../../Pictures/privat.png",
            "../geheim.png",
            "unter/ordner.png",
            "..",
            "ordner/../../x.png",
            "\\\\netz\\\\pfad.png",
        ] {
            XCTAssertFalse(ThemeChrome.isValidLogoFileName(name), "durchgelassen: \(name)")
        }
    }

    /// Absolute Pfade entkommen über `appendingPathComponent` zwar nicht, aber sie
    /// gehören trotzdem nicht in einen Dateinamen.
    func test_absolutePfadeWerdenAbgewiesen() {
        XCTAssertFalse(ThemeChrome.isValidLogoFileName("/etc/passwd"))
        XCTAssertFalse(ThemeChrome.isValidLogoFileName("/Users/maik/Pictures/foo.png"))
    }

    func test_verstecktesUndLeeresWirdAbgewiesen() {
        for name in ["", "   ", ".versteckt.png", ".png", String(repeating: "a", count: 300) + ".png"] {
            XCTAssertFalse(ThemeChrome.isValidLogoFileName(name), "durchgelassen: \(name.debugDescription)")
        }
    }

    /// Umgebender Leerraum wird abgeschnitten, nicht abgelehnt — ein versehentliches
    /// Leerzeichen in der `.cfg` soll kein Theme zerstören. Entscheidend ist, dass der
    /// **normalisierte** Name auch der ist, aus dem der Pfad gebaut wird: Prüfte man den
    /// beschnittenen Wert und öffnete den rohen, wäre die Prüfung wertlos.
    func test_leerraumWirdBeschnittenUndDerBeschnitteneWertVerwendet() {
        XCTAssertEqual(ThemeChrome.sanitizedLogoFileName("  logo.png \n"), "logo.png")
        XCTAssertEqual(ThemeChrome.sanitizedLogoFileName("logo.png"), "logo.png")
        XCTAssertNil(ThemeChrome.sanitizedLogoFileName("  ../weg.png  "))
    }

    /// Nur die in THEMES.md §4.1 zugesagten Formate — ein Theme soll ein Logo mitbringen,
    /// nicht beliebige Dateien öffnen lassen.
    func test_nurZugesagteFormate() {
        for name in ["logo.jpg", "logo.gif", "logo.txt", "logo.webp", "logo", "logo.pdf.txt"] {
            XCTAssertFalse(ThemeChrome.isValidLogoFileName(name), "durchgelassen: \(name)")
        }
        XCTAssertEqual(ThemeChrome.allowedLogoExtensions, ["png", "pdf", "svg"])
    }

    // MARK: Bildmaße

    /// Die Byte-Grenze sagt nichts über den Speicher beim Dekodieren. Ein winziges,
    /// stark komprimiertes Bild mit extremen Maßen muss vor dem Dekodieren auffallen.
    func test_normalesBildWirdAkzeptiert() throws {
        let url = try schreibePNG(breite: 512, hoehe: 512)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertTrue(ThemeChrome.logoDimensionsAreSane(at: url))
    }

    func test_uebergrossesBildWirdAbgelehnt() throws {
        let url = try schreibePNG(breite: ThemeChrome.maxLogoEdge + 1, hoehe: 8)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertFalse(ThemeChrome.logoDimensionsAreSane(at: url))
    }

    /// Keine lesbaren Maße (z. B. SVG) → durchlassen, dort greift die Byte-Grenze. Das
    /// ist eine bewusste Lücke; der Test hält sie fest, damit sie nicht für einen Fehler
    /// gehalten wird.
    func test_ohneLesbareMasseWirdDurchgelassen() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("logo-\(UUID().uuidString).svg")
        try #"<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 10 10"/>"#
            .write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertTrue(ThemeChrome.logoDimensionsAreSane(at: url))
    }

    /// Erzeugt ein echtes PNG mit den gewünschten Pixelmaßen (einfarbig, also winzig
    /// komprimiert — genau das Muster einer Bildbombe).
    private func schreibePNG(breite: Int, hoehe: Int) throws -> URL {
        let rep = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: breite, pixelsHigh: hoehe,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let daten = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("logo-\(UUID().uuidString).png")
        try daten.write(to: url)
        return url
    }
}
