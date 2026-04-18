import AppKit
import Foundation
import Routex
import Security
import UserNotifications

// MARK: - YaxiService
// Replaces NetworkService + BackendManager. Calls the YAXI API directly via
// routex-client-swift (Rust FFI). No Node.js process required.

enum YaxiService {

    // MARK: - Active slot ID (set by BalanceBar when switching accounts)
    // Thread-safe via lock. Async code should snapshot early to avoid mid-flight changes.

    private static let _slotLock = NSLock()
    nonisolated(unsafe) private static var _activeSlotId: String = "legacy"
    static var activeSlotId: String {
        get { _slotLock.lock(); defer { _slotLock.unlock() }; return _activeSlotId }
        set { _slotLock.lock(); defer { _slotLock.unlock() }; _activeSlotId = newValue }
    }

    /// Called on MainActor when a SCA/TAN confirmation is waiting (true) or done (false).
    nonisolated(unsafe) static var onTanStateChanged: (@MainActor (Bool) -> Void)?

    // MARK: - UserDefaults keys (per-slot)
    // "legacy" slot uses the original key names for backward compatibility.

    private static func slotSuffix(for slotId: String) -> String { slotId == "legacy" ? "" : ".\(slotId)" }
    private static func slotSuffix() -> String { slotSuffix(for: activeSlotId) }
    static func ibanKey(for slotId: String) -> String { "simplebanking.iban\(slotSuffix(for: slotId))" }
    static func connectionIdKey(for slotId: String) -> String { "simplebanking.yaxi.connectionId\(slotSuffix(for: slotId))" }
    static func credModelFullKey(for slotId: String) -> String { "simplebanking.yaxi.credModel.full\(slotSuffix(for: slotId))" }
    static func credModelUserIdKey(for slotId: String) -> String { "simplebanking.yaxi.credModel.userId\(slotSuffix(for: slotId))" }
    static func credModelNoneKey(for slotId: String) -> String { "simplebanking.yaxi.credModel.none\(slotSuffix(for: slotId))" }
    static var ibanKey: String { ibanKey(for: activeSlotId) }
    static var connectionIdKey: String { connectionIdKey(for: activeSlotId) }
    static var credModelFullKey: String { credModelFullKey(for: activeSlotId) }
    static var credModelUserIdKey: String { credModelUserIdKey(for: activeSlotId) }
    static var credModelNoneKey: String { credModelNoneKey(for: activeSlotId) }

    // MARK: - Session Store

    static let sessionStore = SessionStore()

