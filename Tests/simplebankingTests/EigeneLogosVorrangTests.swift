import XCTest
@testable import simplebanking

/// Aus einem Audit, 29.09.2026: Ein laufender Logoabruf konnte ein eigenes Logo
/// überschreiben, das der Nutzer inzwischen gesetzt hatte.
///
/// Zwischen dem Start eines Abrufs und dem Ablegen des Ergebnisses liegen bis zu zwei
/// Netzrunden à 15 Sekunden. Geprüft wurde bis dahin nur einmal — vor dem Abruf, in
/// `preload`. Danach schrieb `uebernehmen` bedingungslos.
///
/// Dass es ein Versehen war und keine Absicht, zeigt `clearCache()`: Dort werden eigene
/// Logos ausdrücklich verschont. Diese Tests halten dieselbe Regel für den Netzweg fest.
///
/// Geprüft wird die Entscheidung, nicht der Dienst: `MerchantLogoService` hat einen
/// privaten `init` und existiert nur als `shared`, lässt sich also nicht aufbauen.
final class EigeneLogosVorrangTests: XCTestCase {

    func test_ohneEigenesLogo_darfDasNetzlogoRein() {
        XCTAssertTrue(MerchantLogoService.darfNetzlogoUebernehmen(key: "rewe", eigene: []))
        XCTAssertTrue(MerchantLogoService.darfNetzlogoUebernehmen(key: "rewe", eigene: ["dm", "edeka"]))
    }

    func test_mitEigenemLogo_bleibtDasNetzlogoDraussen() {
        XCTAssertFalse(MerchantLogoService.darfNetzlogoUebernehmen(key: "rewe", eigene: ["rewe"]))
    }

    /// Schlüssel werden überall kleingeschrieben geführt (`setCustomLogo` schreibt
    /// `key.lowercased()`). Käme der Abruf mit anderer Schreibweise zurück, dürfte er
    /// nicht an der Regel vorbeirutschen.
    func test_schreibweiseEntscheidetNicht() {
        XCTAssertFalse(MerchantLogoService.darfNetzlogoUebernehmen(key: "REWE", eigene: ["rewe"]))
        XCTAssertFalse(MerchantLogoService.darfNetzlogoUebernehmen(key: "ReWe", eigene: ["rewe"]))
    }

    /// Gegenprobe zur Regel selbst: Sie darf nicht so weit greifen, dass gar keine
    /// Netzlogos mehr ankommen.
    func test_regelSperrtNichtAllesAus() {
        let eigene: Set<String> = ["rewe", "dm"]
        let durchgelassen = ["edeka", "aldi", "lidl"].filter {
            MerchantLogoService.darfNetzlogoUebernehmen(key: $0, eigene: eigene)
        }
        XCTAssertEqual(durchgelassen.count, 3)
    }
}
