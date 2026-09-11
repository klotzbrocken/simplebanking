import Foundation

enum AICategorizationService {
    static let enabledKey = "aiCategorizationEnabled"

    private static let validCategoryKeys: Set<String> = [
        "gastronomie", "sparen", "freizeit", "gehalt", "gesundheit",
        "umbuchung", "einkaufen", "transport", "versicherung", "sonstiges"
    ]

    /// Runs AI categorization if enabled. Designed for fire-and-forget background use.
    ///
    /// Fehler werden nicht mehr verschluckt, sondern protokolliert: Bis zum 11.09.2026
    /// scheiterte jeder Aufruf still am abgeschalteten Modell `claude-3-5-haiku-latest`,
    /// und niemand konnte es sehen — die Kategorien blieben einfach leer. Die Kategorie
    /// bleibt bei einem Fehler weiterhin unverändert; nur das Log weiß jetzt Bescheid.
    static func runIfEnabled(masterPassword: String) async {
        guard UserDefaults.standard.bool(forKey: enabledKey) else { return }
        let provider = AIProvider.active
        guard let apiKey = try? CredentialsStore.loadAPIKey(forProvider: provider, masterPassword: masterPassword),
              !apiKey.isEmpty else {
            AppLogger.log("Kategorisierung: aktiv, aber kein API-Key für \(provider.rawValue) hinterlegt", category: "AI", level: "WARN")
            return
        }

        let records: [TransactionRecord]
        let slotId = await MainActor.run { MultibankingStore.shared.activeSlot?.id ?? "legacy" }
        do {
            records = try TransactionsDatabase.loadRecordsForCategorization(slotId: slotId)
        } catch { return }
        guard !records.isEmpty else { return }
        AppLogger.log("Kategorisierung: \(records.count) Buchungen ohne Kategorie, Anbieter \(provider.rawValue)", category: "AI")
        var zugeordnet = 0
        var fehler = 0

        // Batch max 20 per call
        let batches = stride(from: 0, to: records.count, by: 20).map {
            Array(records[$0..<min($0 + 20, records.count)])
        }

        for batch in batches {
            let payload: [[String: String]] = batch.map { r in [
                "id":       r.txID,
                "recipient": r.empfaenger ?? r.absender ?? "",
                "purpose":  r.verwendungszweck ?? "",
                "amount":   String(r.betrag)
            ]}
            guard let jsonData = try? JSONSerialization.data(withJSONObject: payload),
                  let jsonText = String(data: jsonData, encoding: .utf8) else { continue }
            do {
                let response = try await AIProviderService.complete(
                    provider: provider, apiKey: apiKey,
                    systemPrompt: AIProviderService.CATEGORIZATION_SYSTEM_PROMPT,
                    userMessage: jsonText,
                    maxTokens: 600, temperature: 0.0)
                zugeordnet += applyResult(response, slotId: slotId)
            } catch {
                // Kategorie bleibt unverändert — aber der Grund steht im Log.
                fehler += 1
                AppLogger.log("Kategorisierung fehlgeschlagen (\(provider.rawValue)): \(error.localizedDescription)", category: "AI", level: "WARN")
            }
        }
        AppLogger.log("Kategorisierung: \(zugeordnet) Buchungen zugeordnet, \(fehler) von \(batches.count) Paketen fehlgeschlagen", category: "AI", level: fehler > 0 ? "WARN" : "INFO")
    }

    /// Übernimmt die Antwort in die Datenbank. Liefert die Zahl der tatsächlich gesetzten Kategorien.
    @discardableResult
    private static func applyResult(_ json: String, slotId: String) -> Int {
        guard let data = json.data(using: .utf8),
              let array = try? JSONSerialization.jsonObject(with: data) as? [[String: String]]
        else {
            AppLogger.log("Kategorisierung: Antwort war kein JSON-Array — \(json.prefix(120))", category: "AI", level: "WARN")
            return 0
        }

        var gesetzt = 0
        for item in array {
            guard let txID = item["id"],
                  let key = item["category"],
                  validCategoryKeys.contains(key),
                  let category = TransactionCategory.from(jsonKey: key)
            else { continue }
            if (try? TransactionsDatabase.updateKategorie(txID: txID, slotId: slotId, kategorie: category.displayName)) != nil {
                gesetzt += 1
            }
        }
        return gesetzt
    }
}
