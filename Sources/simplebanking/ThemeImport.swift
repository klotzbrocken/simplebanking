import Foundation

/// Installiert ein Theme aus einer `.cfg` oder einem ZIP in den Theme-Ordner.
///
/// **Den Pfaden im Archiv wird nicht geglaubt.** Ein ZIP kann Einträge wie
/// `../../../bin/foo` enthalten; darauf zu bauen, dass `unzip` das abfängt, wäre eine
/// Wette. Stattdessen wird in ein temporäres Verzeichnis entpackt, der Baum selbst
/// durchlaufen und **jede Datei nur über ihren Basisnamen** kopiert. Damit sind die
/// Pfade im Archiv schlicht ohne Bedeutung.
///
/// Das Flachziehen ist zugleich fachlich nötig: `ThemeChrome.themeAssetURL` verlangt
/// einfache Dateinamen im Theme-Ordner. Wer einen Ordner zippt — der Normalfall — hätte
/// sonst ein Theme, das lädt, aber ohne Wallpaper, Logo und Ringbild dasteht.
enum ThemeImport {

    /// Was am Ende im Theme-Ordner liegen darf. Alles andere wird nicht kopiert —
    /// die Ladeprüfungen (Maße, Byte-Grenzen, Symlink-Ausbruch) greifen ohnehin, aber
    /// was nicht dazugehört, soll gar nicht erst im Ordner landen.
    static let erlaubteEndungen: Set<String> = ["cfg", "png", "pdf", "svg"]

    /// Obergrenze fürs Archiv. Ein Theme sind drei Wallpaper à 4 MB plus Kleinkram;
    /// 40 MB sind großzügig und verhindern trotzdem, dass ein aufgeblasenes ZIP die
    /// Platte füllt.
    static let maxArchivBytes = 40 * 1024 * 1024

    enum Fehler: Error, Equatable {
        case archivZuGross(bytes: Int)
        case entpackenFehlgeschlagen
        case keineCfgGefunden
        case reservierterName(String)
        case idBereitsVergeben(id: String, name: String)
        case unlesbar
        case schreibfehler(String)
    }

    struct Ergebnis: Equatable {
        let themeId: String
        let themeName: String
        let dateien: [String]
    }

    // MARK: - Prüfungen (rein, ohne Dateisystem)

    /// Dateinamen, die der Start überschreibt oder löscht — ein Import darunter wäre
    /// spätestens beim nächsten Start spurlos verschwunden.
    static var reservierteDateinamen: Set<String> {
        Set(ThemeManager.builtInThemes.keys.map { $0.lowercased() })
            .union(ThemeManager.retiredThemeFiles.map { $0.lowercased() })
    }

    static func istReserviert(_ dateiname: String) -> Bool {
        reservierteDateinamen.contains(dateiname.lowercased())
    }

    /// Darf diese Datei in den Theme-Ordner?
    ///
    /// Verlangt einen einfachen Namen mit erlaubter Endung. Punkt am Anfang schließt
    /// `.DS_Store` und macOS-Ressourcegabeln (`._foo.png`) aus, die in fast jedem auf
    /// dem Mac gepackten Archiv liegen.
    static func istUebernehmbar(_ dateiname: String) -> Bool {
        guard !dateiname.hasPrefix("."), !dateiname.contains("/") else { return false }
        let endung = (dateiname as NSString).pathExtension.lowercased()
        return erlaubteEndungen.contains(endung)
    }

    // MARK: - Import

    /// Installiert die gewählte Datei. Wirft mit einer Begründung, die sich anzeigen lässt.
    ///
    /// `ueberschreiben: false` bricht ab, wenn die `id` schon vergeben ist — der Aufrufer
    /// kann dann fragen und erneut aufrufen.
    @MainActor
    static func importieren(von quelle: URL, ueberschreiben: Bool = false) throws -> Ergebnis {
        let istZip = quelle.pathExtension.lowercased() == "zip"
        let arbeitsordner = istZip ? try entpacken(quelle) : quelle.deletingLastPathComponent()
        defer { if istZip { try? FileManager.default.removeItem(at: arbeitsordner) } }

        let kandidaten = istZip
            ? uebernehmbareDateien(in: arbeitsordner)
            : [quelle]

        guard let cfg = kandidaten.first(where: { $0.pathExtension.lowercased() == "cfg" }) else {
            throw Fehler.keineCfgGefunden
        }
        if istReserviert(cfg.lastPathComponent) {
            throw Fehler.reservierterName(cfg.lastPathComponent)
        }
        guard let theme = ThemeManager.shared.parseTheme(from: cfg) else { throw Fehler.unlesbar }

        if !ueberschreiben,
           let vorhanden = ThemeManager.shared.availableThemes().first(where: { $0.id == theme.id }) {
            throw Fehler.idBereitsVergeben(id: theme.id, name: vorhanden.name)
        }

        // Bei einer einzelnen .cfg werden bewusst KEINE Nachbardateien mitgenommen —
        // sonst kopierte die Auswahl einer Datei aus dem Downloads-Ordner unbesehen
        // alles mit, was zufällig danebenliegt.
        let zuKopieren = istZip ? kandidaten : [cfg]
        let ziel = URL(fileURLWithPath: ThemeManager.shared.themesDirectoryPath)
        try FileManager.default.createDirectory(at: ziel, withIntermediateDirectories: true)

        var kopiert: [String] = []
        for datei in zuKopieren {
            let name = datei.lastPathComponent
            guard istUebernehmbar(name), !istReserviert(name) else { continue }
            let zielDatei = ziel.appendingPathComponent(name)
            do {
                if FileManager.default.fileExists(atPath: zielDatei.path) {
                    try FileManager.default.removeItem(at: zielDatei)
                }
                try FileManager.default.copyItem(at: datei, to: zielDatei)
                kopiert.append(name)
            } catch {
                throw Fehler.schreibfehler(name)
            }
        }

        AppLogger.log("Theme-Import: \(theme.id) mit \(kopiert.count) Datei(en): \(kopiert.joined(separator: ", "))",
                      category: "Theme")
        // Ohne das erschiene das Theme erst nach einem Neustart in der Auswahl.
        ThemeManager.shared.reloadThemes()
        return Ergebnis(themeId: theme.id, themeName: theme.name, dateien: kopiert)
    }

