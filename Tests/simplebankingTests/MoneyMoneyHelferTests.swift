import XCTest
import MoneyMoneyForm
@testable import simplebanking

/// Die drei Zusagen des Importhelfers.
///
/// In der MoneyMoney-Datenbank liegen neben den Umsätzen `pins` (die Bank-PIN des
/// Nutzers) und `banks.privkey` (sein HBCI-Privatschlüssel). Kein Typ kann
/// verhindern, dass eine dieser Tabellen eines Tages mitgelesen wird — darum steht
/// die Zusage hier, geprüft am Quelltext selbst.
final class MoneyMoneyHelferTests: XCTestCase {

    /// Der Quelltext des Helfers **ohne Kommentare** — die Zusage gilt für den Code.
    /// Der Kopfkommentar der Datei nennt die verbotenen Aufrufe beim Namen, um sie
    /// zu verbieten; eine Suche über die Rohdatei schlägt daran fehl.
    private var helfer: String {
        get throws {
            Quelltext.ohneKommentare(try Quelltext.quelle("Sources/simplebanking-mmimport/main.swift"))
        }
    }

    /// Keine Vorprüfung mit `access(2)`.
    ///
    /// `isReadableFile` benutzt `access(2)`, und für den Container einer anderen App
    /// verweigert macOS das seit Sonoma **ohne zu fragen**. Die Rückfrage erscheint
    /// erst beim echten `open`. Eine solche Vorprüfung meldete deshalb am 13.11.2026
    /// „Datei nicht lesbar" über eine Datei, die der Nutzer im Finder vor sich sah —
    /// und verhinderte dabei genau den Dialog, der das Problem gelöst hätte.
    func testKeineVorpruefungMitAccess() throws {
        let quelle = try helfer
        XCTAssertFalse(quelle.contains("isReadableFile"),
                       "access(2) fragt nicht nach Zustimmung — sqlite3_open_v2 soll öffnen")
        XCTAssertTrue(quelle.contains("SQLITE_OPEN_READONLY"),
                      "Das echte Öffnen ist es, was die Rückfrage auslöst")
    }

    func testKeinSternchenInDerAbfrage() throws {
        // `SELECT *` würde jede Spalte mitnehmen, die MoneyMoney morgen dazulegt —
        // auch eine, die etwas enthält, das uns nichts angeht.
        XCTAssertFalse(try helfer.contains("SELECT *"))
        XCTAssertFalse(try helfer.lowercased().contains("select *"))
    }

    func testPinsUndBanksWerdenNieGeoeffnet() throws {
        let quelle = try helfer
        // Als Wortgrenze geprüft, damit `banks` nicht in `category_groups` o. ä.
        // false positive erzeugt: hier geht es um die Tabellennamen in SQL.
        XCTAssertFalse(quelle.contains("FROM pins"))
        XCTAssertFalse(quelle.contains("FROM banks"))
        XCTAssertFalse(quelle.contains("table_info(pins)"))
        XCTAssertFalse(quelle.contains("table_info(banks)"))
        XCTAssertFalse(quelle.contains("privkey"))
        XCTAssertFalse(quelle.contains("credential"))
    }

    func testKeineEntschluesselteKopie() throws {
        let quelle = try helfer
        // Eine entschlüsselte Kopie wäre die Bank-PIN im Klartext auf der Platte —
        // ein größerer Schaden als der Nutzen des gesamten Imports.
        XCTAssertFalse(quelle.contains("sqlcipher_export"))
        XCTAssertFalse(quelle.contains("ATTACH"))
        XCTAssertFalse(quelle.contains("VACUUM INTO"))
    }

    func testNurLesendGeoeffnet() throws {
        let quelle = try helfer
        XCTAssertTrue(quelle.contains("SQLITE_OPEN_READONLY"))
        XCTAssertFalse(quelle.contains("SQLITE_OPEN_READWRITE"))
        XCTAssertFalse(quelle.contains("SQLITE_OPEN_CREATE"))
    }

    func testKennwortKommtUeberStdinUndNichtAlsArgument() throws {
        let quelle = try helfer
        // Argumente stehen für jeden Prozess der Sitzung in `ps`.
        XCTAssertTrue(quelle.contains("standardInput") || quelle.contains("standardInput"))
        XCTAssertTrue(quelle.contains("FileHandle.standardInput"))
        let lesepfad = Quelltext.ohneKommentare(try Quelltext.datei("MoneyMoneyLesepfad.swift"))
        XCTAssertTrue(lesepfad.contains("eingabe.fileHandleForWriting.write"))
        XCTAssertFalse(lesepfad.contains("arguments = [datenbank.path, kennwort"))
    }

