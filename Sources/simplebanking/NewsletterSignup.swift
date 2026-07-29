import Foundation
import SwiftUI

// MARK: - Update-Liste
//
// Eintrag in die E-Mail-Liste für Neuigkeiten. Der Endpunkt ist derselbe, den die
// Website nutzt (`WaitlistCTA.tsx`) — ein Formspree-Formular.
//
// **Der einzige ausgehende Aufruf der App, der eine Adresse des Nutzers verschickt.**
// Deshalb gelten hier engere Regeln als anderswo:
//
//   • Nur auf ausdrückliche Eingabe. Kein Vorbefüllen, schon gar nicht aus Kontodaten.
//   • Nie im Hintergrund, nie beim Start.
//   • Es geht ausschließlich die eingetippte Adresse hinaus, plus die Herkunft und die
//     Version — damit sichtbar ist, woher ein Eintrag kam. Keine IBAN, kein Kontoname,
//     kein Saldo, keine Kennung des Geräts.
//
// Die Trennung in reine Funktionen (`isValidEmail`, `requestBody`) und den Netzaufruf
// ist Absicht: Was hinausgeht, lässt sich damit im Test festnageln, ohne das Netz.

enum NewsletterSignup {

    static let endpoint = URL(string: "https://formspree.io/f/mreazlnb")!

    /// Merkt einen erfolgten Eintrag, damit die „Neu in…"-Sheet niemanden zweimal
    /// fragt. Bewusst nur ein lokaler Merker: Ob die Adresse wirklich im Verteiler
    /// steht, weiß die App nicht — das entscheidet die Bestätigungsmail.
    private static let subscribedKey = "simplebanking.newsletterSubscribed"

    static var hasSubscribed: Bool {
        get { UserDefaults.standard.bool(forKey: subscribedKey) }
        set { UserDefaults.standard.set(newValue, forKey: subscribedKey) }
    }

    // MARK: - Reine Logik

    /// Bewusst großzügig: Eine App darf keine gültigen Adressen abweisen, nur weil ihr
    /// Muster enger ist als der Standard. Geprüft wird das, was einen Tippfehler
    /// erkennbar macht — genau ein `@`, links und rechts etwas, rechts ein Punkt mit
    /// mindestens zwei Zeichen dahinter. Die echte Prüfung ist die Bestätigungsmail.
    static func isValidEmail(_ raw: String) -> Bool {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty, !s.contains(" "), s.count <= 254 else { return false }
        let teile = s.split(separator: "@", omittingEmptySubsequences: false)
        guard teile.count == 2, !teile[0].isEmpty else { return false }
        let domain = teile[1]
        guard let punkt = domain.lastIndex(of: "."), punkt != domain.startIndex else { return false }
        return domain[domain.index(after: punkt)...].count >= 2
    }

    /// Was tatsächlich hinausgeht. Als eigene Funktion, damit ein Test die Felder
    /// aufzählen kann — die Zusage „keine Kontodaten" ist sonst nur ein Kommentar.
    static func requestBody(email: String, source: String, version: String) -> [String: String] {
        [
            "email": email.trimmingCharacters(in: .whitespacesAndNewlines),
            "source": source,
            "version": version,
        ]
    }

    enum SignupError: LocalizedError, Equatable {
        case ungueltigeAdresse
        case abgelehnt(status: Int)
        case netz

        var errorDescription: String? {
            switch self {
            case .ungueltigeAdresse:
                return L10n.t("Diese E-Mail-Adresse sieht nicht richtig aus.",
                              "That email address doesn't look right.")
            case .abgelehnt:
                return L10n.t("Der Eintrag wurde nicht angenommen. Bitte später erneut versuchen.",
                              "The signup was rejected. Please try again later.")
            case .netz:
                return L10n.t("Keine Verbindung. Bitte später erneut versuchen.",
                              "No connection. Please try again later.")
            }
        }
    }

