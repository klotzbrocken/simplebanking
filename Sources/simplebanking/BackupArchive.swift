import Foundation
import CryptoKit
import CommonCrypto
import GRDB

// MARK: - Sicherung und Wiederherstellung
//
// Zweck: Eine Neuinstallation soll kein Neuaufbau sein. Nach dem Einspielen stehen die
// Konten mit Namen, IBAN und Historie wieder da; freigeben muss man sie einmal neu.
//
// **Was bewusst NICHT mitwandert: die Zustimmungen (`connectionData`) und Sitzungen.**
// Die sind an Maschine und Freigabe gebunden. Eine tote Zustimmung einzuspielen erzeugt
// genau den Zustand, der am 23.08.2026 stundenlang Rätsel aufgab: Der Abruf läuft sauber
// durch, meldet keinen Fehler und liefert trotzdem nichts. Lieber ehrlich neu freigeben.
//
// **Zugangsdaten wandern als verschlüsselter Umschlag mit, unverändert.** Sie liegen
// ohnehin schon AES-GCM-verschlüsselt unter dem Master-Passwort; sie hier auszupacken und
// neu zu verschlüsseln hieße, sie unterwegs im Klartext zu halten, ohne dass es etwas
// brächte. Das Master-Passwort selbst ist NICHT in der Sicherung — es steht in deinem
// Kopf, nicht auf der Platte, und beim Einspielen tippst du es wie bisher.
//
// Die Sicherung als Ganzes liegt unter der Passphrase des Nutzers, mit derselben Mechanik
// wie die Zugangsdaten: PBKDF2-SHA256 mit 210 000 Runden, dann AES-GCM.
enum BackupArchive {

    static let dateiendung = "sbbackup"
    static let formatVersion = 1
    private static let pbkdf2Runden = 210_000

    /// Obergrenze für alles, was aus Ordnern eingesammelt wird (Belege, Entwürfe, Themes).
    ///
    /// Die Grenze je Datei allein reicht nicht: Der Export hält die Daten mehrfach im
    /// Speicher — Rohdatei, Base64, JSON, Ciphertext, äußeres Base64. Viele Dateien knapp
    /// unter der Einzelgrenze summieren sich damit zu einem Vielfachen. Was nicht mehr
    /// hineinpasst, wird protokolliert statt stillschweigend zu fehlen.
    static let sammelGrenze = 400_000_000

    // MARK: - Was nicht mitwandert

    /// Schlüssel, die bewusst draußen bleiben.
    ///
    /// Eigene Funktion und nicht in der Schleife versteckt, weil daran die Zusage hängt,
    /// die im Dialog steht. Wer hier etwas hinzufügt, ändert eine Zusage.
    static func istAuszuschliessen(_ schluessel: String) -> Bool {
        schluessel.contains("simplebanking.yaxi.connectionData")
            || schluessel.contains("simplebanking.yaxi.session.")
            || schluessel.contains("simplebanking.yaxi.connectionDataAt")
    }

    // MARK: - Inhalt

    struct Inhalt: Codable {
        var version: Int
        var erstelltAm: Date
        var appVersion: String
        /// Binäre Property-List der gefilterten Einstellungen, Base64. Bewusst kein
        /// eigenes JSON-Schema: Die Werte sind heterogen (Text, Zahl, Bool, Daten,
        /// Listen), und die Property-List gibt sie verlustfrei zurück.
        var einstellungenPlistB64: String
        /// Dateiname → Base64 des bereits verschlüsselten Umschlags.
        var zugangsdaten: [String: String]
        var datenbankB64: String?
        var themes: [String: String]
        /// Belege an Buchungen (`attachments/…`) und Überweisungsentwürfe.
        ///
        /// **Optional, damit ältere Sicherungen weiterhin lesbar bleiben.** Wären sie
        /// Pflichtfelder, ließe sich eine Datei aus der ersten Fassung nicht mehr
        /// einspielen — und ausgerechnet die hat jemand angelegt, bevor das hier dazukam.
        var anhaenge: [String: String]?
        var entwuerfe: [String: String]?
    }

    struct Bericht {
        var einstellungen: Int
        var konten: Int
        var buchungen: Int
        var themes: Int
        var anhaenge: Int = 0
    }

    enum Fehler: LocalizedError {
        case falschePassphrase
        case unbekanntesFormat(Int)
        case beschaedigt(String)
        case abgelehnterPfad(String)

