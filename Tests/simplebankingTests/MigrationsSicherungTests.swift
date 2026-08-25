import XCTest
import Foundation
import GRDB
@testable import simplebanking

// MARK: - Das Netz vor der Migration
//
// Migrationen laufen bei jedem Start und gehen nur vorwärts. Baut eine neue Fassung eine
// Spalte um oder schreibt Daten neu — wie zuletzt bei den Händlernamen —, ist eine
// beschädigte Historie nicht zurückzuholen. Diese Tests halten fest, dass die Kopie im
// richtigen Moment entsteht und im falschen unterbleibt.

final class MigrationsSicherungTests: XCTestCase {

    private var ordner: URL {
        (try! TransactionsDatabase.databaseURL())
            .deletingLastPathComponent()
            .appendingPathComponent("db-sicherungen")
    }

    override func setUp() {
        super.setUp()
        try? FileManager.default.removeItem(at: ordner)
        try? FileManager.default.removeItem(at: try! TransactionsDatabase.databaseURL())
    }

    private func sicherungen() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: ordner.path)) ?? [])
            .filter { $0.hasPrefix("transactions-vor-migration-") }
            .sorted()
    }

    /// Der Erststart darf keine Sicherung erzeugen — eine leere Datenbank ist nichts wert,
    /// und ein Ordner voller Nullstände verdeckt die echten.
    func test_ersterStartLegtNichtsAn() throws {
        try TransactionsDatabase.migrate()
        XCTAssertTrue(sicherungen().isEmpty,
                      "eine frisch angelegte Datenbank braucht kein Netz")
    }

    /// Ein zweiter Start ohne neue Migration ebenfalls nicht — sonst liefe bei jedem
    /// Programmstart eine Kopie mit.
    func test_ohneOffeneMigrationKeineSicherung() throws {
        try TransactionsDatabase.migrate()
        try TransactionsDatabase.migrate()
        try TransactionsDatabase.migrate()
        XCTAssertTrue(sicherungen().isEmpty,
                      "ohne ausstehende Migration gibt es nichts abzusichern")
    }

    /// Und der Fall, für den das Ganze gebaut ist: Es steht eine Migration an, die
    /// Datenbank hat Inhalt — dann wird vorher kopiert.
    func test_offeneMigrationMitDatenLegtSicherungAn() throws {
        try TransactionsDatabase.migrate()

        // Eine angewandte Migration entfernen, damit wieder eine offen ist.
        let queue = try TransactionsDatabase.makeQueue()
        try queue.write { db in
            try db.execute(sql: "DELETE FROM grdb_migrations WHERE identifier = (SELECT identifier FROM grdb_migrations ORDER BY identifier DESC LIMIT 1)")
        }

        try? TransactionsDatabase.migrate()
        XCTAssertEqual(sicherungen().count, 1, "vor der Migration muss eine Kopie liegen")

        // Die Kopie muss lesbar sein — eine kaputte Sicherung wäre schlimmer als keine,
        // weil man sich im Ernstfall auf sie verlässt.
        let kopie = ordner.appendingPathComponent(sicherungen()[0])
        let tabellen = try DatabaseQueue(path: kopie.path).read { db in
            try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type='table'")
        }
        XCTAssertTrue(tabellen.contains("transactions"),
                      "die Kopie muss das Schema enthalten, nicht nur eine leere Datei")
    }

    func test_esWerdenNichtBeliebigVieleAufbewahrt() {
        XCTAssertEqual(TransactionsDatabase.migrationsSicherungen, 3)
    }

}
