import Foundation

/// „Ältere Umsätze holen" für einen PayPal-Slot.
///
/// **Warum es diese Datei gibt.** Das Import-Fenster schickte „Von der Bank laden"
/// bis zum 26.10.2026 ohne jede Fallunterscheidung in `YaxiDeepSyncImporter`. Ein
/// PayPal-Slot hat keine YAXI-Verbindungskennung, also scheiterte der Import mit
/// „Abruf fehlgeschlagen: no connectionId yet" — einer Meldung, die dem Nutzer
/// nichts sagt und nach einem Fehler seiner Zugangsdaten klingt. Gemeldet am
/// 25.10.2026.
///
/// Der Weg selbst war längst da: `PayPalService.fetchTransactions` nimmt die
/// Tageszahl schon immer entgegen, weil der normale Abruf sie ebenfalls braucht.
/// Gefehlt hat nur die Verzweigung.
enum PayPalDeepSyncImporter {

    /// - Parameter days: 180 oder 365 — das Fenster, das neu geholt wird.
    /// - Note: Ohne Freigabe-Maschinerie. PayPals klassische API kennt keine SCA;
    ///   die drei Werte aus dem Schlüsselbund genügen.
    @MainActor
    static func importHistory(
        slotId: String,
        days: Int,
        masterPassword: String
    ) async throws -> ImportResult {
        // Dieselbe Klammer wie beim YAXI-Pendant: Zugangsdaten und Datenbank hängen
        // am aktiven Slot, und der darf hinterher wieder der sein, der es vorher war.
        let snapshot = SlotContext.snapshot()
        SlotContext.activate(slotId: slotId)
        defer { SlotContext.restore(snapshot) }

        let gespeichert: StoredCredentials
        do {
            gespeichert = try CredentialsStore.load(masterPassword: masterPassword)
        } catch {
            AppLogger.log("PayPal-DeepSync: Zugangsdaten nicht lesbar: \(error.localizedDescription)",
                          category: "Import", level: "ERROR")
            throw ImportError.credentialsUnavailable
        }
        guard let user = gespeichert.paypalUser?.nilIfEmpty,
              let pwd = gespeichert.paypalPwd?.nilIfEmpty,
              let sig = gespeichert.paypalSignature?.nilIfEmpty else {
            throw ImportError.credentialsUnavailable
        }
        let creds = PayPalService.Credentials(user: user, pwd: pwd, signature: sig, sandbox: false)

        let vorher = (try? TransactionsDatabase.loadTransactions(days: days).count) ?? 0
        AppLogger.log("PayPal-DeepSync: slot=\(slotId.prefix(8)) days=\(days)", category: "Import")

        let umsaetze: [TransactionsResponse.Transaction]
        do {
            umsaetze = try await PayPalService.fetchTransactions(days: days, slotId: slotId, creds: creds)
        } catch {
            throw ImportError.fetchFailed(error.localizedDescription)
        }
        guard !umsaetze.isEmpty else { return .empty }

        do {
            try TransactionsDatabase.upsert(transactions: umsaetze, purgeStalePending: false)
        } catch {
            throw ImportError.databaseFailed(error.localizedDescription)
        }

        let nachher = (try? TransactionsDatabase.loadTransactions(days: days).count) ?? vorher
        let neu = max(0, nachher - vorher)
        let dubletten = max(0, umsaetze.count - neu)

        AppLogger.log("PayPal-DeepSync: fertig total=\(umsaetze.count) neu=\(neu) dubletten=\(dubletten)",
                      category: "Import")
        return ImportResult(inserted: neu, duplicates: dubletten)
    }
}
