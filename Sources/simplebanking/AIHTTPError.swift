import Foundation

// MARK: - AI provider HTTP error mapping
//
// Vorher warfen `AIProviderService.anthropicComplete` und `openAICompatibleComplete`
// generische NSErrors mit "AI API Fehler (\(statusCode)): \(body)" — der User sah
// einen Status-Code statt einer verständlichen Erklärung. 401 (key ungültig) und
// 429 (rate-limit) sahen identisch aus.
//
// Dieser Enum klassifiziert HTTP-Fehler und liefert pro Case eine deutsche
// Erklärung + (für 429) Retry-After-Hinweis.

enum AIHTTPError: LocalizedError, Equatable {
    case unauthorized(provider: String)
    case forbidden(provider: String)
    case rateLimited(provider: String, retryAfterSeconds: TimeInterval?)
    case serverError(provider: String, statusCode: Int)
    case clientError(provider: String, statusCode: Int)

    /// Factory aus HTTP-Response. Klassifiziert nach statusCode-Range, parst
    /// `Retry-After`-Header bei 429 (kann numeric "120" oder HTTP-Date sein —
    /// wir handhaben hier nur numeric, HTTP-Date wäre over-engineering).
    static func from(provider: String, response: HTTPURLResponse) -> AIHTTPError {
        switch response.statusCode {
        case 401:
            return .unauthorized(provider: provider)
        case 403:
            return .forbidden(provider: provider)
        case 429:
            let retryAfter: TimeInterval? = {
                guard let h = response.value(forHTTPHeaderField: "Retry-After"),
                      let secs = TimeInterval(h.trimmingCharacters(in: .whitespaces)) else {
                    return nil
                }
                return secs
            }()
            return .rateLimited(provider: provider, retryAfterSeconds: retryAfter)
        case 500...599:
            return .serverError(provider: provider, statusCode: response.statusCode)
        default:
            return .clientError(provider: provider, statusCode: response.statusCode)
        }
    }

    var errorDescription: String? {
        switch self {
        case .unauthorized(let p):
            return L10n.t(
                "\(p): API-Schlüssel ungültig oder abgelaufen. In den Einstellungen erneuern.",
                "\(p): API key invalid or expired. Renew in settings.")
        case .forbidden(let p):
            return L10n.t(
                "\(p): API-Schlüssel hat keine Berechtigung für diesen Endpunkt.",
                "\(p): API key has no access to this endpoint.")
        case .rateLimited(let p, let after):
            if let after {
                return L10n.t(
                    "\(p): Rate-Limit erreicht. Erneut versuchen in \(Int(after)) s.",
                    "\(p): rate-limited. Retry in \(Int(after)) s.")
            }
            return L10n.t(
                "\(p): Rate-Limit erreicht. Kurz warten, dann erneut.",
                "\(p): rate-limited. Wait briefly and retry.")
        case .serverError(let p, let code):
            return L10n.t(
                "\(p): Server-Fehler (\(code)). Später erneut versuchen.",
                "\(p): server error (\(code)). Try again later.")
        case .clientError(let p, let code):
            return L10n.t(
                "\(p): Anfrage abgelehnt (\(code)).",
                "\(p): request rejected (\(code)).")
        }
    }

    /// Sinnvolle UI-Action: bei 401/403 muss der User in die Settings, sonst Retry.
    var isRetryable: Bool {
        switch self {
        case .unauthorized, .forbidden, .clientError: return false
        case .rateLimited, .serverError: return true
        }
    }
}
