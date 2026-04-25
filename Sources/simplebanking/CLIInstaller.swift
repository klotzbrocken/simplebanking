import Foundation

/// Installiert/deinstalliert den Terminal-CLI-Binary aus dem App-Bundle als Symlink
/// unter `~/.local/bin/sb`. Kein sudo nötig (User-Directory), aber der User muss
/// `~/.local/bin` in seinem PATH haben.
///
/// Das Symlink-Target zeigt auf das bundle-interne Binary. App-Updates nehmen den
/// Symlink automatisch mit — der `sb`-Befehl bleibt aktuell.
enum CLIInstaller {

    // MARK: - Paths

    /// Directory für den Symlink. `.local/bin` ist Quasi-Standard (systemd-inspired,
    /// in Linux-Manuals „user-writable bin"). macOS hat keinen nativen Äquivalent,
    /// aber viele Dev-Tools (pipx, rustup, cargo) schreiben dorthin.
    static var targetDir: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local", isDirectory: true)
            .appendingPathComponent("bin", isDirectory: true)
    }

    static var symlinkURL: URL {
        targetDir.appendingPathComponent("sb")
    }

    /// Absoluter Pfad zum CLI-Binary im App-Bundle.
    static var sourceURL: URL {
        Bundle.main.bundleURL
            .appendingPathComponent("Contents")
            .appendingPathComponent("MacOS")
            .appendingPathComponent("simplebanking-cli")
    }

    // MARK: - Status

    /// Quellbinary existiert im Bundle (ist also in diesem Build eingebunden).
    static var isAvailable: Bool {
        FileManager.default.isExecutableFile(atPath: sourceURL.path)
    }

    /// Symlink existiert und zeigt auf unser aktuelles Bundle-Binary.
    static var isInstalled: Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: symlinkURL.path) else { return false }
        if let target = try? fm.destinationOfSymbolicLink(atPath: symlinkURL.path) {
            // destinationOfSymbolicLink liefert den Target-Pfad aus dem Link —
            // wir akzeptieren sowohl absolute Pfade als auch relative.
            return target == sourceURL.path ||
                target.hasSuffix("simplebanking.app/Contents/MacOS/simplebanking-cli")
        }
        return false
    }

    /// `~/.local/bin` ist im aktuellen Shell-PATH?
    /// (Wir prüfen die Environment-Variable unseres Prozesses; das ist ein guter
    /// Proxy für das was der User gerade nutzt, aber Shell-Config-Files werden
    /// nicht re-evaluiert.)
    static var isInPath: Bool {
        let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
        let expanded = targetDir.path
        return path.split(separator: ":").contains { String($0) == expanded }
    }

    // MARK: - Actions

    enum InstallError: Error, LocalizedError {
        case sourceMissing
        case createDirFailed(String)
        case symlinkFailed(String)

        var errorDescription: String? {
            switch self {
            case .sourceMissing:
                return "CLI-Binary ist in diesem Build nicht enthalten."
            case .createDirFailed(let msg):
                return "Ordner ~/.local/bin konnte nicht angelegt werden: \(msg)"
            case .symlinkFailed(let msg):
                return "Symlink konnte nicht gesetzt werden: \(msg)"
            }
        }
    }

    static func install() throws {
        guard isAvailable else { throw InstallError.sourceMissing }
        let fm = FileManager.default

        do {
            try fm.createDirectory(at: targetDir, withIntermediateDirectories: true)
        } catch {
            throw InstallError.createDirFailed(error.localizedDescription)
        }

        // Vorhandenen Symlink oder Datei wegräumen (z.B. von einem älteren Bundle-Pfad).
        if fm.fileExists(atPath: symlinkURL.path) || (try? fm.destinationOfSymbolicLink(atPath: symlinkURL.path)) != nil {
            try? fm.removeItem(at: symlinkURL)
        }

        do {
            try fm.createSymbolicLink(at: symlinkURL, withDestinationURL: sourceURL)
        } catch {
            throw InstallError.symlinkFailed(error.localizedDescription)
        }
    }

    static func uninstall() throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: symlinkURL.path) ||
           (try? fm.destinationOfSymbolicLink(atPath: symlinkURL.path)) != nil {
            try fm.removeItem(at: symlinkURL)
        }
    }
}
