import Foundation

/// Outcome of an import operation (Deep-Sync, OFX, CAMT.053).
struct ImportResult {
    /// Anzahl neu aufgenommener Transaktionen (Cache wuchs).
    let inserted: Int
    /// Anzahl ignorierter Duplikate (Upsert-Konflikt via End-to-End-ID / tx_id).
    let duplicates: Int
    /// Gesamtzahl verarbeiteter Transaktionen aus der Quelle.
    var total: Int { inserted + duplicates }
    /// Einzelne Warnungen (parse-Fehler, verworfene Einträge). Nicht-fatal.
    let warnings: [String]

    init(inserted: Int, duplicates: Int, warnings: [String] = []) {
        self.inserted = inserted
        self.duplicates = duplicates
        self.warnings = warnings
    }

    static let empty = ImportResult(inserted: 0, duplicates: 0)
}

/// Fehler die während eines Imports fatal sind (nichts importiert).
enum ImportError: Error, LocalizedError {
    case credentialsUnavailable
    case fetchFailed(String)
    case parseFailed(String)
    case databaseFailed(String)

    var errorDescription: String? {
        switch self {
        case .credentialsUnavailable:
            return "Bank-Zugangsdaten konnten nicht geladen werden."
        case .fetchFailed(let msg):
            return "Abruf fehlgeschlagen: \(msg)"
        case .parseFailed(let msg):
            return "Datei konnte nicht verarbeitet werden: \(msg)"
        case .databaseFailed(let msg):
            return "Speichern fehlgeschlagen: \(msg)"
        }
    }
}
