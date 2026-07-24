import XCTest
@testable import simplebanking

// MARK: - Erkennung von Zugangsdaten-Fehlern
//
// Diese Klassifikation entscheidet seit dem Sperrschutz, ob der automatische
// Abruf gestoppt wird. Beide Richtungen kosten etwas:
//   • nicht erkannt → der Timer probiert die falsche PIN weiter, bis die Bank sperrt
//   • falsch erkannt → der Auto-Sync stoppt ohne Grund
// Deshalb hier beide Seiten explizit abgesichert.

final class CredentialErrorDetectionTests: XCTestCase {

    func test_realBankMessages_areDetected() {
        let messages = [
            "PIN ist falsch",
            "Die eingegebene PIN wurde nicht akzeptiert.",
            "Passwort oder Anmeldename ungültig",
            "Ihr Passwortfehler-Zähler wurde erhöht",
            "Wrong credentials supplied",
            "Unauthorized",
            "Legitimationsdaten konnten nicht geprüft werden",
            "Zugangsdaten abgelehnt",
        ]
        for m in messages {
            XCTAssertTrue(AppDelegate.isLikelyCredentialError(m), "nicht erkannt: \(m)")
        }
    }

    /// Regression: kurze Tokens dürfen nicht mitten im Wort zünden — sonst stoppt
    /// ein banaler Netzwerkfehler den automatischen Abruf.
    func test_unrelatedErrors_doNotTriggerLockProtection() {
        let messages = [
            "Timeout while mapping the response",
            "Shipping address could not be resolved",
            "HTTP 502 Bad Gateway",
            "Fehlender Dialogkontext",
            "Die Verbindung wurde unterbrochen",
            "Keine Umsatzdaten verfügbar.",
        ]
        for m in messages {
            XCTAssertFalse(AppDelegate.isLikelyCredentialError(m), "Fehlalarm: \(m)")
        }
    }

    func test_emptyMessage() {
        XCTAssertFalse(AppDelegate.isLikelyCredentialError(""))
    }
}

// MARK: - WordMatch

final class WordMatchTests: XCTestCase {

    func test_asWord_boundaries() {
        XCTAssertTrue(WordMatch.asWord("pin ist falsch", "pin"))
        XCTAssertTrue(WordMatch.asWord("falsche pin!", "pin"))
        XCTAssertFalse(WordMatch.asWord("timeout while mapping", "pin"))
        XCTAssertFalse(WordMatch.asWord("shipping label", "pin"))
    }

    func test_atWordStart_allowsCompounds() {
        XCTAssertTrue(WordMatch.atWordStart("passwortfehler", "passwort"))
        XCTAssertFalse(WordMatch.atWordStart("meinpasswort", "passwort"))
    }

    func test_containsAnyWord() {
        XCTAssertTrue(WordMatch.containsAnyWord("access unauthorized", ["pin", "unauthorized"]))
        XCTAssertFalse(WordMatch.containsAnyWord("access granted", ["pin", "unauthorized"]))
    }

    func test_punctuationEdgedNeedle() {
        XCTAssertTrue(WordMatch.asWord("rtl+premium", "rtl+"))
        XCTAssertTrue(WordMatch.asWord("e.on energie", "e.on"))
    }

    func test_emptyNeedle() {
        XCTAssertFalse(WordMatch.asWord("egal", ""))
        XCTAssertFalse(WordMatch.atWordStart("egal", ""))
    }
}
