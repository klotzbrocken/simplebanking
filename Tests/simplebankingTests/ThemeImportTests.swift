import XCTest
@testable import simplebanking

// MARK: - Theme-Import
//
// Ein Theme wird weitergegeben — als Datei, per Mail, aus einem Forum. Der Import muss
// deshalb davon ausgehen, dass das Archiv nicht wohlmeinend ist. Die Zusage lautet:
// Aus einem ZIP landet nur, was ein Theme ausmacht, und nur unter seinem Basisnamen im
// Theme-Ordner. Was im Archiv als Pfad steht, ist ohne Bedeutung.

final class ThemeImportTests: XCTestCase {

    // MARK: Was übernommen werden darf

    func test_nurThemeDateienWerdenUebernommen() {
        for gut in ["mein-theme.cfg", "wallpaper.png", "logo.pdf", "marke.svg", "GROSS.CFG"] {
            XCTAssertTrue(ThemeImport.istUebernehmbar(gut), gut)
        }
        for schlecht in ["boese.sh", "tool", "archiv.zip", "readme.txt", "bild.jpeg"] {
            XCTAssertFalse(ThemeImport.istUebernehmbar(schlecht), schlecht)
        }
    }

    /// Pfadanteile im Namen sind der klassische Zip-Slip. Selbst wenn `unzip` sie
    /// abfinge — verlassen wollen wir uns darauf nicht.
    func test_pfadangabenWerdenAbgelehnt() {
        for boese in ["../../../etc/passwd.cfg", "unterordner/theme.cfg", "/tmp/theme.cfg",
                      "..%2F..%2Fx.cfg/theme.cfg"] {
            XCTAssertFalse(ThemeImport.istUebernehmbar(boese), boese)
        }
    }

    /// macOS packt `.DS_Store` und Ressourcegabeln (`._bild.png`) in fast jedes Archiv.
    /// Die gehören nicht in den Theme-Ordner.
    func test_versteckteDateienBleibenDraussen() {
        XCTAssertFalse(ThemeImport.istUebernehmbar(".DS_Store"))
        XCTAssertFalse(ThemeImport.istUebernehmbar("._wallpaper.png"))
        XCTAssertFalse(ThemeImport.istUebernehmbar(".theme.cfg"))
    }

    // MARK: Reservierte Namen

    /// Diese Dateien überschreibt bzw. löscht der Start. Ein Import darunter wäre
    /// spätestens beim nächsten Start spurlos verschwunden — deshalb abweisen, statt
    /// ihn stillschweigend zu schreiben.
    func test_mitgelieferteUndAusgemusterteNamenSindTabu() {
        for name in ["default.cfg", "sunrise.cfg", "gameboy.cfg", "btx.cfg",
                     "ocean.cfg", "norton-commander.cfg"] {
            XCTAssertTrue(ThemeImport.istReserviert(name), name)
        }
        XCTAssertTrue(ThemeImport.istReserviert("BTX.CFG"), "Groß-/Kleinschreibung darf nicht durchrutschen")
        XCTAssertFalse(ThemeImport.istReserviert("mein-btx.cfg"))
        XCTAssertFalse(ThemeImport.istReserviert("futurama2.cfg"))
    }

    /// Die Liste darf nicht auseinanderlaufen: Sie leitet sich aus denselben Quellen ab,
    /// die `ensureThemeFiles` beim Start benutzt.
    func test_reservierteListeFolgtDenBuiltIns() {
        let reserviert = ThemeImport.reservierteDateinamen
        for datei in ThemeManager.builtInThemes.keys {
            XCTAssertTrue(reserviert.contains(datei.lowercased()), datei)
        }
        for datei in ThemeManager.retiredThemeFiles {
            XCTAssertTrue(reserviert.contains(datei.lowercased()), datei)
        }
    }

    // MARK: Echter Import aus einem ZIP

    /// Der Normalfall: Ein Ordner wurde gezippt, das Theme liegt also eine Ebene tief,
    /// samt Wallpaper — und daneben Müll, der nicht mitkommen darf.
    @MainActor
    func test_zipImport_ziehtFlachUndLaesstMuellDraussen() throws {
        let bau = FileManager.default.temporaryDirectory
            .appendingPathComponent("zipbau-\(UUID().uuidString)/Mein Theme")
        try FileManager.default.createDirectory(at: bau, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: bau.deletingLastPathComponent()) }

        let id = "importtest-\(UUID().uuidString.prefix(8))".lowercased()
        try "id=\(id)\nname=Importtest\nwallpaper=tapete.png\n"
            .write(to: bau.appendingPathComponent("theme.cfg"), atomically: true, encoding: .utf8)
        try Data([0x89, 0x50, 0x4E, 0x47])
            .write(to: bau.appendingPathComponent("tapete.png"))
        try "#!/bin/sh\necho boese\n"
            .write(to: bau.appendingPathComponent("install.sh"), atomically: true, encoding: .utf8)
        try "egal".write(to: bau.appendingPathComponent(".DS_Store"), atomically: true, encoding: .utf8)