    func testDerHelferHaengtNichtAnGRDB() throws {
        // Zöge er GRDB mit, lägen SQLCipher und das System-SQLite — dieselben
        // `sqlite3_*`-Symbole — in einem Binary.
        XCTAssertFalse(try helfer.contains("import GRDB"))
        let paket = Quelltext.ohneKommentare(try Quelltext.quelle("Package.swift"))

        // Erst in den Zielbereich, dann zum Helfer: `name: "simplebanking-mmimport"`
        // steht auch oben im Produkt, und von dort bis `.testTarget` liegt der
        // GRDB-Block der App dazwischen — die Zusage wäre nie grün geworden.
        let zielbereich = Quelltext.abschnitt(paket, von: "\n    targets: [")
        XCTAssertFalse(zielbereich.isEmpty, "Zielbereich des Pakets nicht gefunden")
        let helferZiel = Quelltext.abschnitt(zielbereich,
                                             von: "name: \"simplebanking-mmimport\"",
                                             bis: ".testTarget")
        XCTAssertFalse(helferZiel.isEmpty, "Zielblock des Helfers nicht gefunden")
        XCTAssertFalse(helferZiel.contains("GRDB"))

        // Und das Testziel darf den Helfer nicht abhängen — sonst lägen SQLCipher
        // und das System-SQLite in einem Testbinary.
        let testZiel = Quelltext.abschnitt(paket, von: "name: \"simplebankingTests\"")
        XCTAssertFalse(testZiel.isEmpty, "Zielblock der Tests nicht gefunden")
        XCTAssertFalse(testZiel.contains("simplebanking-mmimport"))
    }

    func testJedeAbgefragteSpalteStehtInDerSchemapruefung() throws {
        // Der Fehler, der das hier ausgelöst hat: Die Abfrage auf `transactions` las
        // `name`, die Prüfliste kannte die Spalte nicht. Die Schemaprüfung ging damit
        // durch und erst die Abfrage scheiterte — der Nutzer las „konnte nicht gelesen
        // werden" statt „diese Fassung speichert anders", also genau die Meldung, die
        // die Prüfung abschaffen sollte. In der Messdatenbank gab es `name`, deshalb
        // fiel es nicht auf.
        let quelle = Quelltext.ohneKommentare(try helfer)
        for (tabelle, bekannt) in MoneyMoneyLeseregeln.benoetigteSpalten {
            // Den SELECT dieser Tabelle herausschneiden: von „SELECT" bis „FROM <tabelle>".
            guard let bereich = quelle.range(of: "FROM \(tabelle)") else {
                XCTFail("Keine Abfrage auf \(tabelle) gefunden"); continue
            }
            let davor = String(quelle[quelle.startIndex..<bereich.lowerBound])
            guard let selectAb = davor.range(of: "SELECT", options: .backwards) else {
                XCTFail("Kein SELECT vor FROM \(tabelle)"); continue
            }
            let spalten = davor[selectAb.upperBound...]
                .split(whereSeparator: { $0 == "," || $0.isWhitespace })
                .map(String.init)
                .filter { $0 != "rowid" && !$0.isEmpty }
            for spalte in spalten {
                XCTAssertTrue(bekannt.contains(spalte),
                              "\(tabelle).\(spalte) wird abgefragt, steht aber nicht in "
                              + "benoetigteSpalten — die Schemaprüfung übersieht sie")
            }
        }
    }

    func testDerHelferGehtNichtInsNetz() throws {
        // Diese Zusage kann NICHT aus den Entitlements kommen: Die App trägt kein
        // `com.apple.security.app-sandbox`, also gewährt `network.client` nichts
        // und sein Weglassen verbietet nichts. Eine eigene Entitlements-Datei
        // „ohne Netz" wäre eine Zusage, die sie nicht halten kann. Prüfbar ist sie
        // nur hier, am Quelltext.
        //
        // Warum es überhaupt zählt: Der Helfer hat die Bank-PIN und den
        // HBCI-Privatschlüssel des Nutzers in Lesereichweite — sie liegen in
        // derselben Datei wie die Umsätze. Ein Prozess, der beides kann, lesen
        // und senden, ist der Prozess, den es nicht geben darf.
        let verboten = ["URLSession", "URLRequest", "NWConnection", "import Network",
                        "getaddrinfo", "CFStream", "Process("]
        for begriff in verboten {
            XCTAssertFalse(try helfer.contains(begriff),
                           "Der Helfer darf \(begriff) nicht benutzen")
        }
        // Und er startet nichts: Ein Kindprozess wäre der Weg um alles Obige herum.
        XCTAssertFalse(try helfer.contains("posix_spawn"))
    }

