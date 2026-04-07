import Foundation

enum AICategorizationService {
    static let enabledKey = "aiCategorizationEnabled"

    private static let validCategoryKeys: Set<String> = [
        "gastronomie", "sparen", "freizeit", "gehalt", "gesundheit",
        "umbuchung", "einkaufen", "transport", "versicherung", "sonstiges"
    ]

    /// Runs AI categorization if enabled. Silent on any error. Designed for fire-and-forget background use.
    static func runIfEnabled(masterPassword: String) async {
        guard UserDefaults.standard.bool(forKey: enabledKey) else { return }
        let provider = AIProvider.active
        guard let apiKey = try? CredentialsStore.loadAPIKey(forProvider: provider, masterPassword: masterPassword),
              !apiKey.isEmpty else { return }

        let records: [TransactionRecord]
        do {
            let slotId = await MainActor.run { MultibankingStore.shared.activeSlot?.id ?? "legacy" }
            records = try TransactionsDatabase.loadRecordsForCategorization(slotId: slotId)
        } catch { return }
        guard !records.isEmpty else { return }

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
                applyResult(response)
            } catch {
                // Silent fail — leave existing category unchanged
            }
        }
    }

    private static func applyResult(_ json: String) {
        guard let data = json.data(using: .utf8),
              let array = try? JSONSerialization.jsonObject(with: data) as? [[String: String]]
        else { return }

        for item in array {
            guard let txID = item["id"],
                  let key = item["category"],
                  validCategoryKeys.contains(key),
                  let category = TransactionCategory.from(jsonKey: key)
            else { continue }
            try? TransactionsDatabase.updateKategorie(txID: txID, kategorie: category.displayName)
        }
    }
}