        var errorDescription: String? {
            switch self {
            case .falschePassphrase:
                return L10n.t("Falsche Passphrase — die Sicherung ließ sich nicht entschlüsseln.",
                              "Wrong passphrase — the backup could not be decrypted.")
            case .unbekanntesFormat(let v):
                return L10n.t("Diese Sicherung stammt aus einer neueren Version (Format \(v)).",
                              "This backup comes from a newer version (format \(v)).")
            case .beschaedigt(let was):
                return L10n.t("Die Sicherung ist unvollständig: \(was)",
                              "The backup is incomplete: \(was)")
            case .abgelehnterPfad(let name):
                return L10n.t("Die Sicherung enthält einen unzulässigen Dateinamen und wurde nicht eingespielt: \(name)",
                              "The backup contains an invalid file name and was not restored: \(name)")
            }
        }
    }

    // MARK: - Export

    /// - Parameter domain: Einstellungs-Domäne. Vorgabe ist die der App; Tests geben eine
    ///   eigene mit, damit ein Testlauf nicht die echten Einstellungen des Nutzers
    ///   einsammelt. (`UserDefaults.standard` ist unter XCTest ohnehin eine andere — die
    ///   Domäne hier wird aber ausdrücklich beim Namen genannt und träfe sonst die echte.)
    static func exportieren(passphrase: String,
                            merkhilfe: String? = nil,
                            mitThemes: Bool = true,
                            domain: String = "tech.yaxi.simplebanking") throws -> Data {
        let d = UserDefaults.standard.persistentDomain(forName: domain) ?? [:]
        var gefiltert: [String: Any] = [:]
        for (k, v) in d where !istAuszuschliessen(k) { gefiltert[k] = v }
        let plist = try PropertyListSerialization.data(fromPropertyList: gefiltert,
                                                       format: .binary, options: 0)

        // Ein gemeinsames Budget für alle drei Sammler — nacheinander, weil zwei
        // gleichzeitige `inout`-Zugriffe in einer Argumentliste nicht erlaubt sind.
        var budget = sammelGrenze
        let themes = mitThemes ? themesSammeln(budget: &budget) : [:]
        let anhaenge = ordnerSammeln("attachments", budget: &budget)
        let entwuerfe = ordnerSammeln("transfer-drafts", budget: &budget)

        let inhalt = Inhalt(
            version: formatVersion,
            erstelltAm: Date(),
            appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?",
            einstellungenPlistB64: plist.base64EncodedString(),
            zugangsdaten: try zugangsdatenSammeln(),
            datenbankB64: try datenbankKopieren()?.base64EncodedString(),
            themes: themes,
            anhaenge: anhaenge,
            entwuerfe: entwuerfe
        )

        return try verschluesseln(try JSONEncoder().encode(inhalt),
                                  passphrase: passphrase, merkhilfe: merkhilfe)
    }

    /// Die Umschläge liegen bereits verschlüsselt vor — wir reichen sie unverändert durch.
    private static func zugangsdatenSammeln() throws -> [String: String] {
        let ordner = try CredentialsStore.appSupportURL()
        let dateien = (try? FileManager.default.contentsOfDirectory(atPath: ordner.path)) ?? []
        var aus: [String: String] = [:]
        for name in dateien where name.hasPrefix("credentials") && name.hasSuffix(".json") {
            if let daten = try? Data(contentsOf: ordner.appendingPathComponent(name)) {
                aus[name] = daten.base64EncodedString()
            }
        }
        return aus
    }

    /// Eine in sich stimmige Kopie der Datenbank — auch während die App läuft.
    ///
    /// `VACUUM INTO` schreibt einen konsistenten Stand in eine neue Datei. Die laufende
    /// Datenbank einfach zu kopieren wäre falsch: Im WAL-Betrieb liegen Änderungen in
    /// einer Nebendatei, und die Kopie träfe einen Zwischenstand.
    private static func datenbankKopieren() throws -> Data? {
        let quelle = try TransactionsDatabase.databaseURL()
        guard FileManager.default.fileExists(atPath: quelle.path) else { return nil }
        let ziel = FileManager.default.temporaryDirectory
            .appendingPathComponent("sb-sicherung-\(UUID().uuidString).db")
        defer { try? FileManager.default.removeItem(at: ziel) }

        // `writeWithoutTransaction` ist hier Pflicht, nicht Geschmackssache: `write`
        // legt eine Transaktion drumherum, und SQLite lehnt VACUUM darin ab
        // („cannot VACUUM from within a transaction"). Der Export scheiterte deshalb
        // bei jedem Versuch — gemeldet am 25.08.2026 als „Datei wird nicht angelegt".
        let queue = try DatabaseQueue(path: quelle.path)
        try queue.writeWithoutTransaction { db in
            try db.execute(sql: "VACUUM INTO ?", arguments: [ziel.path])
        }
        return try Data(contentsOf: ziel)
    }

