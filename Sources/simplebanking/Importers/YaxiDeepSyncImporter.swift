import Foundation

/// Explicit "fetch older history" operation via YAXI. Bypasses the incremental-refresh
/// clamp in `YaxiService.clampSinceForRefresh` by first removing the slot's refresh
/// marker, then requesting the full window.
///
/// User-initiated, triggered from the Import-Sheet in Settings → Konten.
enum YaxiDeepSyncImporter {

    /// Deep-sync `days` of history for the given slot.
    /// Requires the user's master password to unlock `CredentialsStore`.
    ///
    /// - Parameter days: 180 or 365 — the window to force-refetch from the bank.
    /// - Note: May trigger SCA/TAN if YAXI consent has expired. Caller must be prepared.
    @MainActor
    static func importHistory(
        slotId: String,
        days: Int,
        masterPassword: String
    ) async throws -> ImportResult {
        // Switch active slot so credentials/session/database all target the right bank.
        let prevYaxiSlot = YaxiService.activeSlotId
        let prevCredsSlot = CredentialsStore.activeSlotId
        let prevDbSlot = TransactionsDatabase.activeSlotId
        YaxiService.activeSlotId = slotId
        CredentialsStore.activeSlotId = slotId
        TransactionsDatabase.activeSlotId = slotId
        defer {
            YaxiService.activeSlotId = prevYaxiSlot
            CredentialsStore.activeSlotId = prevCredsSlot
            TransactionsDatabase.activeSlotId = prevDbSlot
        }

        let creds: StoredCredentials
        do {
            creds = try CredentialsStore.load(masterPassword: masterPassword)
        } catch {
            AppLogger.log("DeepSync: credentials load failed: \(error.localizedDescription)",
                          category: "Import", level: "ERROR")
            throw ImportError.credentialsUnavailable
        }

        // Count rows before so we can report inserted vs duplicates.
        let countBefore = (try? TransactionsDatabase.loadTransactions(days: days).count) ?? 0

        let from = isoDate(daysAgo: days)
        AppLogger.log("DeepSync: slot=\(slotId.prefix(8)) days=\(days) from=\(from)", category: "Import")

        let resp: TransactionsResponse
        do {
            resp = try await YaxiService.fetchTransactions(
                userId: creds.userId,
                password: creds.password,
                from: from
            )
        } catch {
            throw ImportError.fetchFailed(error.localizedDescription)
        }

        guard resp.ok == true, let txs = resp.transactions, !txs.isEmpty else {
            if let msg = resp.userMessage ?? resp.error {
                throw ImportError.fetchFailed(msg)
            }
            return .empty
        }

        do {
            try TransactionsDatabase.upsert(transactions: txs)
        } catch {
            throw ImportError.databaseFailed(error.localizedDescription)
        }

        let countAfter = (try? TransactionsDatabase.loadTransactions(days: days).count) ?? countBefore
        let inserted = max(0, countAfter - countBefore)
        let duplicates = max(0, txs.count - inserted)

        AppLogger.log("DeepSync: done total=\(txs.count) inserted=\(inserted) duplicates=\(duplicates)",
                      category: "Import")
        return ImportResult(inserted: inserted, duplicates: duplicates)
    }

    private static func isoDate(daysAgo: Int) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.current
        let d = Date().addingTimeInterval(-Double(daysAgo) * 86_400)
        return f.string(from: d)
    }
}
