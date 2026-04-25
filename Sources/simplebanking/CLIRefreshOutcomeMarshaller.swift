import Foundation

// MARK: - CLI refresh outcome wire format
//
// Shared JSON shape zwischen App (Writer) und `sb` CLI (Reader, siehe
// `Sources/simplebanking-cli/DataReader.swift::lastRefreshOutcome`). Dieses
// File ist die Single Source of Truth für die Wire-Keys und das Encoding —
// der CLI-Reader spiegelt das Schema bewusst (kann den App-Code nicht importieren,
// weil das ein separates SPM-Executable-Target ist). Tests in
// `CLIRefreshOutcomeTests` decken den Round-Trip ab und schützen vor Drift.

enum CLIRefreshOutcomeStatus: String, Equatable {
    case success
    case locked
    case failed
}

struct CLIRefreshOutcome: Equatable {
    let status: CLIRefreshOutcomeStatus
    let timestamp: String
    let detail: String?
}

enum CLIRefreshOutcomeKeys {
    /// JSON outcome marker — primary signal für die CLI.
    static let outcome = "simplebanking.cli.lastRefreshOutcome"
    /// Legacy ISO-8601 timestamp — bleibt für rückwärtskompat ältere `sb`-Binaries
    /// (die nur diesen Marker pollen) gesetzt.
    static let legacy = "simplebanking.cli.lastRefreshCompletedAt"
}

enum CLIRefreshOutcomeMarshaller {

    /// Erzeugt das JSON für den outcome-Marker und liefert den Timestamp separat
    /// zurück, damit der Caller den legacy-Marker mit demselben Wert setzen kann.
    static func encode(
        status: CLIRefreshOutcomeStatus,
        detail: String? = nil,
        now: Date = Date()
    ) -> (json: String, timestamp: String)? {
        let ts = ISO8601DateFormatter().string(from: now)
        var payload: [String: Any] = ["status": status.rawValue, "timestamp": ts]
        if let detail { payload["detail"] = detail }
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
              let json = String(data: data, encoding: .utf8) else {
            return nil
        }
        return (json, ts)
    }

    /// Parst das vom CLI gepollte JSON. Gibt `nil` bei kaputtem JSON oder
    /// fehlenden Pflichtfeldern — der Reader fällt dann auf den legacy-Marker
    /// zurück.
    static func decode(json: String) -> CLIRefreshOutcome? {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let statusStr = obj["status"] as? String,
              let status = CLIRefreshOutcomeStatus(rawValue: statusStr),
              let ts = obj["timestamp"] as? String else {
            return nil
        }
        return CLIRefreshOutcome(status: status, timestamp: ts, detail: obj["detail"] as? String)
    }
}