        let zip = FileManager.default.temporaryDirectory
            .appendingPathComponent("theme-\(UUID().uuidString).zip")
        defer { try? FileManager.default.removeItem(at: zip) }
        let packer = Process()
        packer.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        packer.arguments = ["-r", "-q", zip.path, bau.lastPathComponent]
        packer.currentDirectoryURL = bau.deletingLastPathComponent()
        try packer.run(); packer.waitUntilExit()
        try XCTSkipUnless(packer.terminationStatus == 0, "zip nicht verfügbar")

        let ergebnis = try ThemeImport.importieren(von: zip)
        let ordner = URL(fileURLWithPath: ThemeManager.shared.themesDirectoryPath)
        addTeardownBlock {
            for datei in ergebnis.dateien {
                try? FileManager.default.removeItem(at: ordner.appendingPathComponent(datei))
            }
        }

        XCTAssertEqual(ergebnis.themeId, id)
        XCTAssertEqual(Set(ergebnis.dateien), ["theme.cfg", "tapete.png"],
                       "nur Theme-Dateien, flach, ohne Unterordner")
        XCTAssertTrue(FileManager.default.fileExists(atPath: ordner.appendingPathComponent("tapete.png").path),
                      "das Wallpaper muss neben der .cfg liegen, sonst findet es das Theme nie")
        XCTAssertFalse(FileManager.default.fileExists(atPath: ordner.appendingPathComponent("install.sh").path))
        XCTAssertTrue(ThemeManager.shared.availableThemes().contains { $0.id == id },
                      "nach dem Import muss das Theme ohne Neustart in der Auswahl stehen")
    }

    /// Ohne `.cfg` ist es kein Theme — dann darf auch kein Bild im Ordner landen.
    @MainActor
    func test_zipOhneCfg_wirdAbgelehnt() throws {
        let bau = FileManager.default.temporaryDirectory
            .appendingPathComponent("zipbau-\(UUID().uuidString)/nurbilder")
        try FileManager.default.createDirectory(at: bau, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: bau.deletingLastPathComponent()) }
        try Data([0x89, 0x50]).write(to: bau.appendingPathComponent("einsam.png"))

        let zip = FileManager.default.temporaryDirectory
            .appendingPathComponent("ohnecfg-\(UUID().uuidString).zip")
        defer { try? FileManager.default.removeItem(at: zip) }
        let packer = Process()
        packer.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        packer.arguments = ["-r", "-q", zip.path, bau.lastPathComponent]
        packer.currentDirectoryURL = bau.deletingLastPathComponent()
        try packer.run(); packer.waitUntilExit()
        try XCTSkipUnless(packer.terminationStatus == 0, "zip nicht verfügbar")

        XCTAssertThrowsError(try ThemeImport.importieren(von: zip)) { fehler in
            XCTAssertEqual(fehler as? ThemeImport.Fehler, .keineCfgGefunden)
        }
        let ordner = URL(fileURLWithPath: ThemeManager.shared.themesDirectoryPath)
        XCTAssertFalse(FileManager.default.fileExists(atPath: ordner.appendingPathComponent("einsam.png").path),
                       "ein abgebrochener Import darf nichts hinterlassen")
    }

    /// Belegte Kennung: erst abbrechen, damit der Aufrufer fragen kann.
    @MainActor
    func test_belegteKennung_brichtOhneUeberschreibenAb() throws {
        let cfg = FileManager.default.temporaryDirectory
            .appendingPathComponent("kollision-\(UUID().uuidString).cfg")
        defer { try? FileManager.default.removeItem(at: cfg) }
        try "id=btx\nname=Mein BTX\n".write(to: cfg, atomically: true, encoding: .utf8)

        XCTAssertThrowsError(try ThemeImport.importieren(von: cfg)) { fehler in
            guard case .idBereitsVergeben(let id, _)? = fehler as? ThemeImport.Fehler else {
                return XCTFail("falscher Fehler: \(fehler)")
            }
            XCTAssertEqual(id, "btx")
        }
    }

    /// Eine .cfg mit reserviertem Dateinamen wird abgewiesen, bevor irgendetwas kopiert
    /// wird — sonst überschriebe der nächste Start sie kommentarlos.
    @MainActor
    func test_reservierterDateiname_wirdAbgewiesen() throws {
        let ordner = FileManager.default.temporaryDirectory
            .appendingPathComponent("reserviert-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: ordner, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: ordner) }
        let cfg = ordner.appendingPathComponent("gameboy.cfg")
        try "id=mein-gameboy\nname=Mein Game Boy\n".write(to: cfg, atomically: true, encoding: .utf8)

        XCTAssertThrowsError(try ThemeImport.importieren(von: cfg)) { fehler in
            XCTAssertEqual(fehler as? ThemeImport.Fehler, .reservierterName("gameboy.cfg"))
        }
    }
}