    func testDerHelferLandetImBundleUndWirdSigniert() throws {
        // Ohne diese beiden Blöcke übersetzt alles, die Tests sind grün, und der
        // Import scheitert erst im gebauten Bundle mit „Helfer nicht gefunden" —
        // also beim Nutzer. `MoneyMoneyLesepfad.helfer` sucht neben
        // `Bundle.main.executableURL`, und was dort nicht liegt, gibt es nicht.
        let bauen = try Quelltext.quelle("build-app.sh")
        XCTAssertTrue(bauen.contains("--product simplebanking-mmimport"))
        XCTAssertTrue(bauen.contains("Contents/MacOS/simplebanking-mmimport"))
        XCTAssertTrue(bauen.contains("lipo -create -output \"$MM_UNIVERSAL\""),
                      "Der Helfer muss universal sein wie die App")

        // Unsigniert lehnt Apple das GESAMTE Bundle als invalid ab — der Kommentar
        // am CLI-Block hält genau das fest.
        let signieren = try Quelltext.quelle("sign-and-notarize.sh")
        XCTAssertTrue(signieren.contains("MacOS/simplebanking-mmimport"))
        let helferblock = Quelltext.abschnitt(signieren,
                                              von: "MM_BIN=",
                                              bis: "# Main Swift binary")
        XCTAssertTrue(helferblock.contains("--options runtime"))
        XCTAssertTrue(helferblock.contains("--timestamp"))
    }

    /// Der Import ist ein Angebot auf der ersten Seite, kein Schritt, der jedem
    /// widerfährt.
    ///
    /// Ohne MoneyMoney bleibt der Weg der alte — ein zusätzlicher Schritt für alle
    /// anderen wäre ein Rückschritt in der Einrichtung. Diese Zusage stand bis zum
    /// 11.11.2026 als `testDerAssistentFragtNurWennEsEineDatenbankGibt` in
    /// `MoneyMoneyVorhabenTests` und ist hier aufgegangen, strenger geworden.
    ///
    /// Bis zum 11.11.2026 hing der Schritt allein an
    /// `MoneyMoneyLesepfad.istVorhanden` — wer MoneyMoney installiert hatte, bekam
    /// ihn als erstes nach dem Hauptkennwort, ungefragt. Kein Typ hält das fest,
    /// darum hier: Der Weg zum Angebot muss an der Wahl des Nutzers hängen, und die
    /// Willkommensseite muss sie überhaupt anbieten.
    func testDerImportKommtNurAufWunsch() throws {
        let quelle = Quelltext.ohneKommentare(try Quelltext.datei("SetupFlowPanel.swift"))

        XCTAssertTrue(quelle.contains("mmGewaehlt && MoneyMoneyLesepfad.istVorhanden"),
                      "Der Weg zum MoneyMoney-Schritt muss an der Wahl hängen, "
                      + "nicht am Vorhandensein der Datenbank")
        XCTAssertTrue(quelle.contains("#selector(onWelcomeMoneyMoney)"),
                      "Die Willkommensseite muss den Import anbieten")
        XCTAssertTrue(quelle.contains("erststart && MoneyMoneyLesepfad.istVorhanden"),
                      "Das Angebot gehört nur in den Erststart und nur, wenn eine "
                      + "MoneyMoney-Datenbank da ist")
    }

