import Foundation

/// Installiert einen **stabilen Symlink** `~/.local/bin/simplebanking-mcp` → das
/// MCP-Binary im App-Bundle. Analog zu `CLIInstaller` (das `sb`-CLI), aber für den
/// MCP-Server.
///
/// Warum ein Symlink? Die generierte Claude-Config (Desktop-JSON bzw.
/// `claude mcp add`) referenziert `command` als **absoluten Pfad**. Zeigt der auf den
/// Bundle-internen Pfad, bricht er beim Verschieben/Update der App. Der Symlink gibt
/// einen stabilen Pfad; `refreshIfInstalled()` (beim App-Start) zeigt ihn nach einem
/// App-Move wieder auf das aktuelle Bundle — die Config bleibt gültig.
enum MCPInstaller {

    // MARK: - Paths

    /// Directory für den Symlink — identisch zum CLI (`~/.local/bin`).
    static var targetDir: URL { CLIInstaller.targetDir }

    static var symlinkURL: URL {
        targetDir.appendingPathComponent("simplebanking-mcp")
    }

    /// Absoluter Pfad zum MCP-Binary im App-Bundle.
    static var sourceURL: URL {
        Bundle.main.bundleURL
            .appendingPathComponent("Contents")
            .appendingPathComponent("MacOS")
            .appendingPathComponent("simplebanking-mcp")
    }

    private static let bundleSuffix = "simplebanking.app/Contents/MacOS/simplebanking-mcp"

    // MARK: - Status

    /// Quellbinary existiert im Bundle (ist also in diesem Build eingebunden).
    static var isAvailable: Bool {
        FileManager.default.isExecutableFile(atPath: sourceURL.path)
    }

    /// True, wenn der Symlink-Target uns gehört (absoluter Pfad ODER bekannter Suffix —
    /// deckt App-Verschiebungen ab).
    static func targetIsOurs(_ target: String?) -> Bool {
        guard let target else { return false }
        return target == sourceURL.path || target.hasSuffix(bundleSuffix)
    }

    /// Symlink existiert und zeigt auf ein simplebanking-mcp-Binary.
    static var isInstalled: Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: symlinkURL.path) ||
              (try? fm.destinationOfSymbolicLink(atPath: symlinkURL.path)) != nil else { return false }
        return targetIsOurs(try? fm.destinationOfSymbolicLink(atPath: symlinkURL.path))
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
                return "MCP-Binary ist in diesem Build nicht enthalten."
            case .createDirFailed(let msg):
                return "Ordner ~/.local/bin konnte nicht angelegt werden: \(msg)"
            case .symlinkFailed(let msg):
                return "Symlink konnte nicht gesetzt werden: \(msg)"
            case .foreignBinaryAtTarget(let target):
                let where_ = target.map { " (zeigt auf: \($0))" } ?? ""
                return "Unter ~/.local/bin/simplebanking-mcp existiert bereits etwas, das nicht von simplebanking ist\(where_). Bitte manuell wegräumen."
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

        // Owner-Check vor Remove: nur wegräumen, wenn der existierende Symlink uns
        // gehört — sonst würde ein fremder Eintrag still überschrieben.
        if fm.fileExists(atPath: symlinkURL.path) ||
           (try? fm.destinationOfSymbolicLink(atPath: symlinkURL.path)) != nil {
            let target = try? fm.destinationOfSymbolicLink(atPath: symlinkURL.path)
            guard targetIsOurs(target) else {
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

    /// Zeigt einen bestehenden (uns gehörenden) Symlink auf das AKTUELLE Bundle neu.
    /// No-op, wenn nicht installiert oder das Ziel bereits stimmt. Beim App-Start
    /// aufrufen, damit die Config nach einem App-Move/Update gültig bleibt.
    static func refreshIfInstalled() {
        let fm = FileManager.default
        guard let target = try? fm.destinationOfSymbolicLink(atPath: symlinkURL.path) else { return }
        guard targetIsOurs(target) else { return }          // fremder Link → nicht anfassen
        guard target != sourceURL.path else { return }      // schon korrekt
        guard isAvailable else { return }
        try? fm.removeItem(at: symlinkURL)
        try? fm.createSymbolicLink(at: symlinkURL, withDestinationURL: sourceURL)
    }
}
