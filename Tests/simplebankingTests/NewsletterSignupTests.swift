import XCTest
@testable import simplebanking

// MARK: - Update-Liste
//
// Der Eintrag in die E-Mail-Liste ist der einzige ausgehende Aufruf der App, der eine
// Adresse des Nutzers verschickt — in einer Banking-App, deren Versprechen lautet, dass
// die Daten lokal bleiben. Die Zusage „nur deine Adresse, keine Kontodaten" steht im
// Fenster; hier wird sie geprüft, statt nur behauptet.

final class NewsletterSignupTests: XCTestCase {

    // MARK: Was hinausgeht

    /// Der eigentliche Test dieser Datei: Der Rumpf trägt genau drei Felder. Kommt je
    /// ein viertes dazu, muss das eine bewusste Entscheidung sein und hier auftauchen.
    func test_rumpfTraegtNurAdresseHerkunftUndVersion() {
        let body = NewsletterSignup.requestBody(email: "a@b.de", source: "settings", version: "2.0.1")
        XCTAssertEqual(Set(body.keys), ["email", "source", "version"],
                       "Neues Feld im Formular? Dann gehört es hier begründet.")
        XCTAssertEqual(body["email"], "a@b.de")
        XCTAssertEqual(body["source"], "settings")
        XCTAssertEqual(body["version"], "2.0.1")
    }

    /// Kein Feld darf versehentlich etwas aus dem Bankkontext tragen.
    func test_rumpfEnthaeltNichtsAusDemKontokontext() {
        let body = NewsletterSignup.requestBody(email: "a@b.de", source: "whatsnew-2.0.1", version: "2.0.1")
        let alles = body.values.joined(separator: " ").lowercased()
        for verboten in ["iban", "de89", "saldo", "balance", "konto", "slot", "token"] {
            XCTAssertFalse(alles.contains(verboten), "\(verboten) im Formular-Rumpf")
        }
    }

    /// Führende und folgende Leerzeichen entstehen beim Einfügen aus der Zwischenablage
    /// ständig — sie dürfen nicht mitgeschickt werden.
    func test_adresseWirdBeschnitten() {
        let body = NewsletterSignup.requestBody(email: "  a@b.de \n", source: "s", version: "v")
        XCTAssertEqual(body["email"], "a@b.de")
    }

    // MARK: Adressprüfung

    /// Bewusst großzügig — die App darf keine gültige Adresse abweisen, nur weil ihr
    /// Muster enger ist als der Standard.
    func test_gueltigeAdressenWerdenAngenommen() {
        for adresse in [
            "a@b.de",
            "maik.klotz@gmail.com",
            "vorname+tag@sub.domain.co.uk",
            "ümlaut@bäckerei.de",
            "a_b-c@example.museum",
            "  mit@leerzeichen.de  ",
        ] {
            XCTAssertTrue(NewsletterSignup.isValidEmail(adresse), "abgewiesen: \(adresse)")
        }
    }

    func test_offensichtlicheTippfehlerWerdenAbgewiesen() {
        for adresse in [
            "",
            "   ",
            "ohne-at.de",
            "@keindomain.de",
            "zwei@@at.de",
            "kein@punkt",
            "punkt@ganz.a",          // Top-Level zu kurz
            "leer@zeichen .de",
            "a@.de",                 // Punkt direkt am Anfang der Domain
        ] {
            XCTAssertFalse(NewsletterSignup.isValidEmail(adresse), "durchgelassen: \(adresse)")
        }
    }

    /// Eine unsinnig lange Eingabe soll gar nicht erst losgeschickt werden.
    func test_ueberlangeAdresseWirdAbgewiesen() {
        let lang = String(repeating: "a", count: 250) + "@example.de"
        XCTAssertFalse(NewsletterSignup.isValidEmail(lang))
    }

    // MARK: Absenden

    /// Ohne gültige Adresse darf kein Netzaufruf entstehen — der Fehler kommt sofort
    /// und ohne Umweg zurück.
    func test_ungueltigeAdresseWirdNichtVerschickt() async {
        let ergebnis = await NewsletterSignup.subscribe(email: "kein-at", source: "test")
        guard case .failure(let fehler) = ergebnis else {
            return XCTFail("hätte scheitern müssen")
        }
        XCTAssertEqual(fehler, .ungueltigeAdresse)
        XCTAssertNotNil(fehler.errorDescription)
    }

    /// Jeder Fehlerfall braucht einen Satz, den man einem Nutzer zeigen kann.
    func test_jederFehlerHatEinenLesbarenText() {
        for fehler: NewsletterSignup.SignupError in [.ungueltigeAdresse, .abgelehnt(status: 500), .netz] {
            XCTAssertFalse(fehler.errorDescription?.isEmpty ?? true, "\(fehler) ohne Text")
        }
    }

    // MARK: Endpunkt

    /// Derselbe Endpunkt wie auf der Website (`WaitlistCTA.tsx`) — beide Wege sollen in
    /// derselben Liste landen.
    func test_endpunktIstDerDerWebsite() {
        XCTAssertEqual(NewsletterSignup.endpoint.absoluteString,
                       "https://formspree.io/f/mreazlnb")
    }
}
