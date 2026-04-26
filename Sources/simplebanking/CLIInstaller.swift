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
        case foreignBinaryAtTarget(currentTarget: String?)

        var errorDescription: String? {
            switch self {
            case .sourceMissing:
                return "CLI-Binary ist in diesem Build nicht enthalten."
            case .createDirFailed(let msg):
                return "Ordner ~/.local/bin konnte nicht angelegt werden: \(msg)"
            case .symlinkFailed(let msg):
                return "Symlink konnte nicht gesetzt werden: \(msg)"
            case .foreignBinaryAtTarget(let target):
                let where_ = target.map { " (zeigt auf: \($0))" } ?? ""
                return "Unter ~/.local/bin/sb existiert bereits etwas, das nicht von simplebanking ist\(where_). Bitte manuell wegräumen."
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

        // Owner-Check vor Remove: nur wegräumen wenn der existierende Symlink
        // wirklich auf ein simplebanking-Binary zeigt. Sonst hätten User mit
        // eigenem `sb`-Script (z.B. ein Brew-Tool, ein selbstgeschriebenes Wrapper)
        // ihren Eintrag still verloren — wir würden sie ungefragt überschreiben.
        if fm.fileExists(atPath: symlinkURL.path) ||
           (try? fm.destinationOfSymbolicLink(atPath: symlinkURL.path)) != nil {
            let target = try? fm.destinationOfSymbolicLink(atPath: symlinkURL.path)
            // Wir akzeptieren nur Symlinks die auf ein simplebanking-cli-Binary
            // im Bundle zeigen (absoluter Pfad ODER beliebiger Pfad mit dem
            // bekannten Suffix — das deckt App-Verschiebungen ab).
            let isOurs = target == sourceURL.path ||
                (target?.hasSuffix("simplebanking.app/Contents/MacOS/simplebanking-cli") ?? false)
            guard isOurs else {
                throw InstallError.foreignBinaryAtTarget(currentTarget: target)
            }
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

    // MARK: - PATH installation
    //
    // Wenn der User den PATH-Hinweis aus der App per Screenshot weiterleitet
    // (Support, Discord, Slack), fängt macOS Live Text die kyrillischen
    // Schwester-Glyphen statt $HOME (`Н О М Е` sehen identisch zu `H O M E`
    // aus). Beim Pasten ins Terminal expandiert die Shell die Variable nicht.
    // Wir bieten daher eine Auto-Fix-Aktion an, die die Zeile selbst ans rc-File
    // schreibt — und einen Copy-Button, der ASCII garantiert ins Pasteboard
    // legt (nicht erst durch Screenshot-OCR-Pipelines wandern muss).

    /// Die Shell-rc-Zeile die wir anbieten. Garantiert ASCII.
    static let shellRcLine = #"export PATH="$HOME/.local/bin:$PATH""#

    /// Marker damit Re-Runs die Zeile finden (auch wenn die literal-line jemand
    /// editiert hat) und idempotent bleiben.
    static let shellRcMarker = "# Added by simplebanking - sb CLI"

    enum ShellRcResult: Equatable {
        case alreadyConfigured(rcFile: URL)
        case appended(rcFile: URL)
    }

    enum ShellRcError: Error, LocalizedError {
        case readFailed(String)
        case writeFailed(String)
        var errorDescription: String? {
            switch self {
            case .readFailed(let m):  return "rc-Datei konnte nicht gelesen werden: \(m)"
            case .writeFailed(let m): return "rc-Datei konnte nicht geschrieben werden: \(m)"
            }
        }
    }

    /// Schreibt die PATH-Zeile ans Ende von `~/.zshrc` (oder `~/.bashrc` falls
    /// `.zshrc` nicht existiert und `.bashrc` schon da ist). Idempotent — Re-Run
    /// auf bereits konfiguriertem rc-File tut nichts.
    ///
    /// Symlink-safe: wenn ~/.zshrc ein Symlink ist (z.B. dotfile-management
    /// wie chezmoi/yadm/stow → ~/dotfiles/zshrc), schreiben wir auf den
    /// resolved Target-Pfad. `.write(to:atomically:)` würde sonst den Symlink
    /// durch eine reguläre Datei ersetzen + Permissions/Ownership ändern.
    static func ensurePathInShellRc() throws -> ShellRcResult {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        let zshrc = home.appendingPathComponent(".zshrc")
        let bashrc = home.appendingPathComponent(".bashrc")

        // macOS-default ist zsh seit Catalina. Wir nutzen .zshrc (anlegen wenn nicht da),
        // außer .bashrc existiert schon und .zshrc nicht.
        let userFacing: URL = {
            if fm.fileExists(atPath: zshrc.path) { return zshrc }
            if fm.fileExists(atPath: bashrc.path) { return bashrc }
            return zshrc
        }()

        // Symlink resolven: wenn userFacing ein Symlink ist, schreiben wir auf
        // den realen Pfad. Sonst würde atomic-write den Symlink ersetzen.
        let writeTarget: URL = {
            guard let symlinkDest = try? fm.destinationOfSymbolicLink(atPath: userFacing.path) else {
                return userFacing
            }
            // destinationOfSymbolicLink kann relativ oder absolut sein.
            if (symlinkDest as NSString).isAbsolutePath {
                return URL(fileURLWithPath: symlinkDest)
            }
            // Relativer Symlink → relativ zum Verzeichnis des Symlinks.
            return userFacing.deletingLastPathComponent().appendingPathComponent(symlinkDest)
        }()

        var existing = ""
        if fm.fileExists(atPath: writeTarget.path) {
            do {
                existing = try String(contentsOf: writeTarget, encoding: .utf8)
            } catch {
                throw ShellRcError.readFailed(error.localizedDescription)
            }
        }

        let updated = appendShellRcLineIfMissing(content: existing)
        if updated == existing {
            // Wir geben das user-facing path zurück (was der User in der Settings-
            // Status-Message sieht), nicht den resolved Pfad — sonst wäre der
            // dotfile-internal Pfad verwirrend.
            return .alreadyConfigured(rcFile: userFacing)
        }

        do {
            try updated.write(to: writeTarget, atomically: true, encoding: .utf8)
        } catch {
            throw ShellRcError.writeFailed(error.localizedDescription)
        }
        return .appended(rcFile: userFacing)
    }

    /// Pure helper — entscheidet ob `content` schon konfiguriert ist und liefert
    /// den ergänzten String zurück. Public für Tests.
    static func appendShellRcLineIfMissing(content: String) -> String {
        if content.contains(shellRcLine) || content.contains(shellRcMarker) {
            return content
        }
        // Sicherer Newline-Handling: wenn content nicht mit \n endet, einen vorne dran.
        let separator = (content.isEmpty || content.hasSuffix("\n")) ? "" : "\n"
        return content + separator + "\n" + shellRcMarker + "\n" + shellRcLine + "\n"
    }
}
