import Foundation
import RoutexClient

// MARK: - Fehler der Routex-Bibliothek → Text für den Nutzer
//
// Vorher zeigte die UI rohen `error.localizedDescription`-Output von RoutexClient
// — das landete als "UnexpectedError" oder generischer Englisch-String beim User.
// Dieser Mapper übersetzt jeden Case in einen deutschen Titel + Aktions-Vorschlag,
// reicht aber die Bank-supplied `userMessage` als optionales Detail durch (die ist
// oft präziser als unser eigener Text).
//
// Verwendung in der UI:
//   let msg = RoutexErrorMapper.userMessage(for: error)
//   alert.title = msg.title
//   alert.body  = msg.detail ?? msg.suggestion ?? ""
//   if msg.isRetryable { alert.addAction("Erneut versuchen") }

enum RoutexErrorMapper {

    struct UserMessage: Equatable {
        /// Kurzer Titel — was ist passiert (deutsch/englisch via L10n).
        let title: String
        /// Bank-supplied userMessage (raw). Kann nil sein. Oft präziser als
        /// unser eigener Text — UI sollte ihn primär anzeigen wenn vorhanden.
        let detail: String?
        /// Vorschlag was der User tun kann. nil wenn nichts sinnvolles.
        let suggestion: String?
        /// Lohnt es sich, "Erneut versuchen" anzubieten?
        /// false bei: Cancel, InvalidCredentials, UnsupportedProduct, AccessExceeded.
        let isRetryable: Bool
    }