    actor SessionStore {
        // On macOS standard Keychain, SecItemAdd always attaches an app-specific ACL
        // (bound to the code-signing identity) even when kSecAttrAccessible is set.
        // This means every new build with a different signature causes "wants to access
        // keychain" prompts — there is no way to avoid this without either:
        //   a) kSecUseDataProtectionKeychain (requires keychain-access-groups entitlement)
        //   b) Developer ID signing (stable identity → ACL persists across updates)
        //
        // Storage strategy (chosen at runtime):
        //   • Developer ID signed build → Keychain (stable ACL, encrypted at rest, no prompts)
        //   • Ad-hoc / unsigned build   → UserDefaults (no prompts; acceptable for dev/test)
        //
        // Credentials (IBAN/password) and the master password stay in Keychain regardless —
        // they are accessed via authenticated LAContext (Touch ID) which handles ACL correctly.

        private let kcService = "tech.yaxi.simplebanking"
        private let defaults  = UserDefaults.standard

        /// True when the running binary has a real Team ID (Developer ID / App Store signing).
        /// Ad-hoc and unsigned builds have no Team ID → use UserDefaults to avoid prompts.
        private static let useKeychain: Bool = {
            var staticCode: SecStaticCode?
            guard SecStaticCodeCreateWithPath(
                Bundle.main.bundleURL as CFURL, [], &staticCode
            ) == errSecSuccess, let staticCode else { return false }
            var info: CFDictionary?
            guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: 0), &info) == errSecSuccess else { return false }
            let teamID = (info as? [String: Any])?["team-identifier"] as? String
            let result = !(teamID?.isEmpty ?? true)
            AppLogger.log("SessionStore: useKeychain=\(result) teamID=\(teamID ?? "none")", category: "Keychain")
            return result
        }()

        private static func suffix(for slotId: String) -> String { slotId == "legacy" ? "" : ".\(slotId)" }
        private static func udKey(_ base: String, slotId: String) -> String {
            "simplebanking.yaxi.\(base)\(suffix(for: slotId))"
        }
        private static func kcAccount(_ base: String, slotId: String) -> String {
            "\(base)\(suffix(for: slotId)).kc3"
        }

        private var balancesSession: Data?
        private var transactionsSession: Data?
        private var storedConnectionData: Data?

        // MARK: - Keychain primitives

        private static func kcRead(account: String) -> Data? {
            let q: [CFString: Any] = [
                kSecClass:       kSecClassGenericPassword,
                kSecAttrService: "tech.yaxi.simplebanking",
                kSecAttrAccount: account,
                kSecReturnData:  true,
                kSecMatchLimit:  kSecMatchLimitOne
            ]
            var result: CFTypeRef?
            guard SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess else { return nil }
            return result as? Data
        }

        private func kcWrite(account: String, data: Data) {
            SecItemDelete([kSecClass: kSecClassGenericPassword,
                           kSecAttrService: kcService,
                           kSecAttrAccount: account] as CFDictionary)
            let status = SecItemAdd([kSecClass:          kSecClassGenericPassword,
                                     kSecAttrService:    kcService,
                                     kSecAttrAccount:    account,
                                     kSecAttrAccessible: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
                                     kSecValueData:      data] as CFDictionary, nil)
            if status != errSecSuccess {
                AppLogger.log("kcWrite failed: \(status) account=\(account)", category: "Keychain", level: "WARN")
            }
        }

        private func kcDelete(account: String) {
            SecItemDelete([kSecClass: kSecClassGenericPassword,
                           kSecAttrService: kcService,
                           kSecAttrAccount: account] as CFDictionary)
        }

        /// Silently removes ALL session items left by older builds from the Keychain.
        /// SecItemDelete on ACL-protected items from other builds fails silently (no UI).
        static func purgeOldKeychainItems() {
            let status = SecItemDelete([
                kSecClass:       kSecClassGenericPassword,
                kSecAttrService: "tech.yaxi.simplebanking",
                kSecMatchLimit:  kSecMatchLimitAll
            ] as CFDictionary)
            AppLogger.log("purgeOldKeychainItems: status=\(status)", category: "Keychain")
        }

        // MARK: - Read / Write helpers (dispatch to Keychain or UserDefaults)

        private static func persistRead(_ base: String, slotId: String) -> Data? {
            if useKeychain {
                return kcRead(account: kcAccount(base, slotId: slotId))
            }
            let sfx = suffix(for: slotId)
            return UserDefaults.standard.string(forKey: "simplebanking.yaxi.\(base)\(sfx)")
                .flatMap { Data(base64Encoded: $0) }
        }

        private func persistWrite(_ base: String, slotId: String, data: Data) {
            if SessionStore.useKeychain {
                kcWrite(account: SessionStore.kcAccount(base, slotId: slotId), data: data)
            } else {
                let sfx = SessionStore.suffix(for: slotId)
                defaults.set(data.base64EncodedString(),
                             forKey: "simplebanking.yaxi.\(base)\(sfx)")
            }
        }

        private func persistDelete(_ base: String, slotId: String) {
            if SessionStore.useKeychain {
                kcDelete(account: SessionStore.kcAccount(base, slotId: slotId))
            } else {
                let sfx = SessionStore.suffix(for: slotId)
                defaults.removeObject(forKey: "simplebanking.yaxi.\(base)\(sfx)")
            }
        }

        // MARK: - Init

        init() {
            // Legacy (no-suffix) slot. Try primary storage first, then UserDefaults migration.
            let ud = UserDefaults.standard
            let legB64 = ud.string(forKey: "simplebanking.yaxi.session")
            balancesSession = SessionStore.persistRead("session.balances", slotId: "legacy")
                ?? (ud.string(forKey: "simplebanking.yaxi.session.balances") ?? legB64)
                    .flatMap { Data(base64Encoded: $0) }
            transactionsSession = SessionStore.persistRead("session.transactions", slotId: "legacy")
                ?? (ud.string(forKey: "simplebanking.yaxi.session.transactions") ?? legB64)
                    .flatMap { Data(base64Encoded: $0) }
            storedConnectionData = SessionStore.persistRead("connectionData", slotId: "legacy")
                ?? ud.string(forKey: "simplebanking.yaxi.connectionData")
                    .flatMap { Data(base64Encoded: $0) }
        }

        // MARK: - Public API

        func session(for scope: Scope) -> Data? {
            switch scope {
            case .balances:     return balancesSession
            case .transactions: return transactionsSession
            }
        }

        func connectionData() -> Data? { storedConnectionData }

        func update(scope: Scope, session: Data?, connectionData: Data?, slotId: String? = nil) {
            let sid = slotId ?? YaxiService.activeSlotId
            if let s = session {
                switch scope {
                case .balances:
                    balancesSession = s
                    persistWrite("session.balances", slotId: sid, data: s)
                case .transactions:
                    transactionsSession = s
                    persistWrite("session.transactions", slotId: sid, data: s)
                }
            }
            if let cd = connectionData {
                storedConnectionData = cd
                persistWrite("connectionData", slotId: sid, data: cd)
            }
        }

        func updateConnectionData(_ connectionData: Data?, slotId: String? = nil) {
            let sid = slotId ?? YaxiService.activeSlotId
            guard let connectionData else { return }
            storedConnectionData = connectionData
            persistWrite("connectionData", slotId: sid, data: connectionData)
        }

        func clearAll(slotId: String? = nil) {
            let sid = slotId ?? YaxiService.activeSlotId
            balancesSession = nil; transactionsSession = nil; storedConnectionData = nil
            persistDelete("session.balances",    slotId: sid)
            persistDelete("session.transactions", slotId: sid)
            persistDelete("connectionData",       slotId: sid)
            defaults.removeObject(forKey: "simplebanking.yaxi.session")
            defaults.removeObject(forKey: "simplebanking.yaxi.session.balances\(SessionStore.suffix(for: sid))")
            defaults.removeObject(forKey: "simplebanking.yaxi.session.transactions\(SessionStore.suffix(for: sid))")
            defaults.removeObject(forKey: "simplebanking.yaxi.connectionData\(SessionStore.suffix(for: sid))")
        }

        func clearSessionsOnly(slotId: String? = nil) {
            let sid = slotId ?? YaxiService.activeSlotId
            balancesSession = nil; transactionsSession = nil
            persistDelete("session.balances",    slotId: sid)
            persistDelete("session.transactions", slotId: sid)
            defaults.removeObject(forKey: "simplebanking.yaxi.session")
            defaults.removeObject(forKey: "simplebanking.yaxi.session.balances\(SessionStore.suffix(for: sid))")
            defaults.removeObject(forKey: "simplebanking.yaxi.session.transactions\(SessionStore.suffix(for: sid))")
        }

        func clearConnectionDataOnly(slotId: String? = nil) {
            let sid = slotId ?? YaxiService.activeSlotId
            storedConnectionData = nil
            persistDelete("connectionData", slotId: sid)
            defaults.removeObject(forKey: "simplebanking.yaxi.connectionData\(SessionStore.suffix(for: sid))")
        }

        func reloadForActiveSlot() {
            let sid = YaxiService.activeSlotId
            let sfx = SessionStore.suffix(for: sid)
            let legB64 = sfx.isEmpty ? defaults.string(forKey: "simplebanking.yaxi.session") : nil
            balancesSession = SessionStore.persistRead("session.balances", slotId: sid)
                ?? (defaults.string(forKey: "simplebanking.yaxi.session.balances\(sfx)") ?? legB64)
                    .flatMap { Data(base64Encoded: $0) }
            transactionsSession = SessionStore.persistRead("session.transactions", slotId: sid)
                ?? (defaults.string(forKey: "simplebanking.yaxi.session.transactions\(sfx)") ?? legB64)
                    .flatMap { Data(base64Encoded: $0) }
            storedConnectionData = SessionStore.persistRead("connectionData", slotId: sid)
                ?? defaults.string(forKey: "simplebanking.yaxi.connectionData\(sfx)")
                    .flatMap { Data(base64Encoded: $0) }
            AppLogger.log("reloadForActiveSlot: slot=\(sid.prefix(8)) useKC=\(SessionStore.useKeychain) cd=\(storedConnectionData == nil ? "nil" : "\(storedConnectionData!.count)b") bal=\(balancesSession == nil ? "nil" : "ok")", category: "YaxiService")
        }

        func copyConnectionDataAndSessions(fromSlotId: String, toSlotId: String) {
            for key in ["connectionData", "session.balances", "session.transactions"] {
                if let data = SessionStore.persistRead(key, slotId: fromSlotId) {
                    persistWrite(key, slotId: toSlotId, data: data)
                }
            }
        }

        func clearLegacySessionData() {
            persistDelete("session.balances",    slotId: "legacy")
            persistDelete("session.transactions", slotId: "legacy")
            persistDelete("connectionData",       slotId: "legacy")
            defaults.removeObject(forKey: "simplebanking.yaxi.session")
            defaults.removeObject(forKey: "simplebanking.yaxi.session.balances")
            defaults.removeObject(forKey: "simplebanking.yaxi.session.transactions")
            defaults.removeObject(forKey: "simplebanking.yaxi.connectionData")
            if YaxiService.activeSlotId == "legacy" {
                balancesSession = nil; transactionsSession = nil; storedConnectionData = nil
            }
            AppLogger.log("clearLegacySessionData: legacy slot cleared", category: "YaxiService")
        }

        enum Scope { case balances, transactions }
    }

    // Throttle re-opening the bank redirect URL (< 290 s cooldown).
    private static nonisolated(unsafe) var lastRedirectOpenedAt: Date? = nil


    // MARK: - Public API

    /// Stores the IBAN and resets connection state (mirrors POST /config).
    static func copyConnectionState(fromSlotId: String, toSlotId: String) async {
        await sessionStore.copyConnectionDataAndSessions(fromSlotId: fromSlotId, toSlotId: toSlotId)
    }

    static func configureBackend(iban: String) async -> Bool {
        let normalized = iban
            .replacingOccurrences(of: " ", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
        guard !normalized.isEmpty else { return false }
        let d = UserDefaults.standard
        d.set(normalized, forKey: ibanKey)
        d.removeObject(forKey: connectionIdKey)
        d.removeObject(forKey: credModelFullKey)
        d.removeObject(forKey: credModelUserIdKey)
        d.removeObject(forKey: credModelNoneKey)
        await sessionStore.clearAll()
        return true
    }

    /// Live bank search using the YAXI search API.
    /// Query is split into individual terms (one per word ≥ 2 chars) as recommended by YAXI docs.
    static func searchBanks(query: String) async -> [ConnectionInfo] {
        let terms = query.split(separator: " ")
            .map { String($0) }
            .filter { $0.count >= 2 }
        guard !terms.isEmpty else { return [] }
        let client = RoutexClient()
        let ticket = YaxiTicketMaker.issueTicket(service: "Accounts")
        do {
            return try await client.search(
                ticket: ticket,
                filters: terms.map { .term(term: $0) },
                ibanDetection: false,
                limit: 50
            )
        } catch {
            AppLogger.log("searchBanks('\(query)') failed: \(error.localizedDescription)", category: "YaxiService", level: "WARN")
            return []
        }
    }

    /// Persists a YAXI ConnectionInfo as the active bank for the current slot.
    /// Called from the setup wizard immediately after the user selects a bank.
    static func storeConnectionInfo(_ info: ConnectionInfo) {
        let d = UserDefaults.standard
        d.set(info.id, forKey: connectionIdKey)
        d.set(info.credentials.full,   forKey: credModelFullKey)
        d.set(info.credentials.userId, forKey: credModelUserIdKey)
        d.set(info.credentials.none,   forKey: credModelNoneKey)
        AppLogger.log("storeConnectionInfo: connId=\(info.id.prefix(8)) name=\(info.displayName)", category: "YaxiService")
    }

    /// Clears connection state without storing an IBAN (for accounts() flow).
    static func clearConnectionState() async {
        let d = UserDefaults.standard
        d.removeObject(forKey: ibanKey)
        d.removeObject(forKey: connectionIdKey)
        d.removeObject(forKey: credModelFullKey)
        d.removeObject(forKey: credModelUserIdKey)
        d.removeObject(forKey: credModelNoneKey)
        await sessionStore.clearAll()
    }

    /// Clears only session data (connectionData + in-memory sessions) without touching
    /// connectionId or credential model keys. Use at setup start when the bank was already
    /// selected (connectionId is set) but stale sessions from other slots must be wiped
    /// to prevent "FGW Fehlender Dialogkontext" for FinTS banks.
    static func clearSessionOnly() async {
        await sessionStore.clearAll()
    }

    /// Searches for the bank matching the stored IBAN and persists the connection ID.
    static func discoverBank() async -> DiscoveredBank? {
        let iban = UserDefaults.standard.string(forKey: ibanKey) ?? ""
        guard !iban.isEmpty else {
            AppLogger.log("discoverBank: no IBAN stored", category: "YaxiService", level: "WARN")
            return nil
        }

        let client = RoutexClient()
        let ticket = YaxiTicketMaker.issueTicket(service: "Accounts")
        do {
            let results = try await client.search(
                ticket: ticket,
                filters: [.term(term: iban)],
                ibanDetection: true,
                limit: 20
            )
            guard let pick = results.first else {
                AppLogger.log("discoverBank: no connections found", category: "YaxiService", level: "WARN")
                return nil
            }

            let d = UserDefaults.standard
            d.set(pick.id, forKey: connectionIdKey)
            d.set(pick.credentials.full, forKey: credModelFullKey)
            d.set(pick.credentials.userId, forKey: credModelUserIdKey)
            d.set(pick.credentials.none, forKey: credModelNoneKey)

            AppLogger.log("discoverBank: found \(pick.displayName)", category: "YaxiService")
            return DiscoveredBank(
                id: pick.id,
                displayName: pick.displayName,
                logoId: pick.logoId,
                credentials: DiscoveredBankCredentials(
                    full: pick.credentials.full,
                    userId: pick.credentials.userId,
                    none: pick.credentials.none
                ),
                userIdLabel: pick.userId?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
                advice: pick.advice?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            )
        } catch {
            AppLogger.log("discoverBank failed: \(error.localizedDescription)", category: "YaxiService", level: "ERROR")
            return nil
        }
    }

    /// Searches for bank by display name/term and persists the connection ID.
    /// Used in accounts() flow where IBAN is not known upfront.
    static func discoverBankByTerm(_ term: String) async -> DiscoveredBank? {
        let client = RoutexClient()
        let ticket = YaxiTicketMaker.issueTicket(service: "Accounts")
        do {
            let results = try await client.search(
                ticket: ticket,
                filters: [.term(term: term)],
                ibanDetection: false,
                limit: 20
            )
            guard let pick = results.first else {
                AppLogger.log("discoverBankByTerm: no connections found for '\(term)'", category: "YaxiService", level: "WARN")
                return nil
            }
            let d = UserDefaults.standard
            d.set(pick.id, forKey: connectionIdKey)
            d.set(pick.credentials.full, forKey: credModelFullKey)
            d.set(pick.credentials.userId, forKey: credModelUserIdKey)
            d.set(pick.credentials.none, forKey: credModelNoneKey)
            AppLogger.log("discoverBankByTerm: found \(pick.displayName)", category: "YaxiService")
            return DiscoveredBank(
                id: pick.id,
                displayName: pick.displayName,
                logoId: pick.logoId,
                credentials: DiscoveredBankCredentials(
                    full: pick.credentials.full,
                    userId: pick.credentials.userId,
                    none: pick.credentials.none
                ),
                userIdLabel: pick.userId?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
                advice: pick.advice?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            )
        } catch {
            AppLogger.log("discoverBankByTerm failed: \(error.localizedDescription)", category: "YaxiService", level: "ERROR")
            return nil
        }
    }

    /// Stores a discovered IBAN without clearing connectionId or session state.
    static func storeDiscoveredIBAN(_ iban: String) {
        let normalized = iban.uppercased().replacingOccurrences(of: " ", with: "")
        UserDefaults.standard.set(normalized, forKey: ibanKey)
    }

    /// Calls accounts() API with SCA and returns discovered accounts.
    static func fetchAccounts(userId: String, password: String) async throws -> [Routex.Account] {
        let slotSnapshot = activeSlotId
        let connIdKey = connectionIdKey(for: slotSnapshot)
        let model = loadCredentialsModel(slotId: slotSnapshot)
        let d = UserDefaults.standard
        guard let connectionId = d.string(forKey: connIdKey), !connectionId.isEmpty else {
            throw NSError(domain: "YaxiService", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "no connectionId for accounts()"])
        }
        let storedCD = await sessionStore.connectionData()
        var storedSession = await sessionStore.session(for: .balances)
        let creds = buildCredentials(
            connectionId: connectionId, model: model,
            connectionData: storedCD, userId: userId, password: password
        )

        let client = RoutexClient()
        // `var` so the retry can issue a fresh ticket — after UnexpectedError the old
        // ticket's server-side state is undefined and reusing it risks another failure.
        var ticket = YaxiTicketMaker.issueTicket(service: "Accounts")

        AppLogger.log("fetchAccounts: slot=\(slotSnapshot.prefix(8)) connId=\(connectionId.prefix(8)) session=\(storedSession == nil ? "nil" : "present")", category: "YaxiService")

        let resp: Routex.AccountsResponse
        do {
            resp = try await client.accounts(
                credentials: creds,
                session: storedSession,
                recurringConsents: true,
                ticket: ticket,
                fields: [.iban, .displayName, .ownerName, .currency],
                filter: .ibanNotEq(value: nil)
            )
        } catch let error as RoutexClientError {
            // Retry once with a fresh ticket:
            // - stale/expired session token → clear it, retry without
            // - transient server error (new account, nil session) → retry fresh
            if storedSession != nil {
                AppLogger.log("fetchAccounts: error with session token, clearing and retrying: \(error)", category: "YaxiService", level: "WARN")
                await sessionStore.clearSessionsOnly(slotId: slotSnapshot)
                storedSession = nil
            } else {
                AppLogger.log("fetchAccounts: transient error, retrying with fresh ticket: \(error)", category: "YaxiService", level: "WARN")
            }
            ticket = YaxiTicketMaker.issueTicket(service: "Accounts")
            resp = try await client.accounts(
                credentials: creds,
                session: nil,
                recurringConsents: true,
                ticket: ticket,
                fields: [.iban, .displayName, .ownerName, .currency],
                filter: .ibanNotEq(value: nil)
            )
        }

        // Snapshot the final ticket value so @Sendable closures capture an immutable copy.
        let finalTicket = ticket
        let confirm: @Sendable (ConfirmationContext) async throws -> SCACommon = { ctx in
            try await toSCACommon(client.confirmAccounts(ticket: finalTicket, context: ctx))
        }
        let respond: @Sendable (InputContext, String) async throws -> SCACommon = { ctx, r in
            try await toSCACommon(client.respondAccounts(ticket: finalTicket, context: ctx, response: r))
        }

        guard let outcome = await handleSCA(
            initial: toSCACommon(resp), client: client, ticket: finalTicket,
            confirm: confirm, respond: respond
        ) else {
            throw NSError(domain: "YaxiService", code: -2,
                          userInfo: [NSLocalizedDescriptionKey: "Konten: Freigabe konnte nicht abgeschlossen werden (Schritt 1 von 3). Bitte erneut verbinden."])
        }

        // Accounts establishes recurring consent and fresh connectionData for follow-up
        // service calls, but its session must not bleed into balances/transactions.
        await sessionStore.updateConnectionData(outcome.connectionData, slotId: slotSnapshot)

        guard case .accounts(let authResult) = outcome.payload else {
            throw NSError(domain: "YaxiService", code: -3,
                          userInfo: [NSLocalizedDescriptionKey: "unexpected result type from accounts()"])
        }
        return authResult.toData().data
    }

    static func fetchBalances(userId: String, password: String) async throws -> BalancesResponse {
        // Snapshot slot ID immediately — activeSlotId may change during async fetch
        let slotSnapshot = activeSlotId
        let connIdKey = connectionIdKey(for: slotSnapshot)
        let ibanKeySnap = ibanKey(for: slotSnapshot)
        let model = loadCredentialsModel(slotId: slotSnapshot)
        let d = UserDefaults.standard
        guard let connectionId = d.string(forKey: connIdKey), !connectionId.isEmpty else {
            return BalancesResponse(ok: false, booked: nil, expected: nil, session: nil,
                                   connectionData: nil, error: "no connectionId yet",
                                   userMessage: nil, scaRequired: nil)
        }
        let iban = d.string(forKey: ibanKeySnap) ?? ""
        // If no IBAN stored yet (first setup), request all accounts (empty list) so YAXI
        // returns balances for all accounts. We then extract and store the IBAN from the
        // first result. This avoids the accounts() SCA which doesn't complete on many banks.
        let accountRefs: [AccountReference] = iban.isEmpty
            ? []
            : [AccountReference(id: .iban(iban), currency: "EUR")]

        let storedCD = await sessionStore.connectionData()
        let storedSession = await sessionStore.session(for: .balances)
        let creds = buildCredentials(
            connectionId: connectionId, model: model,
            connectionData: storedCD, userId: userId, password: password
        )

        let client = RoutexClient()
        let ticket = YaxiTicketMaker.issueTicket(service: "Balances")

        AppLogger.log("fetchBalances: slot=\(slotSnapshot.prefix(8)) connId=\(connectionId.prefix(8)) iban=\(iban.isEmpty ? "(auto)" : String(iban.prefix(8))) cd=\(storedCD == nil ? "nil" : "\(storedCD!.count)b")", category: "YaxiService")

        do {
            var resp: Routex.BalancesResponse
            do {
                resp = try await client.balances(
                    credentials: creds,
                    session: storedSession,
                    recurringConsents: true,
                    ticket: ticket,
                    accounts: accountRefs
                )
            } catch {
                // Retry without userId for banks that report "does not support a user id"
                if shouldRetryWithoutUserId(error: error, model: model, userId: userId) {
                    let credsNoUserId = buildCredentials(
                        connectionId: connectionId, model: model,
                        connectionData: storedCD, userId: nil, password: password
                    )
                    resp = try await client.balances(
                        credentials: credsNoUserId,
                        session: storedSession,
                        recurringConsents: true,
                        ticket: ticket,
                        accounts: accountRefs
                    )
                } else if storedSession != nil {
                    // Retry without session token (e.g. Revolut/Open Banking returns
                    // UnexpectedError when a stale YAXI session token is sent)
                    AppLogger.log("fetchBalances: error with session, retrying without: \(error)", category: "YaxiService", level: "WARN")
                    await sessionStore.clearSessionsOnly(slotId: slotSnapshot)
                    resp = try await client.balances(
                        credentials: creds,
                        session: nil,
                        recurringConsents: true,
                        ticket: ticket,
                        accounts: accountRefs
                    )
                } else if isConnectionResetError(error), storedCD != nil {
                    // Consent abgelaufen (Unauthorized / ConsentExpired):
                    // YAXI-Empfehlung: gleiche Anfrage ohne connectionData wiederholen —
                    // die Bank erneuert den Consent und liefert neue connectionData zurück.
                    AppLogger.log("fetchBalances: consent expired, retrying without connectionData", category: "YaxiService", level: "WARN")
                    let credsNoCD = buildCredentials(
                        connectionId: connectionId, model: model,
                        connectionData: nil, userId: userId, password: password
                    )
                    resp = try await client.balances(
                        credentials: credsNoCD,
                        session: storedSession,
                        recurringConsents: true,
                        ticket: ticket,
                        accounts: accountRefs
                    )
                } else if isRequestError(error) {
                    // Netzwerkfehler: einmal automatisch wiederholen (YAXI-Empfehlung).
                    AppLogger.log("fetchBalances: network error, retrying once: \(error)", category: "YaxiService", level: "WARN")
                    resp = try await client.balances(
                        credentials: creds,
                        session: storedSession,
                        recurringConsents: true,
                        ticket: ticket,
                        accounts: accountRefs
                    )
                } else {
                    throw error
                }
            }

            let confirm: @Sendable (ConfirmationContext) async throws -> SCACommon = { ctx in
                try await toSCACommon(client.confirmBalances(ticket: ticket, context: ctx))
            }
            let respond: @Sendable (InputContext, String) async throws -> SCACommon = { ctx, r in
                try await toSCACommon(client.respondBalances(ticket: ticket, context: ctx, response: r))
            }

            guard let outcome = await handleSCA(
                initial: toSCACommon(resp), client: client, ticket: ticket,
                confirm: confirm, respond: respond
            ) else {
                return BalancesResponse(ok: false, booked: nil, expected: nil, session: nil,
                                       connectionData: nil, error: nil,
                                       userMessage: nil, scaRequired: true)
            }

            AppLogger.log("fetchBalances: outcome.connectionData=\(outcome.connectionData == nil ? "nil" : "\(outcome.connectionData!.count)b")", category: "YaxiService")
            await sessionStore.update(scope: .balances,
                                      session: outcome.session,
                                      connectionData: outcome.connectionData,
                                      slotId: slotSnapshot)

            guard case .balances(let result) = outcome.payload else {
                return BalancesResponse(ok: false, booked: nil, expected: nil, session: nil,
                                       connectionData: nil, error: "unexpected result type",
                                       userMessage: nil, scaRequired: nil)
            }
            // When called without IBAN (first setup), extract and persist IBAN from response
            if iban.isEmpty {
                if case .iban(let discovered) = result.toData().data.balances.first?.account.id {
                    AppLogger.log("fetchBalances: auto-stored IBAN prefix=\(String(discovered.prefix(8)))", category: "YaxiService")
                    storeDiscoveredIBAN(discovered)
                }
            }
            return makeBalancesResponse(result, session: outcome.session, connectionData: outcome.connectionData)

        } catch {
            await writeTrace(client: client, label: "fetchBalances", ticket: ticket, error: error)
            AppLogger.log("fetchBalances error: \(error.localizedDescription)", category: "YaxiService", level: "ERROR")
            if isConnectionResetError(error) {
                AppLogger.log("fetchBalances: clearing ALL state after auth reset", category: "YaxiService")
                await sessionStore.clearAll(slotId: slotSnapshot)
            } else if isObsoleteSessionError(error) || isHBCITransientError(error) {
                // HBCI gateway errors and obsolete sessions: keep connectionData, just reset sessions.
                // Avoids forcing full 2FA re-auth for transient HBCI infrastructure hiccups.
                AppLogger.log("fetchBalances: clearing sessions only (HBCI transient or obsolete)", category: "YaxiService")
                await sessionStore.clearSessionsOnly(slotId: slotSnapshot)
            }
            throw error
        }
    }

    static func fetchTransactions(userId: String, password: String, from: String) async throws -> TransactionsResponse {
        // Snapshot slot ID immediately — activeSlotId may change during async fetch
        let slotSnapshot = activeSlotId
        let connIdKey = connectionIdKey(for: slotSnapshot)
        let ibanKeySnap = ibanKey(for: slotSnapshot)
        let model = loadCredentialsModel(slotId: slotSnapshot)
        let d = UserDefaults.standard
        guard let connectionId = d.string(forKey: connIdKey), !connectionId.isEmpty else {
            return TransactionsResponse(ok: false, transactions: nil, session: nil,
                                       connectionData: nil, error: "no connectionId yet",
                                       userMessage: nil, scaRequired: nil)
        }
        let iban = d.string(forKey: ibanKeySnap) ?? ""
        guard !iban.isEmpty else {
            return TransactionsResponse(ok: false, transactions: nil, session: nil,
                                       connectionData: nil, error: "missing iban",
                                       userMessage: nil, scaRequired: nil)
        }
        let storedCD = await sessionStore.connectionData()
        AppLogger.log("fetchTransactions: storedCD=\(storedCD == nil ? "nil" : "\(storedCD!.count)b") model.none=\(model.none)", category: "YaxiService")
        let storedSession = await sessionStore.session(for: .transactions)
        let creds = buildCredentials(
            connectionId: connectionId, model: model,
            connectionData: storedCD, userId: userId, password: password
        )

        let client = RoutexClient()
        let ticket = YaxiTicketMaker.issueTransactionsTicket(iban: iban, from: from)

        AppLogger.log("fetchTransactions from=\(from)", category: "YaxiService")

        do {
            var resp: Routex.TransactionsResponse
            do {
                resp = try await client.transactions(
                    credentials: creds,
                    session: storedSession,
                    recurringConsents: true,
                    ticket: ticket
                )
            } catch {
                if shouldRetryWithoutUserId(error: error, model: model, userId: userId) {
                    let credsNoUserId = buildCredentials(
                        connectionId: connectionId, model: model,
                        connectionData: storedCD, userId: nil, password: password
                    )
                    resp = try await client.transactions(
                        credentials: credsNoUserId,
                        session: storedSession,
                        recurringConsents: true,
                        ticket: ticket
                    )
                } else if storedSession != nil {
                    AppLogger.log("fetchTransactions: error with session, retrying without: \(error)", category: "YaxiService", level: "WARN")
                    await sessionStore.clearSessionsOnly(slotId: slotSnapshot)
                    resp = try await client.transactions(
                        credentials: creds,
                        session: nil,
                        recurringConsents: true,
                        ticket: ticket
                    )
                } else if isConnectionResetError(error), storedCD != nil {
                    // Consent abgelaufen (Unauthorized / ConsentExpired):
                    // YAXI-Empfehlung: gleiche Anfrage ohne connectionData wiederholen.
                    AppLogger.log("fetchTransactions: consent expired, retrying without connectionData", category: "YaxiService", level: "WARN")
                    let credsNoCD = buildCredentials(
                        connectionId: connectionId, model: model,
                        connectionData: nil, userId: userId, password: password
                    )
                    resp = try await client.transactions(
                        credentials: credsNoCD,
                        session: storedSession,
                        recurringConsents: true,
                        ticket: ticket
                    )
                } else if isRequestError(error) {
                    // Netzwerkfehler: einmal automatisch wiederholen (YAXI-Empfehlung).
                    AppLogger.log("fetchTransactions: network error, retrying once: \(error)", category: "YaxiService", level: "WARN")
                    resp = try await client.transactions(
                        credentials: creds,
                        session: storedSession,
                        recurringConsents: true,
                        ticket: ticket
                    )
                } else {
                    throw error
                }
            }

            let confirm: @Sendable (ConfirmationContext) async throws -> SCACommon = { ctx in
                try await toSCACommon(client.confirmTransactions(ticket: ticket, context: ctx))
            }
            let respond: @Sendable (InputContext, String) async throws -> SCACommon = { ctx, r in
                try await toSCACommon(client.respondTransactions(ticket: ticket, context: ctx, response: r))
            }

            guard let outcome = await handleSCA(
                initial: toSCACommon(resp), client: client, ticket: ticket,
                confirm: confirm, respond: respond
            ) else {
                return TransactionsResponse(ok: false, transactions: nil, session: nil,
                                           connectionData: nil, error: nil,
                                           userMessage: nil, scaRequired: true)
            }

            await sessionStore.update(scope: .transactions,
                                      session: outcome.session,
                                      connectionData: outcome.connectionData,
                                      slotId: slotSnapshot)

            guard case .transactions(let result) = outcome.payload else {
                return TransactionsResponse(ok: false, transactions: nil, session: nil,
                                           connectionData: nil, error: "unexpected result type",
                                           userMessage: nil, scaRequired: nil)
            }
            return makeTransactionsResponse(result, session: outcome.session, connectionData: outcome.connectionData)

        } catch {
            await writeTrace(client: client, label: "fetchTransactions", ticket: ticket, error: error)
            AppLogger.log("fetchTransactions error: \(error.localizedDescription)", category: "YaxiService", level: "ERROR")
            if isConnectionResetError(error) {
                AppLogger.log("fetchTransactions: clearing ALL state after auth reset", category: "YaxiService")
                await sessionStore.clearAll(slotId: slotSnapshot)
            } else if isObsoleteSessionError(error) || isHBCITransientError(error) {
                AppLogger.log("fetchTransactions: clearing sessions only (HBCI transient or obsolete)", category: "YaxiService")
                await sessionStore.clearSessionsOnly(slotId: slotSnapshot)
            }
            throw error
        }
    }

    /// Lightweight bank search for as-you-type IBAN preview. No side-effects.
    static func previewBank(iban: String) async -> DiscoveredBank? {
        let normalized = iban
            .replacingOccurrences(of: " ", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
        guard normalized.count >= 15 else { return nil }

        // Extract BLZ for DE IBANs (chars 4–11) as fallback search term
        let blz: String? = normalized.hasPrefix("DE") && normalized.count >= 12
            ? String(normalized.dropFirst(4).prefix(8))
            : nil

        let client = RoutexClient()

        func searchWith(term: String, ibanDetection: Bool) async -> DiscoveredBank? {
            let ticket = YaxiTicketMaker.issueTicket(service: "Accounts")
            guard let results = try? await client.search(
                ticket: ticket,
                filters: [.term(term: term)],
                ibanDetection: ibanDetection,
                limit: 3
            ), let pick = results.first else { return nil }
            return DiscoveredBank(
                id: pick.id,
                displayName: pick.displayName,
                logoId: pick.logoId,
                credentials: DiscoveredBankCredentials(
                    full: pick.credentials.full,
                    userId: pick.credentials.userId,
                    none: pick.credentials.none
                ),
                userIdLabel: pick.userId?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
                advice: pick.advice?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            )
        }

        // 1. Try full IBAN with IBAN detection
        if let bank = await searchWith(term: normalized, ibanDetection: true) {
            return bank
        }
        // 2. Fallback: search by BLZ only (plain text search, no ibanDetection)
        if let blz, let bank = await searchWith(term: blz, ibanDetection: false) {
            return bank
        }
        return nil
    }

    static func clearSessionState() async {
        await sessionStore.clearAll()
        AppLogger.log("Cleared YAXI session state", category: "YaxiService")
    }

    /// Clears all session data (UserDefaults) for a specific slot.
    /// Call this when permanently deleting a slot.
    static func clearSessionData(forSlotId slotId: String) async {
        await sessionStore.clearAll(slotId: slotId)
        AppLogger.log("Cleared session data for slot \(slotId.prefix(8))", category: "YaxiService")
    }

    static func clearSessionsKeepingConnectionData() async {
        await sessionStore.clearSessionsOnly()
        AppLogger.log("Cleared YAXI sessions (connectionData preserved)", category: "YaxiService")
    }

    /// Clears connectionData only, preserving session tokens.
    /// Used at setup start so YAXI can reuse an existing recurring consent
    /// (session token) and present push TAN instead of full browser OAuth.
    static func clearConnectionDataKeepingSessions() async {
        await sessionStore.clearConnectionDataOnly()
        AppLogger.log("Cleared YAXI connectionData (sessions preserved)", category: "YaxiService")
    }

    // MARK: - Credential building (mirrors buildCredentialsForConnection in server.js)

    /// Corrects previously mis-saved credModel for redirect-banks (e.g. Sparkasse).
    /// Earlier code hardcoded `none = false`; re-discover to get the correct value.
    static func migrateCredentialsModelIfNeeded() {
        let d = UserDefaults.standard
        // If connectionId is present but credModel was saved with none=false and full=false,
        // it may be a redirect-bank (e.g. Sparkasse) that was wrongly migrated.
        // Clear sessions to force a fresh SCA that then saves correct credModel via discoverBank.
        let hasConnection = d.string(forKey: connectionIdKey) != nil
        let noneIsStored = d.object(forKey: credModelNoneKey) != nil
        let none = d.bool(forKey: credModelNoneKey)
        let full = d.bool(forKey: credModelFullKey)
        let userId = d.bool(forKey: credModelUserIdKey)
        if hasConnection && noneIsStored && !none && !full && !userId {
            // Likely a redirect-bank with wrong credModel — clear sessions so next fetch
            // re-establishes the connection and saves the correct model.
            Task { await sessionStore.clearSessionsOnly() }
            AppLogger.log("migrateCredentialsModel: detected likely redirect-bank with wrong model, cleared sessions", category: "YaxiService")
        }
    }

    private static func loadCredentialsModel(slotId: String) -> CredentialsModel {
        let d = UserDefaults.standard
        let fullKey = credModelFullKey(for: slotId)
        guard d.object(forKey: fullKey) != nil else {
            return CredentialsModel(full: true, userId: true, none: false)
        }
        return CredentialsModel(
            full: d.bool(forKey: fullKey),
            userId: d.bool(forKey: credModelUserIdKey(for: slotId)),
            none: d.bool(forKey: credModelNoneKey(for: slotId))
        )
    }

    /// Returns the stored credentials model as DiscoveredBankCredentials (for accounts() flow).
    static func loadStoredCredentials(slotId: String) -> DiscoveredBankCredentials {
        let m = loadCredentialsModel(slotId: slotId)
        return DiscoveredBankCredentials(full: m.full, userId: m.userId, none: m.none)
    }

    private static func buildCredentials(
        connectionId: String,
        model: CredentialsModel,
        connectionData: Data?,
        userId: String?,
        password: String?
    ) -> Credentials {
        let u = userId?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        let p = password?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty

        var creds = Credentials(connectionId: connectionId, connectionData: connectionData)

        // Priority: full > userId > none  (mirrors MoneyMoney Lua)
        // `none` only means redirect when neither `full` nor `userId` is available.
        if model.full {
            creds.userId = u
            creds.password = p
        } else if model.userId {
            creds.userId = u
            // Some providers mark userId-only but still require the password for SCA.
            creds.password = p
        }
        // else model.none only → redirect, no credentials embedded

        return creds
    }

    // MARK: - Error classification (mirrors isConnectionResetError / isObsoleteSessionError)

    private static func isConnectionResetError(_ error: Error) -> Bool {
        guard let re = error as? RoutexClientError else { return false }
        switch re {
        // UnexpectedError is intentionally excluded: HBCI gateway errors like
        // "FGW Gatewaywechsel" and "FGW Fehlender Dialogkontext" are transient
        // infrastructure hiccups that only need session clearing, not full state reset.
        // Full clearAll on UnexpectedError caused Volksbank users to re-do 2FA on
        // every fetch after any transient HBCI error.
        case .Unauthorized, .ConsentExpired: return true
        default: return false
        }
    }

    /// HBCI gateway-level transient errors: session needs reset but connectionData stays valid.
    private static func isHBCITransientError(_ error: Error) -> Bool {
        let msg = error.localizedDescription
        return msg.contains("Gatewaywechsel") ||
               msg.contains("Fehlender Dialogkontext") ||
               msg.contains("Dialog abgebrochen") ||
               msg.contains("Dialogkontext") ||
               msg.contains("Nachrichtennummer")
    }

    private static func isObsoleteSessionError(_ error: Error) -> Bool {
        let msg = error.localizedDescription.lowercased()
        return msg.contains("dialog-id ist nicht g") ||
            msg.contains("dialog abgebrochen") ||
            msg.contains("dialog-id is not valid") ||
            msg.contains("dialog cancelled")
    }

    private static func isRequestError(_ error: Error) -> Bool {
        guard let re = error as? RoutexClientError else { return false }
        if case .RequestError = re { return true }
        return false
    }

    private static func shouldRetryWithoutUserId(error: Error, model: CredentialsModel, userId: String?) -> Bool {
        guard model.full, !model.userId, userId?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty != nil else {
            return false
        }
        let msg = error.localizedDescription.lowercased()
        return msg.contains("does not support a user id") ||
            msg.contains("does not support a userid") ||
            msg.contains("supports no user id") ||
            msg.contains("user id is not supported") ||
            msg.contains("user id and a password")
    }

    // MARK: - Response mapping

    private static func makeBalancesResponse(
        _ result: AuthenticatedBalancesResult,
        session: Session?,
        connectionData: ConnectionData?
    ) -> BalancesResponse {
        let allBalances = result.toData().data.balances.first?.balances ?? []

        let booked = allBalances.first(where: { $0.balanceType == .booked })
            ?? allBalances.first(where: { $0.balanceType == .available })
            ?? allBalances.first
        let expected = allBalances.first(where: { $0.balanceType == .expected })

        return BalancesResponse(
            ok: true,
            booked: booked.map { makeBalanceModel($0) },
            expected: expected.map { makeBalanceModel($0) },
            session: session?.base64EncodedString(),
            connectionData: connectionData?.base64EncodedString(),
            error: nil,
            userMessage: nil,
            scaRequired: nil
        )
    }

    private static func makeBalanceModel(_ b: Balance) -> BalancesResponse.Balance {
        BalancesResponse.Balance(
            amount: (b.amount as NSDecimalNumber).stringValue,
            currency: b.currency,
            balanceType: balanceTypeName(b.balanceType)
        )
    }

    private static func balanceTypeName(_ type: BalanceType) -> String {
        switch type {
        case .booked:    return "Booked"
        case .available: return "Available"
        case .expected:  return "Expected"
        }
    }

    private static func makeTransactionsResponse(
        _ result: AuthenticatedTransactionsResult,
        session: Session?,
        connectionData: ConnectionData?
    ) -> TransactionsResponse {
        let transactions = result.toData().data ?? []

        let mapped = transactions.map { tx -> TransactionsResponse.Transaction in
            let amountVal = (tx.amount.amount as NSDecimalNumber).doubleValue
            // Keep German comma format for stableIdentifier compatibility with existing DB entries
            let amountStr = String(format: "%.2f", amountVal).replacingOccurrences(of: ".", with: ",")

            return TransactionsResponse.Transaction(
                bookingDate: tx.bookingDate.map { dateString($0) },
                valueDate:   tx.valueDate.map   { dateString($0) },
                status:      statusString(tx.status),
                endToEndId:  tx.endToEndId,
                amount: TransactionsResponse.Amount(currency: tx.amount.currency, amount: amountStr),
                creditor: tx.creditor.map {
                    TransactionsResponse.Party(name: truncateName($0.name), iban: $0.iban, bic: $0.bic)
                },
                debtor: tx.debtor.map {
                    TransactionsResponse.Party(name: truncateName($0.name), iban: $0.iban, bic: $0.bic)
                },
                remittanceInformation: tx.remittanceInformation.isEmpty ? nil : tx.remittanceInformation,
                additionalInformation: tx.additionalInformation,
                purposeCode: tx.purposeCode
            )
        }

        return TransactionsResponse(
            ok: true,
            transactions: mapped,
            session: session?.base64EncodedString(),
            connectionData: connectionData?.base64EncodedString(),
            error: nil,
            userMessage: nil,
            scaRequired: nil
        )
    }

    private static func truncateName(_ name: String?) -> String? {
        guard let name else { return nil }
        return name.split(separator: " ").prefix(2).joined(separator: " ")
    }

    private static let isoDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        // Local timezone: the SDK parses bank dates as midnight in local time.
        // Formatting with UTC would shift yesterday's bookings to the day before.
        f.timeZone = TimeZone.current
        return f
    }()

    private static func dateString(_ date: Date) -> String {
        isoDateFormatter.string(from: date)
    }

    private static func statusString(_ status: TransactionStatus) -> String {
        switch status {
        case .pending:  return "pending"
        case .booked:   return "booked"
        case .invoiced: return "invoiced"
        case .paid:     return "paid"
        case .canceled: return "canceled"
        }
    }

    // MARK: - SCA flow (mirrors handleSCAFlow in server.js)

    private enum SCAPayload {
        case balances(AuthenticatedBalancesResult)
        case transactions(AuthenticatedTransactionsResult)
        case accounts(AuthenticatedAccountsResult)
    }

    private struct SCAOutcome {
        let payload: SCAPayload
        let session: Session?
        let connectionData: ConnectionData?
    }

    private enum SCACommon {
        case result(SCAPayload, Session?, ConnectionData?)
        case dialog(DialogInput)
        case redirect(URL, ConfirmationContext)
        case redirectHandle(String, ConfirmationContext)
    }

    private static func toSCACommon(_ r: Routex.BalancesResponse) -> SCACommon {
        switch r {
        case .result(let res, let s, let cd): return .result(.balances(res), s, cd)
        case .dialog(_, _, _, let input):     return .dialog(input)
        case .redirect(let url, let ctx):     return .redirect(url, ctx)
        case .redirectHandle(let h, let ctx): return .redirectHandle(h, ctx)
        }
    }

    private static func toSCACommon(_ r: Routex.TransactionsResponse) -> SCACommon {
        switch r {
        case .result(let res, let s, let cd): return .result(.transactions(res), s, cd)
        case .dialog(_, _, _, let input):     return .dialog(input)
        case .redirect(let url, let ctx):     return .redirect(url, ctx)
        case .redirectHandle(let h, let ctx): return .redirectHandle(h, ctx)
        }
    }

    private static func toSCACommon(_ r: Routex.AccountsResponse) -> SCACommon {
        switch r {
        case .result(let res, let s, let cd): return .result(.accounts(res), s, cd)
        case .dialog(let ctx, let msg, _, let input):
            AppLogger.log("AccountsResponse dialog: ctx=\(ctx.map{"\($0)"} ?? "nil") msg=\(msg ?? "nil") input=\(input)", category: "YaxiService")
            return .dialog(input)
        case .redirect(let url, let ctx):     return .redirect(url, ctx)
        case .redirectHandle(let h, let ctx): return .redirectHandle(h, ctx)
        }
    }

    private static func handleSCA(
        initial: SCACommon,
        client: RoutexClient,
        ticket: Ticket,
        confirm: @escaping @Sendable (ConfirmationContext) async throws -> SCACommon,
        respond: @escaping @Sendable (InputContext, String) async throws -> SCACommon,
        depth: Int = 0
    ) async -> SCAOutcome? {
        if depth > 5 {
            AppLogger.log("SCA: max depth exceeded", category: "YaxiService", level: "WARN")
            return nil
        }

        switch initial {

        case .result(let payload, let session, let connectionData):
            AppLogger.log("SCA result: connectionData=\(connectionData == nil ? "nil" : "\(connectionData!.count)b")", category: "YaxiService")
            return SCAOutcome(payload: payload, session: session, connectionData: connectionData)

        case .dialog(let input):
            switch input {

            case .selection(let options, let context):
                let preferred = options.first(where: { o in
                    let s = "\(o.key) \(o.label) \(o.explanation ?? "")".lowercased()
                    return s.contains("push") || s.contains("app") || s.contains("decoupled")
                }) ?? options.first
                guard let preferred else {
                    AppLogger.log("SCA Selection: no options available", category: "YaxiService", level: "WARN")
                    return nil
                }
                AppLogger.log("SCA Selection: picking '\(preferred.key)'", category: "YaxiService")
                do {
                    let next = try await respond(context, preferred.key)
                    return await handleSCA(initial: next, client: client, ticket: ticket,
                                           confirm: confirm, respond: respond, depth: depth + 1)
                } catch {
                    AppLogger.log("SCA respond error: \(error.localizedDescription)", category: "YaxiService", level: "ERROR")
                    return nil
                }

            case .confirmation(let context, let pollingDelaySecs):
                if let delay = pollingDelaySecs {
                    // YAXI: pollingDelay set → poll until confirmed
                    AppLogger.log("SCA Confirmation: polling delay=\(delay)s", category: "YaxiService")
                    return await pollConfirmation(
                        context: context,
                        delay: TimeInterval(delay),
                        client: client, ticket: ticket,
                        confirm: confirm, respond: respond, depth: depth
                    )
                } else {
                    // YAXI: pollingDelay not set — use a conservative 5 s default.
                    // Push/decoupled banks don't prescribe an interval, but they do
                    // complete via the same confirm() path once the user approves in
                    // their banking app.  Polling with a longer delay is safe and is
                    // what worked reliably before any button-based approach was tried.
                    AppLogger.log("SCA Confirmation: no pollingDelay — polling with 5 s default", category: "YaxiService")
                    return await pollConfirmation(
                        context: context,
                        delay: 5.0,
                        client: client, ticket: ticket,
                        confirm: confirm, respond: respond, depth: depth
                    )
                }

            case .field:
                AppLogger.log("SCA: unhandled field input", category: "YaxiService", level: "WARN")
                return nil
            }

        case .redirect(let url, let context):
            AppLogger.log("SCA Redirect: opening browser", category: "YaxiService")
            openRedirectURL(url)
            return await pollRedirect(context: context, client: client, ticket: ticket,
                                      confirm: confirm, respond: respond)

        case .redirectHandle(let handle, let context):
            AppLogger.log("SCA RedirectHandle: registering redirect URI", category: "YaxiService")
            let callbackServer = YaxiOAuthCallback()
            guard let port = try? await callbackServer.start(), port > 0 else {
                AppLogger.log("SCA: failed to start callback server", category: "YaxiService", level: "ERROR")
                return nil
            }
            let bankURL: URL
            do {
                bankURL = try await client.registerRedirectUri(
                    ticket: ticket,
                    handle: handle,
                    redirectUri: "http://localhost:\(port)/simplebanking-auth-callback"
                )
            } catch {
                callbackServer.stop()
                AppLogger.log("SCA registerRedirectUri failed: \(error.localizedDescription)", category: "YaxiService", level: "ERROR")
                return nil
            }
            AppLogger.log("SCA RedirectHandle: opening bank URL in browser", category: "YaxiService")
            openRedirectURL(bankURL)
            // Signal stream: fires immediately when localhost callback arrives
            let callbackSignal = AsyncStream<Void> { continuation in
                callbackServer.onCallbackReceived = { continuation.yield(); continuation.finish() }
            }
            let result = await pollRedirect(context: context, client: client, ticket: ticket,
                                             confirm: confirm, respond: respond,
                                             callbackSignal: callbackSignal)
            callbackServer.stop()
            return result
        }
    }

    private static func pollConfirmation(
        context: ConfirmationContext,
        delay: TimeInterval,
        client: RoutexClient,
        ticket: Ticket,
        confirm: @escaping @Sendable (ConfirmationContext) async throws -> SCACommon,
        respond: @escaping @Sendable (InputContext, String) async throws -> SCACommon,
        depth: Int
    ) async -> SCAOutcome? {
        Task { @MainActor in YaxiService.onTanStateChanged?(true) }
        defer { Task { @MainActor in YaxiService.onTanStateChanged?(false) } }
        var ctx = context
        var currentDelay = delay
        var consecutiveErrors = 0
        for i in 0..<180 {
            try? await Task.sleep(nanoseconds: UInt64(max(currentDelay, 1.0) * 1_000_000_000))
            if Task.isCancelled { return nil }
            do {
                let next = try await confirm(ctx)
                consecutiveErrors = 0
                switch next {
                case .result:
                    return await handleSCA(initial: next, client: client, ticket: ticket,
                                           confirm: confirm, respond: respond, depth: depth + 1)
                case .dialog(let input):
                    if case .confirmation(let newCtx, let newDelay) = input {
                        let ctxChanged = newCtx != ctx
                        ctx = newCtx
                        currentDelay = newDelay.map { TimeInterval($0) } ?? currentDelay
                        AppLogger.log("SCA poll[\(i)]: still pending ctx=\(ctx.count)b changed=\(ctxChanged) delay=\(currentDelay)s", category: "YaxiService")
                        continue
                    }
                    // Non-confirmation dialog arrived during polling — log it
                    if case .selection(let opts, _) = input {
                        AppLogger.log("SCA poll[\(i)]: got Selection with \(opts.count) options: \(opts.map{$0.key}.joined(separator:", "))", category: "YaxiService")
                    } else {
                        AppLogger.log("SCA poll[\(i)]: got non-confirmation dialog: \(input)", category: "YaxiService", level: "WARN")
                    }
                    return await handleSCA(initial: next, client: client, ticket: ticket,
                                           confirm: confirm, respond: respond, depth: depth + 1)
                default:
                    return await handleSCA(initial: next, client: client, ticket: ticket,
                                           confirm: confirm, respond: respond, depth: depth + 1)
                }
            } catch {
                consecutiveErrors += 1
                AppLogger.log("SCA Confirmation poll \(i) error (\(consecutiveErrors) consecutive): \(error.localizedDescription)", category: "YaxiService", level: "WARN")
                // Abort only after 3 consecutive failures — single transient errors are retried
                if consecutiveErrors >= 3 { return nil }
            }
        }
        AppLogger.log("SCA Confirmation: timeout (180 attempts)", category: "YaxiService", level: "WARN")
        return nil
    }

    private static func pollRedirect(
        context: ConfirmationContext,
        client: RoutexClient,
        ticket: Ticket,
        confirm: @escaping @Sendable (ConfirmationContext) async throws -> SCACommon,
        respond: @escaping @Sendable (InputContext, String) async throws -> SCACommon,
        callbackSignal: AsyncStream<Void>? = nil
    ) async -> SCAOutcome? {
        Task { @MainActor in YaxiService.onTanStateChanged?(true) }
        defer { Task { @MainActor in YaxiService.onTanStateChanged?(false) } }
        var ctx = context
        var callbackFired = false
        var consecutiveErrors = 0

        for _ in 0..<120 {
            if !callbackFired {
                // Race: wait up to 5s OR until redirect callback arrives (whichever first).
                // Use a CheckedContinuation so each racer holds only Sendable values and
                // Swift 6 does not flag mutable-iterator captures inside task-group closures.
                final class _Once: @unchecked Sendable {
                    private var done = false
                    func tryFire() -> Bool { guard !done else { return false }; done = true; return true }
                }
                let once = _Once()
                await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                    Task { try? await Task.sleep(nanoseconds: 5_000_000_000); if once.tryFire() { cont.resume() } }
                    if let sig = callbackSignal {
                        Task {
                            var iter = sig.makeAsyncIterator()
                            _ = await iter.next()
                            if once.tryFire() { cont.resume() }
                        }
                    }
                }
                if Task.isCancelled { return nil }
                callbackFired = true // after first callback, fall through to normal 5s polling
            } else {
                try? await Task.sleep(nanoseconds: 5_000_000_000) // 5 s
                if Task.isCancelled { return nil }
            }
            do {
                let next = try await confirm(ctx)
                switch next {
                case .result:
                    return await handleSCA(initial: next, client: client, ticket: ticket,
                                           confirm: confirm, respond: respond)
                case .redirect(_, let newCtx):
                    ctx = newCtx
                case .redirectHandle(_, let newCtx):
                    ctx = newCtx
                case .dialog(let input):
                    if case .confirmation = input {
                        return await handleSCA(initial: next, client: client, ticket: ticket,
                                               confirm: confirm, respond: respond)
                    }
                    AppLogger.log("SCA Redirect poll: unexpected dialog", category: "YaxiService", level: "WARN")
                    return nil
                }
            } catch {
                consecutiveErrors += 1
                AppLogger.log("SCA Redirect poll error (\(consecutiveErrors) consecutive): \(error.localizedDescription)", category: "YaxiService", level: "WARN")
                if consecutiveErrors >= 3 {
                    await writeTrace(client: client, label: "pollRedirect", ticket: ticket, error: error)
                    return nil
                }
                continue
            }
            consecutiveErrors = 0
        }
        AppLogger.log("SCA Redirect: timeout (120 × 5 s)", category: "YaxiService", level: "WARN")
        await writeTrace(client: client, label: "pollRedirect-timeout", ticket: ticket)
        return nil
    }

    // MARK: - Trace

    /// Fetches the trace for the last client operation and writes it to
    /// ~/Library/Logs/simplebanking/yaxi-trace-<timestamp>-<label>.txt
    /// Always creates a file — even when no traceId is available — so that
    /// the call site can be confirmed and the triggering error is recorded.
    static func writeTrace(client: RoutexClient, label: String, ticket: Ticket, error: Error? = nil) async {
        // Trace files are gated on the same logging setting as the rest of the app.
        // Disable logging in Settings to prevent sensitive banking data from landing on disk.
        guard AppLogger.isEnabled else { return }
        let logsDir = AppLogger.logDirectoryURL.appendingPathComponent("trace")
        do {
            try FileManager.default.createDirectory(at: logsDir, withIntermediateDirectories: true)
        } catch {
            AppLogger.log("trace: cannot create log dir: \(error)", category: "YaxiService", level: "WARN")
        }

        let ts = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let file = logsDir.appendingPathComponent("yaxi-trace-\(ts)-\(label).txt")

        var content = ""
        if let error {
            content += "=== Triggering error ===\n\(error)\n\n"
        }

        if let traceId = client.traceId() {
            do {
                let text = try await client.trace(ticket: ticket, traceId: traceId)
                content += "=== YAXI trace ===\n\(text)\n"
            } catch let traceError {
                content += "=== trace() call failed ===\n\(traceError)\n"
            }
        } else {
            content += "=== No traceId available from SDK ===\n"
        }

        do {
            try content.write(to: file, atomically: true, encoding: .utf8)
            AppLogger.log("trace written → \(file.path)", category: "YaxiService")
        } catch let writeError {
            AppLogger.log("trace: file write failed: \(writeError)", category: "YaxiService", level: "WARN")
        }
    }

    // MARK: - Redirect URL throttling and browser opening

    private static func openRedirectURL(_ url: URL) {
        let now = Date()
        if let last = lastRedirectOpenedAt, now.timeIntervalSince(last) < 290 {
            AppLogger.log("SCA: redirect URL throttled (\(Int(now.timeIntervalSince(last)))s ago)", category: "YaxiService")
            return
        }
        lastRedirectOpenedAt = now
        NSWorkspace.shared.open(url)
        sendSCANotification()
    }

    private static func sendSCANotification() {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = "Banking-Freigabe erforderlich"
            content.body = "Bitte im Browser bestätigen und danach zurückkehren."
            content.sound = .default
            let request = UNNotificationRequest(identifier: "sca-\(UUID().uuidString)", content: content, trigger: nil)
            center.add(request) { error in
                if let error { AppLogger.log("SCA notification error: \(error)", category: "YaxiService", level: "WARN") }
            }
        }
    }
}