    // MARK: - Netz

    static func subscribe(email: String, source: String) async -> Result<Void, SignupError> {
        guard isValidEmail(email) else { return .failure(.ungueltigeAdresse) }

        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Ohne diesen Header antwortet Formspree mit einer HTML-Seite statt mit JSON.
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.timeoutInterval = 20
        req.httpBody = try? JSONEncoder().encode(requestBody(email: email, source: source, version: version))

        do {
            let (_, response) = try await URLSession.shared.data(for: req)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(status) else {
                AppLogger.log("Newsletter: abgelehnt, status=\(status)", category: "Newsletter", level: "WARN")
                return .failure(.abgelehnt(status: status))
            }
            // Nur die Herkunft protokollieren, nie die Adresse.
            AppLogger.log("Newsletter: Eintrag gesendet (source=\(source))", category: "Newsletter")
            hasSubscribed = true
            return .success(())
        } catch {
            AppLogger.log("Newsletter: Netzfehler \(error.localizedDescription)",
                          category: "Newsletter", level: "WARN")
            return .failure(.netz)
        }
    }
}

// MARK: - Ansicht

/// Kompaktes Eingabefeld samt Zusage, wohin die Adresse geht. Wird in der
/// „Neu in simplebanking"-Sheet und in den Einstellungen verwendet.
@MainActor
struct NewsletterSignupView: View {

    /// Woher der Eintrag kam — landet im Formular, damit die Herkunft sichtbar ist.
    let source: String
    /// In der Sheet erklärt die Überschrift den Zusammenhang schon; dort ist sie überflüssig.
    var zeigeUeberschrift: Bool = true

    @State private var email: String = ""
    @State private var laeuft = false
    @State private var fertig = false
    @State private var fehler: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if zeigeUeberschrift {
                Text(L10n.t("Neuigkeiten per Mail", "News by email"))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.primary)
            }

            if fertig {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
                    Text(L10n.t("Eingetragen. Du bekommst eine Mail zur Bestätigung.",
                                "You're on the list. Check your inbox to confirm."))
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
            } else {
                HStack(spacing: 8) {
                    TextField(L10n.t("deine@adresse.de", "you@example.com"), text: $email)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12))
                        .frame(maxWidth: 220)
                        .disabled(laeuft)
                        .onSubmit { eintragen() }
                    Button(action: eintragen) {
                        Text(laeuft ? L10n.t("Sende…", "Sending…")
                                    : L10n.t("Eintragen", "Sign up"))
                            .font(.system(size: 12))
                    }
                    .disabled(laeuft || email.trimmingCharacters(in: .whitespaces).isEmpty)
                }

                if let fehler {
                    Text(fehler)
                        .font(.system(size: 11))
                        .foregroundColor(.red)
                }

                // Die Offenlegung gehört ans Feld, nicht in eine Fußnote: Hier tippt
                // jemand in einer Banking-App eine Adresse ein, die das Gerät verlässt.
                (Text(L10n.t("Nur deine Adresse — keine Konto- oder Umsatzdaten. Versand über Formspree (USA). Abmelden jederzeit per Antwort. ",
                             "Your address only — no account or transaction data. Delivered via Formspree (USA). Unsubscribe any time by replying. "))
                 + Text(L10n.t("Datenschutz", "Privacy")).underline())
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .onTapGesture {
                        if let url = URL(string: "https://simplebanking.de/datenschutz") {
                            NSWorkspace.shared.open(url)
                        }
                    }
            }
        }
    }

    private func eintragen() {
        guard !laeuft else { return }
        fehler = nil
        let adresse = email
        laeuft = true
        Task {
            let ergebnis = await NewsletterSignup.subscribe(email: adresse, source: source)
            laeuft = false
            switch ergebnis {
            case .success:
                fertig = true
                email = ""
            case .failure(let e):
                fehler = e.errorDescription
            }
        }
    }
}