    /// Im modalen Assistenten gibt es `Task { }` und `MainActor.run` nicht.
    ///
    /// `NSApp.runModal` dreht die Schleife in `NSModalPanelRunLoopMode`, und
    /// `DispatchQueue.main` feuert dort nicht — der Haupt-Actor plant aber genau
    /// darüber. Ein geerbter `Task { }` läuft nie an, ein `await MainActor.run`
    /// kehrt nie zurück. Beides still: kein Fehler, kein Absturz, nur eine
    /// Oberfläche, die für immer lädt. Genau das war am 11.11.2026 der
    /// „hängende" MoneyMoney-Import.
    ///
    /// Der Compiler sagt dazu nichts, also sagt es dieser Test.
    func testDerAssistentErbtDenHauptActorNicht() throws {
        let quelle = Quelltext.ohneKommentare(try Quelltext.datei("SetupFlowPanel.swift"))
        XCTAssertFalse(quelle.contains("Task {"),
                       "Arbeit aus dem modalen Assistenten gehört in Task.detached — "
                       + "ein geerbter Haupt-Actor wird dort nie eingeplant")
        XCTAssertFalse(quelle.contains("MainActor.run"),
                       "MainActor.run kehrt im modalen Assistenten nie zurück — "
                       + "Hauptthread.lauf nehmen")

        // Was der Assistent anstößt, läuft mit: der Nachtrag springt selbst auf den
        // Haupt-Thread, und zwar auf demselben Weg.
        let nachtrag = Quelltext.ohneKommentare(try Quelltext.datei("MoneyMoneyUebernahme.swift"))
        XCTAssertFalse(nachtrag.contains("MainActor.run"))
        XCTAssertTrue(nachtrag.contains("Hauptthread.lauf"))
    }
}

/// Welcher SQLite-Code was bedeutet.
///
/// Am 11.11.2026 stand im Assistenten „Das Kennwort passt nicht zu dieser
/// MoneyMoney-Datenbank" — mit dem richtigen Kennwort. MoneyMoney lief und hatte ein
/// `-journal` offen; eine Datenbank mit unaufgeräumtem Journal lässt sich nicht
/// nur-lesend öffnen, weil das Zurückrollen Schreibrechte bräuchte. Der Helfer warf
/// jeden gescheiterten Erstzugriff auf „falsches Kennwort".
final class MoneyMoneyFehlerfamilieTests: XCTestCase {

    func testNurNichtAlsDatenbankLesbarHeisstFalschesKennwort() {
        XCTAssertEqual(MoneyMoneyLesefehler.fuer(sqliteCode: 26), .kennwortFalsch,
                       "SQLITE_NOTADB (26) ist der Fall, in dem der Schlüssel nicht passt")
    }

    func testBelegtUndGesperrtSchickenNichtZumKennwort() {
        // SQLITE_BUSY, SQLITE_LOCKED, SQLITE_READONLY, SQLITE_IOERR, SQLITE_CANTOPEN
        for code: Int32 in [5, 6, 8, 10, 14] {
            XCTAssertEqual(MoneyMoneyLesefehler.fuer(sqliteCode: code), .inBenutzung,
                           "SQLite \(code) heisst 'gerade in Arbeit', nicht 'falsches Kennwort'")
        }
    }

    /// Am 12.11.2026 stand dieselbe Meldung wieder da, mit demselben richtigen
    /// Kennwort. Der 11.11. hatte nur **einen** von zwei Ausgängen erwischt: Bei
    /// unaufgeräumtem Journal scheitert schon `sqlite3_prepare_v2` — es liest das
    /// Schema —, der Lauf kommt also nie bis zum `step`, der seit gestern den
    /// SQLite-Code befragt. Die Zusage gilt deshalb am Quelltext und nicht an einer
    /// Stelle: Nach dem Setzen des Schlüssels darf kein Ausgang mehr „falsches
    /// Kennwort" behaupten, ohne SQLite gefragt zu haben.
    func testNachDemSchluesselEntscheidetNurNochSQLite() throws {
        let quelle = Quelltext.ohneKommentare(
            try Quelltext.quelle("Sources/simplebanking-mmimport/main.swift"))
        // Ab der Stelle, an der das Kennwort aus dem Speicher fällt: Alles danach
        // ist Lesen, und Lesen scheitert aus vielen Gründen.
        let nachDemSchluessel = Quelltext.abschnitt(quelle, von: "kennwort.removeAll()")
        XCTAssertFalse(nachDemSchluessel.contains("abbrechen(.kennwortFalsch"),
                       "Ein Lesefehler nach dem Schlüssel ist kein Beweis für ein falsches Kennwort")
        XCTAssertGreaterThanOrEqual(
            nachDemSchluessel.components(separatedBy: "fuer(sqliteCode:").count - 1, 2,
            "Beide Erstzugriffe — vorbereiten und ausführen — müssen den SQLite-Code befragen")
    }

    func testJederLesefehlerHatEineKennung() {
        for fall in MoneyMoneyLesefehler.allCases {
            XCTAssertFalse(fall.kennung.isEmpty)
        }
    }
}