    /// Wandelt einen Error in eine User-Message. Nicht-Routex-Errors bekommen
    /// einen generischen Fallback-Text.
    static func userMessage(for error: Error) -> UserMessage {
        // Seit SDK 0.5 gibt es VIER Fehlerfamilien statt einer: `RoutexError` (Bank bzw.
        // Dienst), `RoutexClientError` (Fehler im Client selbst), `HTTPError` (Transport)
        // und `KeySettlementError` (Attestierung). Eine Abfrage nur auf
        // `RoutexClientError` — wie bis 0.4.1 — ginge an ALLEN Bankfehlern vorbei, und
        // jeder davon bekäme den generischen Text.
        if let http = error as? HTTPError {
            return UserMessage(
                title: L10n.t("Keine Verbindung", "No connection"),
                detail: "\(http)",
                suggestion: L10n.t("Internetverbindung prüfen und erneut versuchen.",
                                   "Check your connection and retry."),
                isRetryable: true
            )
        }
        if let client = error as? RoutexClientError {
            return UserMessage(
                title: L10n.t("Antwort nicht lesbar", "Malformed response"),
                detail: "\(client)",
                suggestion: L10n.t("Bitte erneut versuchen.", "Please retry."),
                isRetryable: true
            )
        }
        if let settlement = error as? KeySettlementError {
            return UserMessage(
                title: L10n.t("Sichere Verbindung nicht bestätigt", "Secure channel unverified"),
                detail: "\(settlement)",
                suggestion: L10n.t("Bitte erneut versuchen. Bleibt es dabei, ist der Dienst gestört.",
                                   "Please retry. If it persists, the service is disrupted."),
                isRetryable: true
            )
        }
        guard let re = error as? RoutexError else {
            return UserMessage(
                title: L10n.t("Unbekannter Fehler", "Unknown error"),
                detail: error.localizedDescription,
                suggestion: L10n.t("Bitte erneut versuchen.", "Please try again."),
                isRetryable: true
            )
        }

        switch re {
        // `InvalidRedirectUri` und `RequestError` gibt es seit 0.5 nicht mehr:
        // `setRedirectURI` prüft nicht mehr, und Transportfehler sind `HTTPError`
        // (oben abgefangen). Geblieben ist die unlesbare Antwort.
        case .unrecognizedResponse(let status, let text):
            return UserMessage(
                title: L10n.t("Unerwartete Antwort", "Unexpected response"),
                detail: "HTTP \(status): \(text)",
                suggestion: L10n.t("Bitte erneut versuchen.", "Please retry."),
                isRetryable: true
            )

        case .unexpectedError(let msg):
            return UserMessage(
                title: L10n.t("Unerwarteter Bankfehler", "Unexpected bank error"),
                detail: msg,
                suggestion: L10n.t("Kurz warten, dann erneut versuchen.", "Wait briefly and retry."),
                isRetryable: true
            )

        case .canceled:
            return UserMessage(
                title: L10n.t("Vorgang abgebrochen", "Cancelled"),
                detail: nil,
                suggestion: nil,
                isRetryable: true
            )

        case .invalidCredentials(let msg):
            return UserMessage(
                title: L10n.t("Zugangsdaten ungültig", "Invalid credentials"),
                detail: msg,
                suggestion: L10n.t("Bank-Login und Passwort prüfen, danach Setup neu starten.",
                                   "Verify bank login and password, then restart setup."),
                isRetryable: false
            )

        case .serviceBlocked(_, let msg):
            return UserMessage(
                title: L10n.t("Bank-Zugang gesperrt", "Bank access blocked"),
                detail: msg,
                suggestion: L10n.t("Bei der Bank entsperren lassen.",
                                   "Contact the bank to unblock."),
                isRetryable: false
            )

        // `ConsentExpired` ist seit 0.5 in `unauthorized` aufgegangen. Der Vorschlag
        // deckt deshalb beides ab: eine abgelaufene Sitzung löst sich durch erneutes
        // Verbinden, eine abgelaufene Einwilligung braucht die Einrichtung. Am Fehler
        // allein sind die Fälle nicht mehr zu unterscheiden.
        case .unauthorized(let msg):
            return UserMessage(
                title: L10n.t("Zugriff abgelaufen", "Access expired"),
                detail: msg,
                suggestion: L10n.t("Erneut verbinden. Hilft das nicht, im Banking-Setup neu autorisieren.",
                                   "Reconnect. If that does not help, re-authorize in banking setup."),
                isRetryable: true
            )

        case .accessExceeded(let msg):
            return UserMessage(
                title: L10n.t("Tageslimit erreicht", "Daily limit reached"),
                detail: msg,
                suggestion: L10n.t("Morgen wieder versuchen.", "Try again tomorrow."),
                isRetryable: false
            )

        case .periodOutOfBounds(let msg):
            return UserMessage(
                title: L10n.t("Zeitraum nicht abrufbar", "Period out of range"),
                detail: msg,
                suggestion: L10n.t("Kürzeren Zeitraum wählen.", "Choose a shorter range."),
                isRetryable: false
            )

        case .unsupportedProduct(_, let msg):
            return UserMessage(
                title: L10n.t("Konto wird nicht unterstützt", "Account type unsupported"),
                detail: msg,
                suggestion: L10n.t("Anderes Konto wählen.", "Choose a different account."),
                isRetryable: false
            )

        case .paymentFailed(_, let msg):
            return UserMessage(
                title: L10n.t("Zahlung fehlgeschlagen", "Payment failed"),
                detail: msg,
                suggestion: nil,
                isRetryable: true
            )

        case .unexpectedValue(let err):
            return UserMessage(
                title: L10n.t("Datenfehler", "Data error"),
                detail: err,
                suggestion: L10n.t("Bitte erneut versuchen.", "Please retry."),
                isRetryable: true
            )

        case .ticketError(let err, _):
            return UserMessage(
                title: L10n.t("Setup-Fehler", "Setup error"),
                detail: err,
                suggestion: L10n.t("Setup neu starten.", "Restart setup."),
                isRetryable: true
            )

        case .providerError(_, let msg):
            return UserMessage(
                title: L10n.t("Bankfehler", "Bank error"),
                detail: msg,
                suggestion: L10n.t("Kurz warten, dann erneut versuchen.", "Wait briefly and retry."),
                isRetryable: true
            )

        case .notFound:
            return UserMessage(
                title: L10n.t("Nicht gefunden", "Not found"),
                detail: nil,
                suggestion: nil,
                isRetryable: false
            )

        case .interruptError:
            return UserMessage(
                title: L10n.t("Vorgang unterbrochen", "Interrupted"),
                detail: nil,
                suggestion: L10n.t("Erneut versuchen.", "Retry."),
                isRetryable: true
            )

        // Pflicht, kein Versehen: `RoutexError` kann in einer künftigen SDK-Fassung
        // Fälle dazubekommen. Ein erschöpfendes `switch` bricht dann beim Aktualisieren —
        // die Migrationsanleitung zu 0.5 nennt das ausdrücklich.
        default:
            return UserMessage(
                title: L10n.t("Bankfehler", "Bank error"),
                detail: "\(re)",
                suggestion: L10n.t("Bitte erneut versuchen.", "Please retry."),
                isRetryable: true
            )
        }
    }
}
