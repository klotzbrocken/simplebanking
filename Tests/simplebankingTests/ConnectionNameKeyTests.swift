import XCTest
@testable import simplebanking

// MARK: - Anzeigename der Bank überlebt die Einrichtung
//
// Beim Ersteinrichten existiert noch kein Slot, dessen `displayName` man fragen könnte —
// das TAN-Panel hieß deshalb nur „Bank", obwohl der Name aus der Banksuche längst
// bekannt war. Er wird jetzt neben connectionId und Credential-Modell abgelegt.
//
// Die Tests arbeiten auf erfundenen Slot-IDs und räumen hinter sich auf, damit sie
// keine echten Slots berühren.

final class ConnectionNameKeyTests: XCTestCase {

    private let quelle = "test-conn-name-src"
    private let ziel   = "test-conn-name-dst"

    private var alleSchluessel: [String] {
        [YaxiService.connectionNameKey(for: quelle),
         YaxiService.connectionNameKey(for: ziel),
         YaxiService.connectionIdKey(for: quelle),
         YaxiService.connectionIdKey(for: ziel)]
    }

    override func tearDown() {
        alleSchluessel.forEach { UserDefaults.standard.removeObject(forKey: $0) }
        super.tearDown()
    }

    /// Der Schlüssel muss pro Slot getrennt sein, sonst zeigte ein zweites Konto den
    /// Namen des ersten.
    func test_schluesselIstProSlotGetrennt() {
        XCTAssertNotEqual(YaxiService.connectionNameKey(for: quelle),
                          YaxiService.connectionNameKey(for: ziel))
        // Der Altbestand („legacy") bleibt ohne Suffix — wie bei allen anderen Keys.
        XCTAssertEqual(YaxiService.connectionNameKey(for: "legacy"),
                       "simplebanking.yaxi.connectionName")
    }

    /// „Konto hinzufügen" kopiert den Verbindungszustand auf den neuen Slot. Bliebe der
    /// Name zurück, hieße das Panel dort wieder „Bank".
    func test_nameWirdAufDenNeuenSlotKopiert() {
        let d = UserDefaults.standard
        d.set("connection-123", forKey: YaxiService.connectionIdKey(for: quelle))
        d.set("UniCredit Bank - HypoVereinsbank", forKey: YaxiService.connectionNameKey(for: quelle))

        YaxiService.copyConnectionStateKeys(fromSlotId: quelle, toSlotId: ziel)

        XCTAssertEqual(d.string(forKey: YaxiService.connectionNameKey(for: ziel)),
                       "UniCredit Bank - HypoVereinsbank")
    }

    /// Ohne Quelle darf nichts geschrieben werden — sonst überschriebe ein leerer
    /// Kopiervorgang einen bereits gesetzten Namen am Ziel.
    func test_leereQuelleUeberschreibtDasZielNicht() {
        let d = UserDefaults.standard
        d.set("Sparkasse Musterstadt", forKey: YaxiService.connectionNameKey(for: ziel))

        YaxiService.copyConnectionStateKeys(fromSlotId: quelle, toSlotId: ziel)

        XCTAssertEqual(d.string(forKey: YaxiService.connectionNameKey(for: ziel)),
                       "Sparkasse Musterstadt")
    }
}