    /// Sammelt einen Unterordner des Datenverzeichnisses rekursiv ein.
    ///
    /// Für Belege: Die Datenbank kennt sie als Zeile, die Datei liegt daneben. Ohne diese
    /// Dateien käme nach dem Einspielen eine Buchung zurück, die auf einen Beleg zeigt,
    /// den es nicht mehr gibt — schlimmer als gar kein Beleg, weil es wie ein Fehler
    /// aussieht.
    ///
    /// Bewusst NICHT dabei: `logo-cache` (baut sich von selbst wieder auf) und
    /// `transactions-demo.db` (Vorführdaten, keine Nutzerdaten).
    private static func ordnerSammeln(_ unterordner: String, budget: inout Int) -> [String: String] {
        guard let basis = try? CredentialsStore.appSupportURL()
                .appendingPathComponent(unterordner) else { return [:] }
        guard let lauf = FileManager.default.enumerator(at: basis,
                                                        includingPropertiesForKeys: [.isRegularFileKey])
        else { return [:] }

        var aus: [String: String] = [:]
        for fall in lauf {
            guard let url = fall as? URL,
                  (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true,
                  let daten = try? Data(contentsOf: url) else { continue }
            // Einzelne sehr große Dateien bleiben draußen, damit eine Sicherung nicht an
            // einem versehentlich abgelegten Video scheitert. Wird protokolliert, statt
            // stillschweigend zu fehlen.
            guard daten.count <= 20_000_000 else {
                AppLogger.log("Sicherung: \(url.lastPathComponent) übersprungen (\(daten.count / 1_048_576) MB)",
                              category: "Backup", level: "WARN")
                continue
            }
            guard daten.count <= budget else {
                AppLogger.log("Sicherung: \(url.lastPathComponent) übersprungen — Gesamtgrenze erreicht",
                              category: "Backup", level: "WARN")
                continue
            }
            budget -= daten.count
            // Beide Seiten auflösen, bevor verglichen wird: `enumerator` liefert den
            // aufgelösten Pfad (/private/var/…), die Basis ist der Symlink (/var/…).
            // Ohne das griff der Abgleich nicht, der „relative" Pfad blieb absolut, und
            // die Datei landete beim Einspielen irgendwo tief in einem Fantasieordner —
            // der Zähler stimmte trotzdem, der Beleg fehlte.
            let basisAufgeloest = basis.resolvingSymlinksInPath().path
            let dateiAufgeloest = url.resolvingSymlinksInPath().path
            guard dateiAufgeloest.hasPrefix(basisAufgeloest + "/") else { continue }
            let relativ = String(dateiAufgeloest.dropFirst(basisAufgeloest.count + 1))
            aus[relativ] = daten.base64EncodedString()
        }
        return aus
    }

    private static func themesSammeln(budget: inout Int) -> [String: String] {
        let ordner = ThemeManager.shared.themesDirectoryURL
        let dateien = (try? FileManager.default.contentsOfDirectory(atPath: ordner.path)) ?? []
        var aus: [String: String] = [:]
        for name in dateien {
            if let daten = try? Data(contentsOf: ordner.appendingPathComponent(name)),
               daten.count < 5_000_000 {
                guard daten.count <= budget else {
                    AppLogger.log("Sicherung: Theme \(name) übersprungen — Gesamtgrenze erreicht",
                                  category: "Backup", level: "WARN")
                    continue
                }
                budget -= daten.count
                aus[name] = daten.base64EncodedString()
            }
        }
        return aus
    }

    // MARK: - Zielpfade

    /// Prüft einen Namen aus einer Sicherung und liefert den Zielpfad — oder wirft.
    ///
    /// Eine Sicherung ist eine Datei von außen: Wer sie erstellt, bestimmt die Namen darin,
    /// und die Verschlüsselung schützt davor nicht — die Passphrase liefert er ja mit. Ein
    /// Name wie `../../../.zshrc` schriebe sonst aus dem Zielordner heraus, und was in der
    /// `.zshrc` steht, führt die nächste Shell aus.
    ///
    /// - Parameter unterordner: Für Belege und Entwürfe erlaubt — ihre Pfade enthalten
    ///   Ordner. Für Zugangsdaten und Themes nicht; dort sind es reine Dateinamen.
    static func sichererZielpfad(basis: URL, name: String, unterordner: Bool = false) throws -> URL {
        guard !name.isEmpty, name.utf8.count <= 1024 else { throw Fehler.abgelehnterPfad(name) }
        guard !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              !name.contains("\\"), !name.hasPrefix("~")
        else { throw Fehler.abgelehnterPfad(name) }

        let teile = name.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard unterordner || teile.count == 1 else { throw Fehler.abgelehnterPfad(name) }
        for teil in teile {
            // Leere Teile fangen führende, doppelte und abschließende Trenner mit ab.
            guard !teil.isEmpty, teil != ".", teil != ".." else { throw Fehler.abgelehnterPfad(name) }
        }

        var ziel = basis
        for teil in teile { ziel = ziel.appendingPathComponent(teil) }

        // Der Zielordner kann selbst ein Symlink sein — dann läge die Datei außerhalb,
        // ohne dass im Namen etwas Verdächtiges stünde. Deshalb beide Seiten auflösen,
        // wie `ordnerSammeln` es beim Einsammeln schon tut.
        let basisAufgeloest = basis.resolvingSymlinksInPath().standardized.path
        let eltern = ziel.deletingLastPathComponent().resolvingSymlinksInPath().standardized.path
        guard eltern == basisAufgeloest || eltern.hasPrefix(basisAufgeloest + "/") else {
            throw Fehler.abgelehnterPfad(name)
        }
        return ziel
    }

    // MARK: - Einspielen

    /// Alles, was geschrieben werden soll — dekodiert, geprüft, mit fertigen Zielpfaden.
    private struct Vorbereitet {
        var einstellungen: [String: Any]
        var zugangsdaten: [(ziel: URL, daten: Data)]
        var datenbank: (daten: Data, buchungen: Int)?
        var dateien: [(ziel: URL, daten: Data)]
        var themes: [(ziel: URL, daten: Data)]
    }

    /// Der Vorabdurchgang: dekodiert alles, prüft jeden Zielpfad und öffnet die
    /// mitgelieferte Datenbank probeweise — **bevor** das erste Byte geschrieben wird.
    ///
    /// Ein vollständiger Rückweg wäre teurer und brächte kaum mehr: Woran ein Einspielen
    /// scheitert, entscheidet sich fast immer hier. Vorher schrieb es Einstellungen und
    /// Zugangsdaten und stolperte erst danach — mit einer halb umgebauten Installation als
    /// Ergebnis, aus der man von Hand wieder herausfinden musste.
    private static func vorbereiten(_ inhalt: Inhalt) throws -> Vorbereitet {
        guard let plist = Data(base64Encoded: inhalt.einstellungenPlistB64),
              let woerterbuch = (try? PropertyListSerialization.propertyList(
                    from: plist, options: [], format: nil)) as? [String: Any]
        else { throw Fehler.beschaedigt("Einstellungen") }

        let credOrdner = try CredentialsStore.appSupportURL()
        var zugangsdaten: [(ziel: URL, daten: Data)] = []
        for (name, b64) in inhalt.zugangsdaten {
            guard let daten = Data(base64Encoded: b64) else {
                throw Fehler.beschaedigt("Zugangsdaten (\(name))")
            }
            zugangsdaten.append((try sichererZielpfad(basis: credOrdner, name: name), daten))
        }

        var datenbank: (daten: Data, buchungen: Int)?
        if let b64 = inhalt.datenbankB64 {
            guard let daten = Data(base64Encoded: b64) else { throw Fehler.beschaedigt("Datenbank") }
            datenbank = (daten, try buchungenPruefen(daten))
        }

        var dateien: [(ziel: URL, daten: Data)] = []
        for (unterordner, liste) in [("attachments", inhalt.anhaenge ?? [:]),
                                     ("transfer-drafts", inhalt.entwuerfe ?? [:])] {
            let basis = credOrdner.appendingPathComponent(unterordner)
            for (relativ, b64) in liste {
                guard let daten = Data(base64Encoded: b64) else {
                    throw Fehler.beschaedigt("Beleg (\(relativ))")
                }
                dateien.append((try sichererZielpfad(basis: basis, name: relativ, unterordner: true),
                                daten))
            }
        }

        let themeOrdner = ThemeManager.shared.themesDirectoryURL
        var themes: [(ziel: URL, daten: Data)] = []
        for (name, b64) in inhalt.themes {
            guard let daten = Data(base64Encoded: b64) else {
                throw Fehler.beschaedigt("Theme (\(name))")
            }
            themes.append((try sichererZielpfad(basis: themeOrdner, name: name), daten))
        }

        return Vorbereitet(einstellungen: woerterbuch, zugangsdaten: zugangsdaten,
                           datenbank: datenbank, dateien: dateien, themes: themes)
    }

    /// Öffnet die mitgelieferte Datenbank in einer Kopie und zählt die Buchungen.
    ///
    /// Vorher verschluckte ein `try?` diesen Fehler: Eine unlesbare Datei wurde eingespielt
    /// und als „0 Buchungen" gemeldet — eine Erfolgsmeldung über einen Datenverlust.
    static func buchungenPruefen(_ daten: Data) throws -> Int {
        let probe = FileManager.default.temporaryDirectory
            .appendingPathComponent("sb-probe-\(UUID().uuidString).db")
        defer { try? FileManager.default.removeItem(at: probe) }
        do {
            try daten.write(to: probe, options: [.atomic])
            return try zaehleBuchungen(probe)
        } catch {
            throw Fehler.beschaedigt("Datenbank")
        }
    }

    @discardableResult
    static func einspielen(_ archiv: Data, passphrase: String) throws -> Bericht {
        let roh = try entschluesseln(archiv, passphrase: passphrase)
        let inhalt = try JSONDecoder().decode(Inhalt.self, from: roh)
        guard inhalt.version <= formatVersion else { throw Fehler.unbekanntesFormat(inhalt.version) }

        let plan = try vorbereiten(inhalt)

        // Ab hier wird geschrieben. Alles davor ist geprüft.
        var gesetzt = 0
        for (k, v) in plan.einstellungen where !istAuszuschliessen(k) {
            UserDefaults.standard.set(v, forKey: k)
            gesetzt += 1
        }

        // Zugangsdaten — unverändert zurückschreiben, 0600 wie beim Original.
        let credOrdner = try CredentialsStore.appSupportURL()
        try FileManager.default.createDirectory(at: credOrdner, withIntermediateDirectories: true)
        var konten = 0
        for (ziel, daten) in plan.zugangsdaten {
            try daten.write(to: ziel, options: [.atomic])
            try? FileManager.default.setAttributes([.posixPermissions: 0o600],
                                                   ofItemAtPath: ziel.path)
            konten += 1
        }

        // Datenbank — die vorhandene wird beiseitegelegt, nicht überschrieben. Wer eine
        // Sicherung einspielt, hat oft schon etwas in der neuen Installation; das
        // kommentarlos zu löschen wäre der zweite Datenverlust nach dem ersten.
        var buchungen = 0
        if let db = plan.datenbank {
            let ziel = try TransactionsDatabase.databaseURL()
            if FileManager.default.fileExists(atPath: ziel.path) {
                try beiseiteLegen(ziel)
            }
            // Nebendateien des WAL-Betriebs müssen weg, sonst mischt SQLite den alten
            // Journalstand in die frisch eingespielte Datei.
            for anhang in ["-wal", "-shm"] {
                try? FileManager.default.removeItem(
                    at: URL(fileURLWithPath: ziel.path + anhang))
            }
            try db.daten.write(to: ziel, options: [.atomic])
            buchungen = db.buchungen
        }

        // Belege und Entwürfe — mit den Unterordnern, die im Pfad stecken.
        var anhangAnzahl = 0
        for (ziel, daten) in plan.dateien {
            try? FileManager.default.createDirectory(at: ziel.deletingLastPathComponent(),
                                                     withIntermediateDirectories: true)
            if (try? daten.write(to: ziel, options: [.atomic])) != nil { anhangAnzahl += 1 }
        }

        // Themes
        let themeOrdner = ThemeManager.shared.themesDirectoryURL
        try? FileManager.default.createDirectory(at: themeOrdner, withIntermediateDirectories: true)
        var themeAnzahl = 0
        for (ziel, daten) in plan.themes {
            // Gezählt wird, was geschrieben wurde. Vorher stand das Hochzählen hinter einem
            // `try?` und zählte die Fehlschläge mit.
            if (try? daten.write(to: ziel, options: [.atomic])) != nil { themeAnzahl += 1 }
        }

        return Bericht(einstellungen: gesetzt,
                       konten: konten,
                       buchungen: buchungen,
                       themes: themeAnzahl,
                       anhaenge: anhangAnzahl)
    }

    /// Wie viele beiseitegelegte Datenbanken aufgehoben werden.
    static let rueckfallebenen = 3

    /// Legt die vorhandene Datenbank datiert beiseite und behält die letzten drei.
    ///
    /// Vorher hieß die Datei fest `transactions-vor-wiederherstellung.db` und wurde vor
    /// jedem Versuch gelöscht — **zwei fehlgeschlagene Einspielversuche hintereinander
    /// hätten die letzte funktionierende Datenbank vernichtet.**
    private static func beiseiteLegen(_ ziel: URL) throws {
        let ordner = ziel.deletingLastPathComponent()
            .appendingPathComponent("db-sicherungen", isDirectory: true)
        try FileManager.default.createDirectory(at: ordner, withIntermediateDirectories: true)
        let beiseite = ordner.appendingPathComponent(
            "transactions-vor-wiederherstellung-\(dateiStempel.string(from: Date())).db")
        try FileManager.default.moveItem(at: ziel, to: beiseite)
        AppLogger.log("Datenbank beiseitegelegt: \(beiseite.lastPathComponent)", category: "Backup")

        let vorhanden = (try? FileManager.default.contentsOfDirectory(
            at: ordner, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        let sortiert = vorhanden
            .filter { $0.lastPathComponent.hasPrefix("transactions-vor-wiederherstellung-") }
            .sorted { a, b in
                let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? .distantPast
                let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? .distantPast
                return da > db
            }
        for alt in sortiert.dropFirst(rueckfallebenen) {
            try? FileManager.default.removeItem(at: alt)
            AppLogger.log("Alte Rückfallebene entfernt: \(alt.lastPathComponent)", category: "Backup")
        }
    }

    nonisolated(unsafe) private static let dateiStempel: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd-HHmmss"
        return f
    }()

    private static func zaehleBuchungen(_ url: URL) throws -> Int {
        let queue = try DatabaseQueue(path: url.path)
        return try queue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM transactions") ?? 0
        }
    }

    // MARK: - Umschlag (gleiche Mechanik wie CredentialsStore)

    private struct Umschlag: Codable {
        let v: Int
        let saltB64: String
        let nonceB64: String
        let ciphertextB64: String
        let tagB64: String
        let kdf: String
        let iterations: Int
        /// Merkhilfe — **unverschlüsselt und mit Absicht.**
        ///
        /// Eine Erinnerungshilfe, die man erst nach Eingabe der Passphrase lesen könnte,
        /// wäre sinnlos. Sie steht deshalb im Dateikopf. Der Nutzer wird im Dialog
        /// gewarnt, dass sie mitlesbar ist — sie darf die Passphrase nicht verraten.
        var hinweis: String?
    }

    /// Liest die Merkhilfe, ohne die Sicherung zu entschlüsseln. Für den Einspiel-Dialog:
    /// Er zeigt sie an, bevor nach der Passphrase gefragt wird — genau dann braucht man
    /// sie.
    static func merkhilfe(aus archiv: Data) -> String? {
        guard let u = try? JSONDecoder().decode(Umschlag.self, from: archiv) else { return nil }
        guard let h = u.hinweis, !h.isEmpty else { return nil }
        return h
    }

    /// Intern statt privat, damit die Tests eine **feindlich präparierte** Sicherung bauen
    /// können. Ohne das ließe sich der Angriffsweg nur in Einzelteilen prüfen — und genau
    /// das war der Mangel des alten Ausbruchs-Tests.
    static func verschluesseln(_ klartext: Data, passphrase: String,
                               merkhilfe: String?) throws -> Data {
        var salt = [UInt8](repeating: 0, count: 16)
        guard SecRandomCopyBytes(kSecRandomDefault, salt.count, &salt) == errSecSuccess else {
            throw Fehler.beschaedigt("Zufallsquelle")
        }
        let key = try schluessel(passphrase: passphrase, salt: salt, runden: pbkdf2Runden)
        let nonce = AES.GCM.Nonce()
        let versiegelt = try AES.GCM.seal(klartext, using: key, nonce: nonce)
        let u = Umschlag(v: formatVersion,
                         saltB64: Data(salt).base64EncodedString(),
                         nonceB64: Data(nonce).base64EncodedString(),
                         ciphertextB64: versiegelt.ciphertext.base64EncodedString(),
                         tagB64: versiegelt.tag.base64EncodedString(),
                         kdf: "pbkdf2-sha256",
                         iterations: pbkdf2Runden,
                         hinweis: merkhilfe?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty)
        return try JSONEncoder().encode(u)
    }

    private static func entschluesseln(_ archiv: Data, passphrase: String) throws -> Data {
        guard let u = try? JSONDecoder().decode(Umschlag.self, from: archiv),
              let salt = Data(base64Encoded: u.saltB64),
              let nonceData = Data(base64Encoded: u.nonceB64),
              let ciphertext = Data(base64Encoded: u.ciphertextB64),
              let tag = Data(base64Encoded: u.tagB64)
        else { throw Fehler.beschaedigt("Dateikopf") }

        guard u.v <= formatVersion else { throw Fehler.unbekanntesFormat(u.v) }
        guard u.kdf == "pbkdf2-sha256" else {
            throw Fehler.beschaedigt("Schlüsselableitung (\(u.kdf))")
        }

        let key = try schluessel(passphrase: passphrase, salt: [UInt8](salt),
                                 runden: try gepruefteRunden(u.iterations))
        do {
            let box = try AES.GCM.SealedBox(nonce: try AES.GCM.Nonce(data: nonceData),
                                            ciphertext: ciphertext, tag: tag)
            return try AES.GCM.open(box, using: key)
        } catch {
            // AES-GCM unterscheidet nicht zwischen „falsches Kennwort" und „verändert" —
            // beides ist ein gescheiterter Authentizitätsnachweis. Für den Nutzer ist die
            // falsche Passphrase der weitaus wahrscheinlichere Fall.
            throw Fehler.falschePassphrase
        }
    }

    /// Zulässige Rundenzahlen aus dem Dateikopf.
    ///
    /// Der Kopf liegt **außerhalb** der Verschlüsselung — er muss ohne Passphrase lesbar
    /// sein, sonst wäre die Merkhilfe nutzlos. Damit ist er auch nicht authentifiziert, und
    /// ein präparierter Wert lief bis hier ungeprüft durch. `UInt32(runden)` ist bei einem
    /// negativen oder zu großen Wert kein langsamer Lauf, sondern ein sofortiger Absturz:
    /// Eine untergeschobene Datei beendete die App, noch bevor eine Passphrase geprüft war.
    /// Die Obergrenze deckelt zusätzlich die Rechenzeit.
    static let rundenGrenzen = 10_000...5_000_000

    static func gepruefteRunden(_ roh: Int) throws -> Int {
        guard rundenGrenzen.contains(roh) else { throw Fehler.beschaedigt("Rundenzahl (\(roh))") }
        return roh
    }

    private static func schluessel(passphrase: String, salt: [UInt8], runden: Int) throws -> SymmetricKey {
        var abgeleitet = [UInt8](repeating: 0, count: 32)
        defer { MemoryWipe.zeroize(&abgeleitet) }
        let laenge = passphrase.lengthOfBytes(using: .utf8)
        let status: Int32 = passphrase.withCString { pw in
            salt.withUnsafeBytes { s in
                guard let basis = s.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                    return Int32(kCCParamError)
                }
                return CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), pw, laenge,
                                            basis, salt.count,
                                            CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                                            UInt32(runden), &abgeleitet, abgeleitet.count)
            }
        }
        guard status == kCCSuccess else { throw Fehler.beschaedigt("Schlüsselableitung") }
        return SymmetricKey(data: Data(abgeleitet))
    }
}
