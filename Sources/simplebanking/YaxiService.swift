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

    /// Wird vom SCA-`.field`-Branch in `handleSCA` aufgerufen, wenn die Bank
    /// eine TAN/PIN-Eingabe verlangt. Liefert den eingegebenen String oder
    /// nil bei User-Cancel. Wird einmalig in `BalanceBar` beim App-Start
    /// auf `SCAFieldInputPresenter.present(_:)` verdrahtet. Bleibt nil in
    /// Test-/CLI-Kontexten — dann bricht der Branch wie bisher mit WARN ab.
    nonisolated(unsafe) static var fieldInputProvider:
        (@Sendable (SCAFieldInput.Spec) async -> String?)?

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

        /// Per-Slot in-memory Cache. Vor Refactor 2026-05-19 gab es vier globale
        /// Felder (balancesSession etc.), die durch `reloadForActiveSlot()` zwischen
        /// Slots gewechselt wurden — bei nicht-aktiven Slot-Operationen leakte das
        /// active-slot-Material in die Bank-Calls (Aileen-Diagnose). Jetzt strikt
        /// pro slotId isoliert, lazy on first access aus Disk geladen.
        struct SlotState {
            var balancesSession: Data?
            var transactionsSession: Data?
            var transferSession: Data?
            var connectionData: Data?
        }
        private var slotStates: [String: SlotState] = [:]

        /// Lädt einen Slot lazy beim ersten Zugriff aus der Disk in den Cache.
        /// Wird vom `actor` automatisch serialisiert — gleichzeitige Reads für
        /// denselben Slot finden nach dem ersten Load alle den Cache-Hit.
        private func loadIfNeeded(_ slotId: String) -> SlotState {
            if let cached = slotStates[slotId] { return cached }
            var state = SlotState()
            state.balancesSession     = SessionStore.persistRead("session.balances",     slotId: slotId)
            state.transactionsSession = SessionStore.persistRead("session.transactions", slotId: slotId)
            state.transferSession     = SessionStore.persistRead("session.transfer",     slotId: slotId)
            state.connectionData      = SessionStore.persistRead("connectionData",       slotId: slotId)
            // Legacy-UserDefaults-Migration (pre-multibanking) nur für den
            // "legacy"-Slot: damalige Builds schrieben in no-suffix UD-Keys.
            if slotId == "legacy" {
                let legB64 = defaults.string(forKey: "simplebanking.yaxi.session")
                if state.balancesSession == nil {
                    state.balancesSession = (defaults.string(forKey: "simplebanking.yaxi.session.balances") ?? legB64)
                        .flatMap { Data(base64Encoded: $0) }
                }
                if state.transactionsSession == nil {
                    state.transactionsSession = (defaults.string(forKey: "simplebanking.yaxi.session.transactions") ?? legB64)
                        .flatMap { Data(base64Encoded: $0) }
                }
                if state.transferSession == nil {
                    state.transferSession = defaults.string(forKey: "simplebanking.yaxi.session.transfer")
                        .flatMap { Data(base64Encoded: $0) }
                }
                if state.connectionData == nil {
                    state.connectionData = defaults.string(forKey: "simplebanking.yaxi.connectionData")
                        .flatMap { Data(base64Encoded: $0) }
                }
            }
            slotStates[slotId] = state
            return state
        }

        /// Mutiert den Cache-Eintrag für slotId. Erstellt ihn falls noch nicht
        /// geladen. Garantiert Konsistenz zwischen Memory und Disk.
        private func mutateState(_ slotId: String, _ block: (inout SlotState) -> Void) {
            var state = loadIfNeeded(slotId)
            block(&state)
            slotStates[slotId] = state
        }

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
            // Lazy: keine eager loads mehr. Slot-State wird beim ersten Zugriff
            // pro slotId aus der Disk geholt (siehe `loadIfNeeded`).
        }

        // MARK: - Public API

        /// Slot-explizite Reader. Vor Refactor 2026-05-19 gab es Overloads ohne
        /// slotId, die das aktive in-memory Feld zurückgaben — was bei Multi-Slot-
        /// Setups zu Cross-Slot-Leaks führte (Aileen-Diagnose).
        func session(for scope: Scope, slotId: String) -> Data? {
            let state = loadIfNeeded(slotId)
            switch scope {
            case .balances:     return state.balancesSession
            case .transactions: return state.transactionsSession
            case .transfer:     return state.transferSession
            }
        }

        func connectionData(slotId: String) -> Data? {
            loadIfNeeded(slotId).connectionData
        }

        func update(scope: Scope, session: Data?, connectionData: Data?, slotId: String? = nil) {
            let sid = slotId ?? YaxiService.activeSlotId
            mutateState(sid) { state in
                if let s = session {
                    switch scope {
                    case .balances:     state.balancesSession     = s
                    case .transactions: state.transactionsSession = s
                    case .transfer:     state.transferSession     = s
                    }
                    let key: String = {
                        switch scope {
                        case .balances:     return "session.balances"
                        case .transactions: return "session.transactions"
                        case .transfer:     return "session.transfer"
                        }
                    }()
                    persistWrite(key, slotId: sid, data: s)
                }
                if let cd = connectionData {
                    state.connectionData = cd
                    persistWrite("connectionData", slotId: sid, data: cd)
                }
            }
        }

        func updateConnectionData(_ connectionData: Data?, slotId: String? = nil) {
            let sid = slotId ?? YaxiService.activeSlotId
            guard let connectionData else { return }
            mutateState(sid) { state in
                state.connectionData = connectionData
                persistWrite("connectionData", slotId: sid, data: connectionData)
            }
        }

        func clearAll(slotId: String? = nil) {
            let sid = slotId ?? YaxiService.activeSlotId
            slotStates[sid] = SlotState()
            persistDelete("session.balances",    slotId: sid)
            persistDelete("session.transactions", slotId: sid)
            persistDelete("session.transfer",     slotId: sid)
            persistDelete("connectionData",       slotId: sid)
            defaults.removeObject(forKey: "simplebanking.yaxi.session")
            defaults.removeObject(forKey: "simplebanking.yaxi.session.balances\(SessionStore.suffix(for: sid))")
            defaults.removeObject(forKey: "simplebanking.yaxi.session.transactions\(SessionStore.suffix(for: sid))")
            defaults.removeObject(forKey: "simplebanking.yaxi.session.transfer\(SessionStore.suffix(for: sid))")
            defaults.removeObject(forKey: "simplebanking.yaxi.connectionData\(SessionStore.suffix(for: sid))")
        }

        func clearSessionsOnly(slotId: String? = nil) {
            let sid = slotId ?? YaxiService.activeSlotId
            mutateState(sid) { state in
                state.balancesSession = nil
                state.transactionsSession = nil
                state.transferSession = nil
            }
            persistDelete("session.balances",    slotId: sid)
            persistDelete("session.transactions", slotId: sid)
            persistDelete("session.transfer",     slotId: sid)
            defaults.removeObject(forKey: "simplebanking.yaxi.session")
            defaults.removeObject(forKey: "simplebanking.yaxi.session.balances\(SessionStore.suffix(for: sid))")
            defaults.removeObject(forKey: "simplebanking.yaxi.session.transactions\(SessionStore.suffix(for: sid))")
            defaults.removeObject(forKey: "simplebanking.yaxi.session.transfer\(SessionStore.suffix(for: sid))")
        }

        func clearConnectionDataOnly(slotId: String? = nil) {
            let sid = slotId ?? YaxiService.activeSlotId
            mutateState(sid) { $0.connectionData = nil }
            persistDelete("connectionData", slotId: sid)
            defaults.removeObject(forKey: "simplebanking.yaxi.connectionData\(SessionStore.suffix(for: sid))")
        }

        /// Invalidiert den in-memory Cache für `slotId` — der nächste Read lädt
        /// frisch aus der Disk. Ersatz für das alte `reloadForActiveSlot()`,
        /// das nach dem Per-Slot-Refactor obsolet ist (Cache lädt automatisch
        /// pro slotId). Wird noch von Diagnose- und Slot-Switch-Pfaden genutzt,
        /// um nach externen Disk-Schreibvorgängen Frische zu garantieren.
        func invalidateCache(slotId: String) {
            slotStates.removeValue(forKey: slotId)
        }

        func copyConnectionDataAndSessions(fromSlotId: String, toSlotId: String) {
            for key in ["connectionData", "session.balances", "session.transactions", "session.transfer"] {
                if let data = SessionStore.persistRead(key, slotId: fromSlotId) {
                    persistWrite(key, slotId: toSlotId, data: data)
                }
            }
            // Memory-Cache für target invalidieren — nächster Read lädt frische
            // Daten von Disk inkl. der gerade kopierten.
            slotStates.removeValue(forKey: toSlotId)
        }

        func clearLegacySessionData() {
            slotStates["legacy"] = SlotState()
            persistDelete("session.balances",    slotId: "legacy")
            persistDelete("session.transactions", slotId: "legacy")
            persistDelete("session.transfer",     slotId: "legacy")
            persistDelete("connectionData",       slotId: "legacy")
            defaults.removeObject(forKey: "simplebanking.yaxi.session")
            defaults.removeObject(forKey: "simplebanking.yaxi.session.balances")
            defaults.removeObject(forKey: "simplebanking.yaxi.session.transactions")
            defaults.removeObject(forKey: "simplebanking.yaxi.session.transfer")
            defaults.removeObject(forKey: "simplebanking.yaxi.connectionData")
            AppLogger.log("clearLegacySessionData: legacy slot cleared", category: "YaxiService")
        }

        enum Scope { case balances, transactions, transfer }
    }

    // Throttle re-opening the bank redirect URL (< 290 s cooldown).
    private static nonisolated(unsafe) var lastRedirectOpenedAt: Date? = nil


    // MARK: - Public API

    /// Copies the FULL connection state from one slot to another. Used when one
    /// Online-Banking-Login deckt mehrere Konten ab (z.B. DKB Familie) und
    /// jedes Konto bekommt seinen eigenen Slot, teilt sich aber die YAXI-
    /// connection. Kopiert BEIDES: UserDefaults-Keys (connectionId, credModel*)
    /// UND SessionStore (connectionData + sessions). Ohne die UserDefaults-
    /// Keys hätte der neue Slot `connectionId = nil` und jeder fetchBalances
    /// würde mit „no connectionId yet" rausfallen.
    static func copyConnectionState(fromSlotId: String, toSlotId: String) async {
        copyConnectionStateKeys(fromSlotId: fromSlotId, toSlotId: toSlotId)
        await sessionStore.copyConnectionDataAndSessions(fromSlotId: fromSlotId, toSlotId: toSlotId)
    }

    /// Synchroner Teil von `copyConnectionState`: kopiert die UserDefaults-
    /// State-Keys (connectionId + credential-model-Flags) zwischen Slots.
    /// MUSS vor `MultibankingStore.addSlot` + Refresh laufen, sonst rennt
    /// ein sofort getriggerter fetchBalances in „no connectionId yet" weil
    /// der async SessionStore-Copy noch nicht durch ist.
    static func copyConnectionStateKeys(fromSlotId: String, toSlotId: String) {
        let d = UserDefaults.standard
        if let v = d.string(forKey: connectionIdKey(for: fromSlotId)), !v.isEmpty {
            d.set(v, forKey: connectionIdKey(for: toSlotId))
        }
        for (srcKey, dstKey) in [
            (credModelFullKey(for: fromSlotId),   credModelFullKey(for: toSlotId)),
            (credModelUserIdKey(for: fromSlotId), credModelUserIdKey(for: toSlotId)),
            (credModelNoneKey(for: fromSlotId),   credModelNoneKey(for: toSlotId)),
        ] {
            if d.object(forKey: srcKey) != nil {
                d.set(d.bool(forKey: srcKey), forKey: dstKey)
            }
        }
        let copied = d.string(forKey: connectionIdKey(for: toSlotId))?.prefix(8) ?? "nil"
        AppLogger.log(
            "copyConnectionStateKeys: from=\(fromSlotId.prefix(8)) to=\(toSlotId.prefix(8)) connId=\(copied)",
            category: "YaxiService"
        )
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
        let storedCD = await sessionStore.connectionData(slotId: slotSnapshot)
        var storedSession = await sessionStore.session(for: .balances, slotId: slotSnapshot)
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

    /// `alwaysTrace=true` schreibt nach erfolgreicher Antwort zusätzlich
    /// einen YAXI-Trace via `writeTrace()` — für Diagnose-Probes, die auch
    /// bei Erfolg den vollen HTTP-Roundtrip dokumentieren wollen. Im
    /// normalen Refresh-Pfad (default false) bleibt der Trace nur Error-Pfad.
    static func fetchBalances(userId: String, password: String, alwaysTrace: Bool = false) async throws -> BalancesResponse {
        // Snapshot slot ID immediately — activeSlotId may change during async fetch
        let slotSnapshot = activeSlotId
        // HBCI-Mutex via withSlot — Acquire/Release atomar im Actor, damit
        // sequenzielle Folge-Calls den Slot nicht fälschlich als busy sehen
        // (P1.1: alte tryAcquire/Task-release-Kombi konnte race-en).
        let result: BalancesResponse? = try await BankRequestQueue.shared.withSlot(slotSnapshot) {
            try await fetchBalancesLocked(
                slotSnapshot: slotSnapshot,
                userId: userId,
                password: password,
                alwaysTrace: alwaysTrace
            )
        }
        guard let response = result else {
            AppLogger.log("fetchBalances: slot busy, skip slot=\(slotSnapshot.prefix(8))", category: "YaxiService", level: "WARN")
            return BalancesResponse(ok: false, booked: nil, expected: nil, session: nil,
                                   connectionData: nil, error: "bank busy",
                                   userMessage: nil, scaRequired: nil)
        }
        return response
    }

    /// Eigentlicher Bank-Call. Vorausgesetzt: Caller hält den BankRequestQueue-
    /// Slot. Niemals direkt aufrufen — immer über `fetchBalances`.
    private static func fetchBalancesLocked(
        slotSnapshot: String,
        userId: String,
        password: String,
        alwaysTrace: Bool
    ) async throws -> BalancesResponse {
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

        let storedCD = await sessionStore.connectionData(slotId: slotSnapshot)
        let storedSession = await sessionStore.session(for: .balances, slotId: slotSnapshot)
        let creds = buildCredentials(
            connectionId: connectionId, model: model,
            connectionData: storedCD, userId: userId, password: password
        )

        let client = RoutexClient()
        // Mutable — wird im retry-Pfad bei Bedarf neu ausgestellt (Yaxi-Doku:
        // nach non-RequestError frischer Ticket). Der finale Wert nach dem
        // inner-catch wird in `scaTicket` eingefroren für die SCA-Closures.
        var ticket = YaxiTicketMaker.issueTicket(service: "Balances")

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
                // YAXI-Doku: nach jedem non-RequestError ist der Service in
                // "failed state" → "need to start it again, with a new ticket".
                // Wir holen daher in jedem retry-Branch (außer Network) einen
                // frischen Ticket. Network-Errors sind explizit ausgenommen.
                if shouldRetryWithoutUserId(error: error, model: model, userId: userId) {
                    let credsNoUserId = buildCredentials(
                        connectionId: connectionId, model: model,
                        connectionData: storedCD, userId: nil, password: password
                    )
                    ticket = YaxiTicketMaker.issueTicket(service: "Balances")
                    let retryTicket = ticket
                    resp = try await client.balances(
                        credentials: credsNoUserId,
                        session: storedSession,
                        recurringConsents: true,
                        ticket: retryTicket,
                        accounts: accountRefs
                    )
                } else if isConnectionResetError(error), storedCD != nil {
                    // Consent abgelaufen (Unauthorized / ConsentExpired):
                    // YAXI-Empfehlung "Restart the service without passing
                    // connection data" — frischer Ticket (Doku) + connectionData
                    // weg. Session behalten: ein Drop führt bei Sparkasse zu
                    // erzwungenem SCA-Push bei JEDEM Refresh (Regression
                    // 2026-05-12). Yaxi-Doku verlangt das nicht explizit.
                    AppLogger.log("fetchBalances: consent expired, retrying without connectionData", category: "YaxiService", level: "WARN")
                    let credsNoCD = buildCredentials(
                        connectionId: connectionId, model: model,
                        connectionData: nil, userId: userId, password: password
                    )
                    ticket = YaxiTicketMaker.issueTicket(service: "Balances")
                    let retryTicket = ticket
                    resp = try await client.balances(
                        credentials: credsNoCD,
                        session: storedSession,
                        recurringConsents: true,
                        ticket: retryTicket,
                        accounts: accountRefs
                    )
                } else if storedSession != nil {
                    // Retry without session token (e.g. Revolut/Open Banking returns
                    // UnexpectedError when a stale YAXI session token is sent).
                    // UnexpectedError ist explizit nicht in isConnectionResetError,
                    // dieser Branch greift also nicht für 1822-Unauthorized.
                    AppLogger.log("fetchBalances: error with session, retrying without: \(error)", category: "YaxiService", level: "WARN")
                    await sessionStore.clearSessionsOnly(slotId: slotSnapshot)
                    ticket = YaxiTicketMaker.issueTicket(service: "Balances")
                    let retryTicket = ticket
                    resp = try await client.balances(
                        credentials: creds,
                        session: nil,
                        recurringConsents: true,
                        ticket: retryTicket,
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

            // SCA-Closures müssen let-bound Capture haben (Sendable).
            let scaTicket = ticket
            let confirm: @Sendable (ConfirmationContext) async throws -> SCACommon = { ctx in
                try await toSCACommon(client.confirmBalances(ticket: scaTicket, context: ctx))
            }
            let respond: @Sendable (InputContext, String) async throws -> SCACommon = { ctx, r in
                try await toSCACommon(client.respondBalances(ticket: scaTicket, context: ctx, response: r))
            }

            guard let outcome = await handleSCA(
                initial: toSCACommon(resp), client: client, ticket: scaTicket,
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
            if alwaysTrace {
                await writeTrace(client: client, label: "diag-fetchBalances-ok", ticket: ticket, error: nil)
            }
            return makeBalancesResponse(result,
                                        session: outcome.session,
                                        connectionData: outcome.connectionData,
                                        requestedIban: iban)

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

    static func fetchTransactions(userId: String, password: String, from: String, alwaysTrace: Bool = false) async throws -> TransactionsResponse {
        // Snapshot slot ID immediately — activeSlotId may change during async fetch
        let slotSnapshot = activeSlotId
        // HBCI-Mutex via withSlot (siehe fetchBalances).
        let result: TransactionsResponse? = try await BankRequestQueue.shared.withSlot(slotSnapshot) {
            try await fetchTransactionsLocked(
                slotSnapshot: slotSnapshot,
                userId: userId,
                password: password,
                from: from,
                alwaysTrace: alwaysTrace
            )
        }
        guard let response = result else {
            AppLogger.log("fetchTransactions: slot busy, skip slot=\(slotSnapshot.prefix(8))", category: "YaxiService", level: "WARN")
            return TransactionsResponse(ok: false, transactions: nil, session: nil,
                                       connectionData: nil, error: "bank busy",
                                       userMessage: nil, scaRequired: nil)
        }
        return response
    }

    /// Eigentlicher Bank-Call. Vorausgesetzt: Caller hält den BankRequestQueue-
    /// Slot. Niemals direkt aufrufen — immer über `fetchTransactions`.
    private static func fetchTransactionsLocked(
        slotSnapshot: String,
        userId: String,
        password: String,
        from: String,
        alwaysTrace: Bool
    ) async throws -> TransactionsResponse {
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
        let storedCD = await sessionStore.connectionData(slotId: slotSnapshot)
        AppLogger.log("fetchTransactions: slot=\(slotSnapshot.prefix(8)) storedCD=\(storedCD == nil ? "nil" : "\(storedCD!.count)b") model.none=\(model.none)", category: "YaxiService")
        let storedSession = await sessionStore.session(for: .transactions, slotId: slotSnapshot)
        let creds = buildCredentials(
            connectionId: connectionId, model: model,
            connectionData: storedCD, userId: userId, password: password
        )

        let client = RoutexClient()
        // Mutable — retry-Pfade ziehen neuen Ticket (Yaxi-Doku).
        var ticket = YaxiTicketMaker.issueTransactionsTicket(iban: iban, from: from)

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
                // YAXI-Doku: nach jedem non-RequestError ist der Service in
                // "failed state" → frischer Ticket nötig. Network-Errors
                // sind explizit ausgenommen.
                if shouldRetryWithoutUserId(error: error, model: model, userId: userId) {
                    let credsNoUserId = buildCredentials(
                        connectionId: connectionId, model: model,
                        connectionData: storedCD, userId: nil, password: password
                    )
                    ticket = YaxiTicketMaker.issueTransactionsTicket(iban: iban, from: from)
                    let retryTicket = ticket
                    resp = try await client.transactions(
                        credentials: credsNoUserId,
                        session: storedSession,
                        recurringConsents: true,
                        ticket: retryTicket
                    )
                } else if isConnectionResetError(error), storedCD != nil {
                    // Consent abgelaufen — frischer Ticket + connectionData
                    // weg, Session behalten (siehe fetchBalances: Sparkasse-
                    // Regression bei Session-Drop, 2026-05-12).
                    AppLogger.log("fetchTransactions: consent expired, retrying without connectionData", category: "YaxiService", level: "WARN")
                    let credsNoCD = buildCredentials(
                        connectionId: connectionId, model: model,
                        connectionData: nil, userId: userId, password: password
                    )
                    ticket = YaxiTicketMaker.issueTransactionsTicket(iban: iban, from: from)
                    let retryTicket = ticket
                    resp = try await client.transactions(
                        credentials: credsNoCD,
                        session: storedSession,
                        recurringConsents: true,
                        ticket: retryTicket
                    )
                } else if storedSession != nil {
                    // Stale-Session-Retry für Revolut/Open-Banking-Quirks
                    // (UnexpectedError, nicht in isConnectionResetError).
                    AppLogger.log("fetchTransactions: error with session, retrying without: \(error)", category: "YaxiService", level: "WARN")
                    await sessionStore.clearSessionsOnly(slotId: slotSnapshot)
                    ticket = YaxiTicketMaker.issueTransactionsTicket(iban: iban, from: from)
                    let retryTicket = ticket
                    resp = try await client.transactions(
                        credentials: creds,
                        session: nil,
                        recurringConsents: true,
                        ticket: retryTicket
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

            // SCA-Closures müssen let-bound Capture haben (Sendable).
            let scaTicket = ticket
            let confirm: @Sendable (ConfirmationContext) async throws -> SCACommon = { ctx in
                try await toSCACommon(client.confirmTransactions(ticket: scaTicket, context: ctx))
            }
            let respond: @Sendable (InputContext, String) async throws -> SCACommon = { ctx, r in
                try await toSCACommon(client.respondTransactions(ticket: scaTicket, context: ctx, response: r))
            }

            guard let outcome = await handleSCA(
                initial: toSCACommon(resp), client: client, ticket: scaTicket,
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
            if alwaysTrace {
                await writeTrace(client: client, label: "diag-fetchTransactions-ok", ticket: ticket, error: nil)
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

    /// Internal (statt private) für `@testable import`-Coverage —
    /// `RoutexClientErrorClassificationTests` prüft die Klassifizierung
    /// (Branch-Reorder-Schutz in fetchBalances/fetchTransactions/sendTransfer).
    static func isConnectionResetError(_ error: Error) -> Bool {
        guard let re = error as? RoutexClientError else { return false }
        switch re {
        case .Unauthorized, .ConsentExpired:
            return true
        case .UnexpectedError(let userMessage):
            // Build-181-Logik (urspr. NetworkService.swift, bei der routex-client-swift-
            // Migration verloren gegangen): UnexpectedError mit leerem userMessage ist
            // bei Sparkasse & Co. häufig stale ConnectionData → frische SCA nötig.
            // HBCI-Gateway-Errors (Volksbank: "FGW Gatewaywechsel", "Fehlender
            // Dialogkontext") haben userMessage gesetzt und fallen durch — die werden
            // weiterhin via isHBCITransientError mit clearSessionsOnly behandelt,
            // damit kein erzwungenes Re-2FA bei jedem Gateway-Hiccup entsteht.
            return userMessage == nil
        default:
            return false
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

    // MARK: - sendTransfer

    /// Initiiert eine SEPA-Überweisung über `client.transfer()` für den
    /// aktiven Slot. Im Demo-Mode wird die Bank-Anfrage durch ein Mock-
    /// Result ersetzt — kein Routex-Call.
    ///
    /// SCA (TAN/Browser-Redirect) wird über die bestehende `handleSCA`-
    /// Infrastruktur abgewickelt, identisch zu `fetchBalances`.
    ///
    /// - Returns: `TransferOutcome` mit `ok=true` bei Erfolg. Bei
    ///   `UnexpectedError`/`ProviderError` ist `mayHaveBeenExecuted=true`,
    ///   weil die Bank den Transfer trotzdem ausgeführt haben kann
    ///   (laut YAXI-Doku) — die UI muss das ehrlich kommunizieren.
    /// `requestedExecutionDate` ist optional. nil = sofort (SEPA Instant).
    /// Routex/YAXI nimmt einen `Date` und überträgt ihn als ISO-Date an die
    /// Bank. Wochenende/Feiertage werden serverseitig validiert; im
    /// Fehlerfall kommt ein `.failed`-Outcome mit der Bank-Begründung zurück.
    static func sendTransfer(
        request: TransferRequest,
        userId: String,
        password: String,
        requestedExecutionDate: Date? = nil
    ) async throws -> TransferOutcome {
        // Demo-Mode: kein Routex-Call, Mock-Erfolg. Stays consistent mit
        // dem Demo-Mode-Pattern in BalanceBar / MCP / CLI.
        if UserDefaults.standard.bool(forKey: "demoMode") {
            AppLogger.log("sendTransfer (demo): \(request.amountEUR) EUR → \(request.creditorIban.prefix(8))…", category: "YaxiService")
            try? await Task.sleep(nanoseconds: 800_000_000)  // ~UX-realistisches Delay
            return .demoSuccess
        }

        let slotSnapshot = activeSlotId
        // HBCI-Mutex via withSlot — blockiert parallele balance/transactions-
        // Refreshes während SCA gerade läuft. Bei busy graceful failen.
        let result: TransferOutcome? = try await BankRequestQueue.shared.withSlot(slotSnapshot) {
            try await sendTransferLocked(
                slotSnapshot: slotSnapshot,
                request: request,
                userId: userId,
                password: password,
                requestedExecutionDate: requestedExecutionDate
            )
        }
        guard let outcome = result else {
            AppLogger.log("sendTransfer: slot busy, abort slot=\(slotSnapshot.prefix(8))", category: "YaxiService", level: "WARN")
            return TransferOutcome(ok: false, scaRequired: false,
                                   error: "bank busy",
                                   userMessage: L10n.t("Bankverbindung gerade beschäftigt — bitte gleich erneut versuchen.",
                                                       "Bank connection busy — please try again shortly."),
                                   mayHaveBeenExecuted: false)
        }
        return outcome
    }

    /// Eigentlicher Transfer-Call. Vorausgesetzt: Caller hält den
    /// BankRequestQueue-Slot. Niemals direkt aufrufen — immer über `sendTransfer`.
    private static func sendTransferLocked(
        slotSnapshot: String,
        request: TransferRequest,
        userId: String,
        password: String,
        requestedExecutionDate: Date?
    ) async throws -> TransferOutcome {
        let connIdKey = connectionIdKey(for: slotSnapshot)
        let model = loadCredentialsModel(slotId: slotSnapshot)
        let d = UserDefaults.standard
        guard let connectionId = d.string(forKey: connIdKey), !connectionId.isEmpty else {
            return TransferOutcome(ok: false, scaRequired: false,
                                   error: "no connectionId yet",
                                   userMessage: nil, mayHaveBeenExecuted: false)
        }

        let storedCD = await sessionStore.connectionData(slotId: slotSnapshot)
        let storedSession = await sessionStore.session(for: .transfer, slotId: slotSnapshot)
        let creds = buildCredentials(
            connectionId: connectionId, model: model,
            connectionData: storedCD, userId: userId, password: password
        )

        let client = RoutexClient()
        // Mutable, damit retry-Pfade einen frischen Ticket ziehen können
        // (Yaxi-Doku: nach non-RequestError neuer Ticket nötig). Der finale
        // Wert nach dem inner-catch wird in `scaTicket` eingefroren und an die
        // confirm/respond-Closures übergeben.
        var ticket = await YaxiTicketMaker.issueTransferTicket()

        let amountString = NSDecimalNumber(decimal: request.amountEUR).stringValue
        let amount = Routex.Amount(currency: "EUR", amount: Decimal(string: amountString) ?? request.amountEUR)
        let details = [
            Routex.TransferDetails(
                endToEndIdentification: request.endToEndId,
                amount: amount,
                creditorAccount: .iban(request.creditorIban),
                creditorAgentBic: nil,
                creditorName: request.creditorName,
                creditorAddress: nil,
                remittance: request.remittance,
                chargeBearer: nil
            )
        ]

        AppLogger.log("sendTransfer: slot=\(slotSnapshot.prefix(8)) connId=\(connectionId.prefix(8)) → \(request.creditorIban.prefix(8))… amount=\(amountString)€", category: "YaxiService")

        do {
            var resp: Routex.TransferResponse
            do {
                resp = try await client.transfer(
                    credentials: creds,
                    session: storedSession,
                    recurringConsents: true,
                    ticket: ticket,
                    product: .sepaCreditTransfer,
                    details: details,
                    debtorAccount: nil,
                    debtorName: nil,
                    requestedExecutionDate: requestedExecutionDate
                )
            } catch {
                // YAXI-Doku: nach non-RequestError frischer Ticket nötig.
                if shouldRetryWithoutUserId(error: error, model: model, userId: userId) {
                    let credsNoUserId = buildCredentials(
                        connectionId: connectionId, model: model,
                        connectionData: storedCD, userId: nil, password: password
                    )
                    ticket = await YaxiTicketMaker.issueTransferTicket()
                    resp = try await client.transfer(
                        credentials: credsNoUserId,
                        session: storedSession,
                        recurringConsents: true,
                        ticket: ticket,
                        product: .sepaCreditTransfer,
                        details: details,
                        debtorAccount: nil,
                        debtorName: nil,
                        requestedExecutionDate: requestedExecutionDate
                    )
                } else if isConnectionResetError(error), storedCD != nil {
                    // Yaxi-Empfehlung „Restart the service without passing
                    // connection data" — frischer Ticket + connectionData weg,
                    // Session behalten (Sparkasse-Regression bei Drop, 2026-05-12).
                    AppLogger.log("sendTransfer: consent expired, retrying without connectionData", category: "YaxiService", level: "WARN")
                    let credsNoCD = buildCredentials(
                        connectionId: connectionId, model: model,
                        connectionData: nil, userId: userId, password: password
                    )
                    ticket = await YaxiTicketMaker.issueTransferTicket()
                    resp = try await client.transfer(
                        credentials: credsNoCD,
                        session: storedSession,
                        recurringConsents: true,
                        ticket: ticket,
                        product: .sepaCreditTransfer,
                        details: details,
                        debtorAccount: nil,
                        debtorName: nil,
                        requestedExecutionDate: requestedExecutionDate
                    )
                } else {
                    throw error
                }
            }

            // Einfrieren des aktuellen (ggf. nach retry getauschten) Tickets,
            // damit die @Sendable-Closures eine let-bound Capture haben.
            let scaTicket = ticket
            let confirm: @Sendable (ConfirmationContext) async throws -> SCACommon = { ctx in
                try await toSCACommon(client.confirmTransfer(ticket: scaTicket, context: ctx))
            }
            let respond: @Sendable (InputContext, String) async throws -> SCACommon = { ctx, r in
                try await toSCACommon(client.respondTransfer(ticket: scaTicket, context: ctx, response: r))
            }

            guard let outcome = await handleSCA(
                initial: toSCACommon(resp), client: client, ticket: scaTicket,
                confirm: confirm, respond: respond
            ) else {
                return TransferOutcome(ok: false, scaRequired: true, error: nil,
                                       userMessage: nil, mayHaveBeenExecuted: false)
            }

            // Connection-Data refreshen (Session ist out-of-band sowieso obsolete
            // nach dem Call, aber connectionData kann erneuert worden sein).
            // Transfer hat eigenen Scope, damit der Session-Token nicht in
            // Folge-Balance/Transactions-Calls leakt.
            await sessionStore.update(scope: .transfer,
                                      session: outcome.session,
                                      connectionData: outcome.connectionData,
                                      slotId: slotSnapshot)

            guard case .transfer = outcome.payload else {
                return TransferOutcome(ok: false, scaRequired: false,
                                       error: "unexpected result type",
                                       userMessage: nil, mayHaveBeenExecuted: false)
            }

            AppLogger.log("sendTransfer: success", category: "YaxiService")
            return TransferOutcome(ok: true, scaRequired: false, error: nil,
                                   userMessage: nil, mayHaveBeenExecuted: false)

        } catch {
            await writeTrace(client: client, label: "sendTransfer", ticket: ticket, error: error)
            AppLogger.log("sendTransfer error: \(error.localizedDescription)", category: "YaxiService", level: "ERROR")
            // YAXI-Doku-Hinweis: bei UnexpectedError/ProviderError kann der
            // Transfer trotzdem ausgeführt worden sein. Caller-UI muss
            // ehrlich kommunizieren: „Status unklar, prüfe Banking-App".
            let msg = error.localizedDescription.lowercased()
            let mayBeExecuted =
                msg.contains("unexpected") || msg.contains("provider")
            return TransferOutcome(
                ok: false, scaRequired: false,
                error: error.localizedDescription,
                userMessage: nil,
                mayHaveBeenExecuted: mayBeExecuted
            )
        }
    }

    // MARK: - Response mapping

    private static func makeBalancesResponse(
        _ result: AuthenticatedBalancesResult,
        session: Session?,
        connectionData: ConnectionData?,
        requestedIban: String = ""
    ) -> BalancesResponse {
        // YAXI liefert für Banken wie 1822direkt mehrere Account-Einträge zurück
        // (Girokonto + Tagesgeld + Visa-Karten-Subkonto). `first` ist russisches
        // Roulette — kann ein Subaccount ohne Booked-Balance treffen.
        // Per IBAN matchen, Fallback auf first wie bisher.
        let allEntries = result.toData().data.balances
        let target = requestedIban
            .replacingOccurrences(of: " ", with: "")
            .uppercased()

        let matchedIdx: Int? = {
            guard !target.isEmpty else { return nil }
            for (i, e) in allEntries.enumerated() {
                if case .iban(let id) = e.account.id,
                   id.replacingOccurrences(of: " ", with: "").uppercased() == target {
                    return i
                }
            }
            return nil
        }()

        let allBalances: [Balance]
        if let idx = matchedIdx {
            allBalances = allEntries[idx].balances
        } else if !target.isEmpty, !allEntries.isEmpty {
            AppLogger.log("makeBalancesResponse: requested IBAN \(target.prefix(8))… not in response (got \(allEntries.count) entries), using first as fallback",
                          category: "YaxiService", level: "WARN")
            allBalances = allEntries.first?.balances ?? []
        } else {
            allBalances = allEntries.first?.balances ?? []
        }

        // Priority: Booked > Available > Expected (matches canonical YAXI-MoneyMoney
        // reference in `mapping/balance.lua`). `Booked` is the authoritative posted balance.
        // At some banks `Available` = booked + overdraft line (Dispokredit) — misleading
        // as "Kontostand". Hence Booked first.
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
            balanceType: balanceTypeName(b.balanceType),
            creditLimitIncluded: b.creditLimitIncluded
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
        case transfer(AuthenticatedTransferResult)
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

    private static func toSCACommon(_ r: Routex.TransferResponse) -> SCACommon {
        switch r {
        case .result(let res, let s, let cd): return .result(.transfer(res), s, cd)
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

            case .field(let type, let secrecy, let minLen, let maxLen, let context):
                // Kein Provider gesetzt = wir laufen ohne UI (Tests/CLI). Sauberer
                // Abbruch wie bisher, damit nicht-UI-Konsumenten nicht crashen.
                guard let provider = fieldInputProvider else {
                    AppLogger.log("SCA field: no provider registered, aborting",
                                  category: "YaxiService", level: "WARN")
                    return nil
                }
                let slotEpochSnapshot = await MainActor.run {
                    MultibankingStore.shared.activeSlotEpoch
                }
                let bankName = await MainActor.run {
                    MultibankingStore.shared.activeSlot?.displayName ?? "Bank"
                }
                let spec = SCAFieldInput.Spec(
                    type: type, secrecyLevel: secrecy,
                    minLength: minLen, maxLength: maxLen,
                    bankDisplayName: bankName,
                    slotEpochAtRequest: slotEpochSnapshot
                )
                // Nur Metadaten loggen — der eingegebene Wert ist Secret.
                AppLogger.log(
                    "SCA field: requesting input type=\(type) secrecy=\(secrecy) " +
                    "min=\(minLen.map(String.init) ?? "—") max=\(maxLen.map(String.init) ?? "—")",
                    category: "YaxiService"
                )
                guard let userValue = await provider(spec) else {
                    AppLogger.log("SCA field: user cancelled", category: "YaxiService")
                    return nil
                }
                // Slot-Race: User hat während Eingabe Bank gewechselt → der
                // InputContext zeigt auf eine fremde Session, nicht abschicken.
                let currentEpoch = await MainActor.run {
                    MultibankingStore.shared.activeSlotEpoch
                }
                guard currentEpoch == slotEpochSnapshot else {
                    AppLogger.log("SCA field: slot epoch changed during input, aborting",
                                  category: "YaxiService", level: "WARN")
                    return nil
                }
                do {
                    let next = try await respond(context, userValue)
                    return await handleSCA(initial: next, client: client, ticket: ticket,
                                           confirm: confirm, respond: respond, depth: depth + 1)
                } catch {
                    AppLogger.log("SCA field respond error: \(error.localizedDescription)",
                                  category: "YaxiService", level: "ERROR")
                    return nil
                }
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

    /// Höhere Schwelle als die ursprünglichen 3, um Rate-Limit-Bursts (z.B. N26
    /// schickt mehrere 429er hintereinander) nicht als fatalen SCA-Abbruch
    /// zu interpretieren. 8 consecutive errors mit exponentiellem Backoff ergibt
    /// realen Retry-Spielraum (insgesamt bis zu ~3 Min Pause zwischen Polls).
    static let scaMaxConsecutiveErrors = 8

    /// Exponentielles Backoff für SCA-Polling nach Bank-Errors. Wird ZUSÄTZLICH
    /// zum bank-supplied `currentDelay` aufgeschlagen — die Bank kann uns also
    /// nicht in zu schnelles Polling zwingen, wenn sie kurzzeitig instabil ist.
    /// Curve: 2s, 4s, 8s, 16s, 30s (cap), 30s, 30s, 30s.
    /// Pure function — public für Tests in `SCARetryBackoffTests`.
    static func scaBackoffSeconds(forConsecutiveErrors n: Int,
                                  base: TimeInterval = 2.0,
                                  cap: TimeInterval = 30.0) -> TimeInterval {
        guard n > 0 else { return 0 }
        let exponent = Double(min(n - 1, 10))   // prevent pow overflow on absurd inputs
        return min(base * pow(2.0, exponent), cap)
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
        var errorBackoff: TimeInterval = 0
        for i in 0..<180 {
            let sleepSeconds = max(currentDelay, 1.0) + errorBackoff
            try? await Task.sleep(nanoseconds: UInt64(sleepSeconds * 1_000_000_000))
            if Task.isCancelled { return nil }
            do {
                let next = try await confirm(ctx)
                consecutiveErrors = 0
                errorBackoff = 0  // reset nach erfolgreicher Antwort
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
                errorBackoff = scaBackoffSeconds(forConsecutiveErrors: consecutiveErrors)
                AppLogger.log("SCA Confirmation poll \(i) error (\(consecutiveErrors) consecutive, next backoff \(errorBackoff)s): \(error.localizedDescription)", category: "YaxiService", level: "WARN")
                // Höherer Threshold + Backoff schützt gegen 429-Rate-Limit-Bursts.
                if consecutiveErrors >= scaMaxConsecutiveErrors { return nil }
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
                // pollRedirect schläft bereits 5s zwischen Polls — kleinerer
                // additional Backoff (cap 15s) reicht, sonst staut sich die
                // Gesamtwartezeit zu sehr auf.
                let extra = scaBackoffSeconds(forConsecutiveErrors: consecutiveErrors, base: 2.0, cap: 15.0)
                AppLogger.log("SCA Redirect poll error (\(consecutiveErrors) consecutive, extra backoff \(extra)s): \(error.localizedDescription)", category: "YaxiService", level: "WARN")
                if consecutiveErrors >= scaMaxConsecutiveErrors {
                    await writeTrace(client: client, label: "pollRedirect", ticket: ticket, error: error)
                    return nil
                }
                if extra > 0 {
                    try? await Task.sleep(nanoseconds: UInt64(extra * 1_000_000_000))
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
