import Foundation
import Routex

// MARK: - RoutexClientError → User-facing message
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
        guard let re = error as? RoutexClientError else {
            return UserMessage(
                title: L10n.t("Unbekannter Fehler", "Unknown error"),
                detail: error.localizedDescription,
                suggestion: L10n.t("Bitte erneut versuchen.", "Please try again."),
                isRetryable: true
            )
        }

        switch re {
        case .InvalidRedirectUri:
            return UserMessage(
                title: L10n.t("Banking-Konfiguration fehlerhaft", "Banking configuration error"),
                detail: nil,
                suggestion: L10n.t("Setup neu starten.", "Restart setup."),
                isRetryable: false
            )

        case .RequestError(let err):
            return UserMessage(
                title: L10n.t("Netzwerkfehler", "Network error"),
                detail: err,
                suggestion: L10n.t("Internet prüfen, dann erneut versuchen.", "Check connection and retry."),
                isRetryable: true
            )

        case .UnexpectedError(let msg):
            return UserMessage(
                title: L10n.t("Unerwarteter Bankfehler", "Unexpected bank error"),
                detail: msg,
                suggestion: L10n.t("Kurz warten, dann erneut versuchen.", "Wait briefly and retry."),
                isRetryable: true
            )

        case .Canceled:
            return UserMessage(
                title: L10n.t("Vorgang abgebrochen", "Cancelled"),
                detail: nil,
                suggestion: nil,
                isRetryable: true
            )

        case .InvalidCredentials(let msg):
            return UserMessage(
                title: L10n.t("Zugangsdaten ungültig", "Invalid credentials"),
                detail: msg,
                suggestion: L10n.t("Bank-Login und Passwort prüfen, danach Setup neu starten.",
                                   "Verify bank login and password, then restart setup."),
                isRetryable: false
            )

        case .ServiceBlocked(let msg, _):
            return UserMessage(
                title: L10n.t("Bank-Zugang gesperrt", "Bank access blocked"),
                detail: msg,
                suggestion: L10n.t("Bei der Bank entsperren lassen.",
                                   "Contact the bank to unblock."),
                isRetryable: false
            )

        case .Unauthorized(let msg):
            return UserMessage(
                title: L10n.t("Sitzung abgelaufen", "Session expired"),
                detail: msg,
                suggestion: L10n.t("Erneut verbinden.", "Reconnect."),
                isRetryable: true
            )

        case .ConsentExpired(let msg):
            return UserMessage(
                title: L10n.t("Banking-Einwilligung abgelaufen", "Banking consent expired"),
                detail: msg,
                suggestion: L10n.t("Im Banking-Setup neu autorisieren.",
                                   "Re-authorize in banking setup."),
                isRetryable: true
            )

        case .AccessExceeded(let msg):
            return UserMessage(
                title: L10n.t("Tageslimit erreicht", "Daily limit reached"),
                detail: msg,
                suggestion: L10n.t("Morgen wieder versuchen.", "Try again tomorrow."),
                isRetryable: false
            )

        case .PeriodOutOfBounds(let msg):
            return UserMessage(
                title: L10n.t("Zeitraum nicht abrufbar", "Period out of range"),
                detail: msg,
                suggestion: L10n.t("Kürzeren Zeitraum wählen.", "Choose a shorter range."),
                isRetryable: false
            )

        case .UnsupportedProduct(_, let msg):
            return UserMessage(
                title: L10n.t("Konto wird nicht unterstützt", "Account type unsupported"),
                detail: msg,
                suggestion: L10n.t("Anderes Konto wählen.", "Choose a different account."),
                isRetryable: false
            )

        case .PaymentFailed(_, let msg):
            return UserMessage(
                title: L10n.t("Zahlung fehlgeschlagen", "Payment failed"),
                detail: msg,
                suggestion: nil,
                isRetryable: true
            )

        case .UnexpectedValue(let err):
            return UserMessage(
                title: L10n.t("Datenfehler", "Data error"),
                detail: err,
                suggestion: L10n.t("Bitte erneut versuchen.", "Please retry."),
                isRetryable: true
            )

        case .TicketError(let err, _):
            return UserMessage(
                title: L10n.t("Setup-Fehler", "Setup error"),
                detail: err,
                suggestion: L10n.t("Setup neu starten.", "Restart setup."),
                isRetryable: true
            )

        case .ProviderError(_, let msg):
            return UserMessage(
                title: L10n.t("Bankfehler", "Bank error"),
                detail: msg,
                suggestion: L10n.t("Kurz warten, dann erneut versuchen.", "Wait briefly and retry."),
                isRetryable: true
            )

        case .ResponseError(let response):
            return UserMessage(
                title: L10n.t("Unerwartete Antwort", "Unexpected response"),
                detail: response,
                suggestion: L10n.t("Bitte erneut versuchen.", "Please retry."),
                isRetryable: true
            )

        case .NotFound:
            return UserMessage(
                title: L10n.t("Nicht gefunden", "Not found"),
                detail: nil,
                suggestion: nil,
                isRetryable: false
            )

        case .InterruptError:
            return UserMessage(
                title: L10n.t("Vorgang unterbrochen", "Interrupted"),
                detail: nil,
                suggestion: L10n.t("Erneut versuchen.", "Retry."),
                isRetryable: true
            )
        }
    }
}