    // MARK: - Innereien

    private static func entpacken(_ zip: URL) throws -> URL {
        let groesse = (try? FileManager.default.attributesOfItem(atPath: zip.path)[.size] as? Int) ?? 0
        guard groesse <= maxArchivBytes else { throw Fehler.archivZuGross(bytes: groesse ?? 0) }

        let ordner = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("theme-import-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: ordner, withIntermediateDirectories: true)

        // `/usr/bin/unzip` wie beim eBon-Import (REWEService) — die App ist nicht
        // sandboxed. `-j` zieht schon beim Entpacken flach; die Basisnamen-Regel unten
        // bleibt trotzdem, denn sie ist die Zusage, nicht die Bequemlichkeit.
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        p.arguments = ["-o", "-q", "-j", zip.path, "-d", ordner.path]
        do { try p.run(); p.waitUntilExit() } catch { throw Fehler.entpackenFehlgeschlagen }
        guard p.terminationStatus == 0 else { throw Fehler.entpackenFehlgeschlagen }
        return ordner
    }

    /// Alle übernehmbaren Dateien unterhalb von `ordner` — rekursiv, aber **nur reguläre
    /// Dateien**. Symlinks bleiben außen vor: Sie könnten aus dem temporären Ordner
    /// heraus auf beliebige Dateien des Nutzers zeigen, und `copyItem` folgte ihnen.
    private static func uebernehmbareDateien(in ordner: URL) -> [URL] {
        guard let lauf = FileManager.default.enumerator(
            at: ordner,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var gefunden: [URL] = []
        for fall in lauf {
            guard let url = fall as? URL else { continue }
            let werte = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard werte?.isSymbolicLink != true, werte?.isRegularFile == true else { continue }
            guard istUebernehmbar(url.lastPathComponent) else { continue }
            gefunden.append(url)
        }
        return gefunden
    }
}

// MARK: - Fehlertexte

extension ThemeImport.Fehler {
    /// Anzeigbarer Grund. Sagt jeweils auch, was zu tun ist — eine Fehlermeldung, die
    /// nur benennt, lässt den Nutzer stehen.
    var beschreibung: String {
        switch self {
        case .archivZuGross(let bytes):
            return L10n.t("Das Archiv ist \(bytes / 1024 / 1024) MB groß. Erlaubt sind \(ThemeImport.maxArchivBytes / 1024 / 1024) MB.",
                          "The archive is \(bytes / 1024 / 1024) MB. The limit is \(ThemeImport.maxArchivBytes / 1024 / 1024) MB.")
        case .entpackenFehlgeschlagen:
            return L10n.t("Das Archiv ließ sich nicht entpacken.", "The archive could not be extracted.")
        case .keineCfgGefunden:
            return L10n.t("Im Archiv ist keine .cfg-Datei — ohne sie ist es kein Theme.",
                          "The archive contains no .cfg file — without one it isn't a theme.")
        case .reservierterName(let name):
            return L10n.t("„\(name)“ ist ein mitgelieferter Themename. Er wird bei jedem Start überschrieben — benenne die Datei um.",
                          "„\(name)“ is a built-in theme file name. It gets overwritten on every launch — rename the file.")
        case .idBereitsVergeben(_, let name):
            return L10n.t("Ein Theme mit dieser Kennung gibt es schon: „\(name)“.",
                          "A theme with this id already exists: „\(name)“.")
        case .unlesbar:
            return L10n.t("Die .cfg-Datei ließ sich nicht lesen.", "The .cfg file could not be read.")
        case .schreibfehler(let name):
            return L10n.t("„\(name)“ ließ sich nicht in den Theme-Ordner kopieren.",
                          "„\(name)“ could not be copied into the themes folder.")
        }
    }
}
