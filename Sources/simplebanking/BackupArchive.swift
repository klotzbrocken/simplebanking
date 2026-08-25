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
    }

    struct Bericht {
        var einstellungen: Int
        var konten: Int
        var buchungen: Int
        var themes: Int
    }

    enum Fehler: LocalizedError {
        case falschePassphrase
        case unbekanntesFormat(Int)
        case beschaedigt(String)

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

        let inhalt = Inhalt(
            version: formatVersion,
            erstelltAm: Date(),
            appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?",
            einstellungenPlistB64: plist.base64EncodedString(),
            zugangsdaten: try zugangsdatenSammeln(),
            datenbankB64: try datenbankKopieren()?.base64EncodedString(),
            themes: mitThemes ? themesSammeln() : [:]
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

        let queue = try DatabaseQueue(path: quelle.path)
        try queue.write { db in
            try db.execute(sql: "VACUUM INTO ?", arguments: [ziel.path])
        }
        return try Data(contentsOf: ziel)
    }

    private static func themesSammeln() -> [String: String] {
        let ordner = ThemeManager.shared.themesDirectoryURL
        let dateien = (try? FileManager.default.contentsOfDirectory(atPath: ordner.path)) ?? []
        var aus: [String: String] = [:]
        for name in dateien {
            if let daten = try? Data(contentsOf: ordner.appendingPathComponent(name)),
               daten.count < 5_000_000 {
                aus[name] = daten.base64EncodedString()
            }
        }
        return aus
    }

    // MARK: - Einspielen

    @discardableResult
    static func einspielen(_ archiv: Data, passphrase: String) throws -> Bericht {
        let roh = try entschluesseln(archiv, passphrase: passphrase)
        let inhalt = try JSONDecoder().decode(Inhalt.self, from: roh)
        guard inhalt.version <= formatVersion else { throw Fehler.unbekanntesFormat(inhalt.version) }

        // Einstellungen
        guard let plist = Data(base64Encoded: inhalt.einstellungenPlistB64),
              let woerterbuch = try PropertyListSerialization.propertyList(
                    from: plist, options: [], format: nil) as? [String: Any]
        else { throw Fehler.beschaedigt("Einstellungen") }

        var gesetzt = 0
        for (k, v) in woerterbuch where !istAuszuschliessen(k) {
            UserDefaults.standard.set(v, forKey: k)
            gesetzt += 1
        }

        // Zugangsdaten — unverändert zurückschreiben, 0600 wie beim Original.
        let credOrdner = try CredentialsStore.appSupportURL()
        try FileManager.default.createDirectory(at: credOrdner, withIntermediateDirectories: true)
        for (name, b64) in inhalt.zugangsdaten {
            guard let daten = Data(base64Encoded: b64) else { continue }
            let ziel = credOrdner.appendingPathComponent(name)
            try daten.write(to: ziel, options: [.atomic])
            try? FileManager.default.setAttributes([.posixPermissions: 0o600],
                                                   ofItemAtPath: ziel.path)
        }

        // Datenbank — die vorhandene wird beiseitegelegt, nicht überschrieben. Wer eine
        // Sicherung einspielt, hat oft schon etwas in der neuen Installation; das
        // kommentarlos zu löschen wäre der zweite Datenverlust nach dem ersten.
        var buchungen = 0
        if let b64 = inhalt.datenbankB64, let daten = Data(base64Encoded: b64) {
            let ziel = try TransactionsDatabase.databaseURL()
            if FileManager.default.fileExists(atPath: ziel.path) {
                let beiseite = ziel.deletingLastPathComponent()
                    .appendingPathComponent("transactions-vor-wiederherstellung.db")
                try? FileManager.default.removeItem(at: beiseite)
                try? FileManager.default.moveItem(at: ziel, to: beiseite)
            }
            // Nebendateien des WAL-Betriebs müssen weg, sonst mischt SQLite den alten
            // Journalstand in die frisch eingespielte Datei.
            for anhang in ["-wal", "-shm"] {
                try? FileManager.default.removeItem(
                    at: URL(fileURLWithPath: ziel.path + anhang))
            }
            try daten.write(to: ziel, options: [.atomic])
            buchungen = (try? zaehleBuchungen(ziel)) ?? 0
        }

        // Themes
        let themeOrdner = ThemeManager.shared.themesDirectoryURL
        try? FileManager.default.createDirectory(at: themeOrdner, withIntermediateDirectories: true)
        var themeAnzahl = 0
        for (name, b64) in inhalt.themes {
            guard let daten = Data(base64Encoded: b64) else { continue }
            try? daten.write(to: themeOrdner.appendingPathComponent(name), options: [.atomic])
            themeAnzahl += 1
        }

        return Bericht(einstellungen: gesetzt,
                       konten: inhalt.zugangsdaten.count,
                       buchungen: buchungen,
                       themes: themeAnzahl)
    }

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

    private static func verschluesseln(_ klartext: Data, passphrase: String,
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

        let key = try schluessel(passphrase: passphrase, salt: [UInt8](salt), runden: u.iterations)
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
