import AppKit
import Foundation
import RoutexClient
import Security
import UserNotifications

// MARK: - YaxiService
// Replaces NetworkService + BackendManager. Calls the YAXI API directly via
// routex-client-swift (Rust FFI). No Node.js process required.

/// Lässt genau einen von mehreren Wettläufern gewinnen.
///
/// Stand bis SDK 0.4.1 direkt in `pollRedirect`. Seit die Funktion über den Tickettyp
/// generisch ist, erlaubt Swift dort keinen verschachtelten Typ mehr — deshalb hier.
private final class EinmaligerAusloeser: @unchecked Sendable {
    private var done = false
    func tryFire() -> Bool { guard !done else { return false }; done = true; return true }
}

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
    /// Zweiter Parameter ist der Slot, dessen Bank fragt. Ohne ihn galt der Hinweis
    /// für alle Konten gleichzeitig.
    nonisolated(unsafe) static var onTanStateChanged: (@MainActor (Bool, String) -> Void)?

    /// Wird vom SCA-`.field`-Branch in `handleSCA` aufgerufen, wenn die Bank
    /// eine TAN/PIN-Eingabe verlangt. Meldet den eingegebenen String über die
    /// Completion — oder nil bei User-Cancel. Wird einmalig in `BalanceBar` beim
    /// App-Start auf `SCAFieldInputPresenter.present(_:completion:)` verdrahtet.
    /// Bleibt nil in Test-/CLI-Kontexten — dann bricht der Branch wie bisher mit
    /// WARN ab.
    ///
    /// Bewusst mit Completion statt `async`: Der Aufrufer muss das Panel synchron
    /// aus einem Runloop-Callback heraus aufbauen können (siehe `onMainRunLoop`).
    /// Eine `async`-Signatur zwänge ihn zurück auf die Main-Queue, die während einer
    /// modalen Sitzung nicht bedient wird.
    nonisolated(unsafe) static var fieldInputProvider:
        (@MainActor (SCAFieldInput.Spec, @escaping @MainActor (String?) -> Void) -> Void)?

    /// Meldet den SCA-Methodentyp, sobald `handleSCA` ihn kennt — damit die Setup-UI
    /// den Fortschrittstext passend setzt (Code-Eingabe vs. App-Freigabe). Vom
    /// Setup-Flow gesetzt (mit `defer nil`), sonst nil → kein Effekt.
    nonisolated(unsafe) static var scaMethodReporter:
        (@Sendable (SCAMethodHint) -> Void)?

    /// Schreibt Zwischenschritte in das Einrichtungsprotokoll.
    ///
    /// Die Freigabe ist der Teil der Einrichtung, der am häufigsten hakt — und
    /// gleichzeitig der einzige, von dem in der Diagnosedatei bisher nichts stand:
    /// Redirect geöffnet, wie oft gepollt, ob eine Zustimmung zurückkam. Wer das
    /// wissen wollte, musste es aus dem Hauptprotokoll zusammensuchen und die
    /// Zeitstempel von Hand abgleichen. Vom Setup-Flow gesetzt (mit `defer nil`).
    nonisolated(unsafe) static var setupPhaseReporter:
        (@Sendable (String, [String: String]) -> Void)?

    // MARK: - UserDefaults keys (per-slot)
    // "legacy" slot uses the original key names for backward compatibility.

    private static func slotSuffix(for slotId: String) -> String { slotId == "legacy" ? "" : ".\(slotId)" }
    private static func slotSuffix() -> String { slotSuffix(for: activeSlotId) }
    static func ibanKey(for slotId: String) -> String { "simplebanking.iban\(slotSuffix(for: slotId))" }
    static func connectionIdKey(for slotId: String) -> String { "simplebanking.yaxi.connectionId\(slotSuffix(for: slotId))" }
    static func credModelFullKey(for slotId: String) -> String { "simplebanking.yaxi.credModel.full\(slotSuffix(for: slotId))" }
    static func credModelUserIdKey(for slotId: String) -> String { "simplebanking.yaxi.credModel.userId\(slotSuffix(for: slotId))" }
    static func credModelNoneKey(for slotId: String) -> String { "simplebanking.yaxi.credModel.none\(slotSuffix(for: slotId))" }
    /// Anzeigename der Bank aus der Banksuche. Wird nur für Beschriftungen gebraucht —
    /// beim Ersteinrichten gibt es noch keinen Slot, dessen `displayName` man fragen
    /// könnte, und das TAN-Panel hieß deshalb nur „Bank".
    static func connectionNameKey(for slotId: String) -> String { "simplebanking.yaxi.connectionName\(slotSuffix(for: slotId))" }
    static var ibanKey: String { ibanKey(for: activeSlotId) }
    static var connectionIdKey: String { connectionIdKey(for: activeSlotId) }
    static var credModelFullKey: String { credModelFullKey(for: activeSlotId) }
    static var credModelUserIdKey: String { credModelUserIdKey(for: activeSlotId) }
    static var credModelNoneKey: String { credModelNoneKey(for: activeSlotId) }
    static var connectionNameKey: String { connectionNameKey(for: activeSlotId) }

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
            /// Wann die connectionData zuletzt geschrieben wurde.
            ///
            /// Bis 2.0.2 bewusst nur im Speicher, mit der Begründung, „nicht frisch" sei
            /// die vorsichtigere Annahme. Das war ein Trugschluss: Unbekanntes Alter
            /// **erlaubt** das Verwerfen (`darfOhneConnectionDataWiederholen`), der
            /// Schutz war nach jedem App-Start also aus. Jetzt mitgespeichert.
            var connectionDataAt: Date?
        }
        private var slotStates: [String: SlotState] = [:]

        /// Lädt einen Slot lazy beim ersten Zugriff aus der Disk in den Cache.
        /// Wird vom `actor` automatisch serialisiert — gleichzeitige Reads für
        /// denselben Slot finden nach dem ersten Load alle den Cache-Hit.
        private func loadIfNeeded(_ slotId: String) -> SlotState {
            if let cached = slotStates[slotId] { return cached }
            var state = SlotState()
            // Sessions werden bewusst NICHT von der Platte gelesen. YAXI beschreibt sie
            // als kurzlebig und nach Übergabe an einen Dienst als verbraucht; dauerhaft
            // gehört nur `connectionData` gespeichert. Eine Session aus einer früheren
            // Sitzung ist bestenfalls wirkungslos und schlimmstenfalls ein Grund, warum
            // ein Aufruf scheitert. Alte Schlüssel räumt `alteSessionsAufraeumen` weg.
            state.connectionData      = SessionStore.persistRead("connectionData",       slotId: slotId)
            state.connectionDataAt    = SessionStore.persistRead("connectionDataAt",     slotId: slotId)
                .flatMap { String(data: $0, encoding: .utf8) }
                .flatMap { TimeInterval($0) }
                .map { Date(timeIntervalSince1970: $0) }
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
        /// Gibt die Session heraus **und verbraucht sie**.
        ///
        /// „a session object should be considered obsolete after passing it to a
        /// service" — dann darf sie auch nicht liegen bleiben und ein zweites Mal
        /// mitgehen. Bis 05.09.2026 blieb sie stehen, bis eine neue kam.
        func session(for scope: Scope, slotId: String) -> Data? {
            let state = loadIfNeeded(slotId)
            let vorhandene: Data?
            switch scope {
            case .balances:     vorhandene = state.balancesSession
            case .transactions: vorhandene = state.transactionsSession
            case .transfer:     vorhandene = state.transferSession
            }
            guard vorhandene != nil else { return nil }
            mutateState(slotId) { s in
                switch scope {
                case .balances:     s.balancesSession = nil
                case .transactions: s.transactionsSession = nil
                case .transfer:     s.transferSession = nil
                }
            }
            return vorhandene
        }

        /// Räumt die früher dauerhaft abgelegten Sessions einmalig weg — sie sind
        /// wertlos und hätten sonst unbegrenzt im Schlüsselbund bzw. in den
        /// Einstellungen gelegen.
        func alteSessionsAufraeumen(slotIds: [String]) {
            for sid in slotIds {
                persistDelete("session.balances",     slotId: sid)
                persistDelete("session.transactions", slotId: sid)
                persistDelete("session.transfer",     slotId: sid)
            }
        }

        func connectionData(slotId: String) -> Data? {
            loadIfNeeded(slotId).connectionData
        }

        /// Alter der connectionData in Sekunden, `nil` wenn sie aus einer früheren
        /// Sitzung stammt (dann ist der Zeitpunkt unbekannt).
        func connectionDataAge(slotId: String) -> TimeInterval? {
            loadIfNeeded(slotId).connectionDataAt.map { Date().timeIntervalSince($0) }
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
                    // Kein `persistWrite` mehr: Die Session lebt nur für die Folge von
                    // Aufrufen, die gerade läuft.
                }
                if let cd = connectionData {
                    state.connectionData = cd
                    state.connectionDataAt = Date()
                    persistWrite("connectionData", slotId: sid, data: cd)
                    persistZeitstempel(state.connectionDataAt, slotId: sid)
                }
            }
        }

        func updateConnectionData(_ connectionData: Data?, slotId: String? = nil) {
            let sid = slotId ?? YaxiService.activeSlotId
            guard let connectionData else { return }
            mutateState(sid) { state in
                state.connectionData = connectionData
                state.connectionDataAt = Date()
                persistWrite("connectionData", slotId: sid, data: connectionData)
                persistZeitstempel(state.connectionDataAt, slotId: sid)
            }
        }

        /// Der Zeitstempel geht denselben Weg wie die Zustimmung selbst (Keychain oder
        /// UserDefaults, je nach Signatur), damit beide zusammen bleiben und nicht ein
        /// Teil den Neustart überlebt und der andere nicht.
        private func persistZeitstempel(_ wann: Date?, slotId: String) {
            guard let wann, let daten = String(wann.timeIntervalSince1970).data(using: .utf8) else {
                persistDelete("connectionDataAt", slotId: slotId)
                return
            }
            persistWrite("connectionDataAt", slotId: slotId, data: daten)
        }

        func clearAll(slotId: String? = nil) {
            let sid = slotId ?? YaxiService.activeSlotId
            slotStates[sid] = SlotState()
            persistDelete("session.balances",    slotId: sid)
            persistDelete("session.transactions", slotId: sid)
            persistDelete("session.transfer",     slotId: sid)
            persistDelete("connectionData",       slotId: sid)
            persistDelete("connectionDataAt",     slotId: sid)
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
    /// Führt `body` auf dem Main-Thread aus — auch während einer modalen Sitzung.
    ///
    /// `await MainActor.run` reiht den Block in die Main-Dispatch-Queue ein, und die
    /// wird nur in den Common-Modes bedient. `NSApp.runModal()` fährt die Runloop aber
    /// in `NSModalPanelRunLoopMode`, der nicht dazugehört: Solange der
    /// Einrichtungsassistent modal läuft, bleibt so ein Hop schlicht liegen, bis die
    /// Sitzung endet. Bei Banken mit Tipp-TAN (HypoVereinsbank) verzögerte das die
    /// Anzeige des TAN-Felds bis zum Abbruch — gemessen 17 bis 60 Sekunden, die TAN war
    /// dann abgelaufen. `RunLoop.perform(inModes:)` wird auch im Modal-Mode bedient;
    /// `SetupFlowPanel.enqueueOnMainRunLoop` nimmt für seine Callbacks denselben Weg.
    static func onMainRunLoop<T: Sendable>(_ body: @escaping @MainActor @Sendable () -> T) async -> T {
        await withCheckedContinuation { (cont: CheckedContinuation<T, Never>) in
            RunLoop.main.perform(inModes: [.default, .modalPanel]) {
                MainActor.assumeIsolated { cont.resume(returning: body()) }
            }
        }
    }



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
        if let v = d.string(forKey: connectionNameKey(for: fromSlotId)), !v.isEmpty {
            d.set(v, forKey: connectionNameKey(for: toSlotId))
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
        d.removeObject(forKey: connectionNameKey)
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
        let client = YaxiTransport.client()
        do {
            // Wirft seit SDK 0.5: Der Ticket-Typ prüft die Dienstangabe im Token.
            let ticket = try YaxiTicketMaker.accountsTicket()
            return try await client.search(
                ticket: ticket,
                filters: terms.map { .term($0) },
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
        // `.description` ist die Drahtform („connection-<uuid>"). Seit SDK 0.5 ist `id`
        // ein `ConnectionID`-Werttyp; ihn direkt abzulegen ließ die App abstürzen —
        // UserDefaults nimmt nur Property-List-Typen und wirft sonst eine
        // Objective-C-Ausnahme, die den Prozess beendet. Der Compiler warnt nicht, weil
        // `set` ein `Any?` entgegennimmt. Gemeldet als Absturz beim Einrichten (23.08.).
        d.set(info.id.description, forKey: connectionIdKey)
        d.set(info.credentials.full,   forKey: credModelFullKey)
        d.set(info.credentials.userID, forKey: credModelUserIdKey)
        d.set(info.credentials.none,   forKey: credModelNoneKey)
        d.set(info.displayName,        forKey: connectionNameKey)
        AppLogger.log("storeConnectionInfo: connId=\(info.id.description.prefix(8)) name=\(info.displayName)", category: "YaxiService")
    }

    /// Clears connection state without storing an IBAN (for accounts() flow).
    static func clearConnectionState() async {
        let d = UserDefaults.standard
        d.removeObject(forKey: ibanKey)
        d.removeObject(forKey: connectionIdKey)
        d.removeObject(forKey: credModelFullKey)
        d.removeObject(forKey: credModelUserIdKey)
        d.removeObject(forKey: credModelNoneKey)
        d.removeObject(forKey: connectionNameKey)
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

        let client = YaxiTransport.client()
        do {
            // Wirft seit SDK 0.5: Der Ticket-Typ prüft die Dienstangabe im Token.
            let ticket = try YaxiTicketMaker.accountsTicket()
            let results = try await client.search(
                ticket: ticket,
                filters: [.term(iban)],
                ibanDetection: true,
                limit: 20
            )
            guard let pick = results.first else {
                AppLogger.log("discoverBank: no connections found", category: "YaxiService", level: "WARN")
                return nil
            }

            let d = UserDefaults.standard
            d.set(pick.id.description, forKey: connectionIdKey)
            d.set(pick.credentials.full, forKey: credModelFullKey)
            d.set(pick.credentials.userID, forKey: credModelUserIdKey)
            d.set(pick.credentials.none, forKey: credModelNoneKey)

            AppLogger.log("discoverBank: found \(pick.displayName)", category: "YaxiService")
            return DiscoveredBank(
                id: pick.id.description,
                displayName: pick.displayName,
                logoId: pick.logoID,
                credentials: DiscoveredBankCredentials(
                    full: pick.credentials.full,
                    userId: pick.credentials.userID,
                    none: pick.credentials.none
                ),
                userIdLabel: pick.userIDLabel?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
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
        let client = YaxiTransport.client()
        do {
            // Wirft seit SDK 0.5: Der Ticket-Typ prüft die Dienstangabe im Token.
            let ticket = try YaxiTicketMaker.accountsTicket()
            let results = try await client.search(
                ticket: ticket,
                filters: [.term(term)],
                ibanDetection: false,
                limit: 20
            )
            guard let pick = results.first else {
                AppLogger.log("discoverBankByTerm: no connections found for '\(term)'", category: "YaxiService", level: "WARN")
                return nil
            }
            let d = UserDefaults.standard
            d.set(pick.id.description, forKey: connectionIdKey)
            d.set(pick.credentials.full, forKey: credModelFullKey)
            d.set(pick.credentials.userID, forKey: credModelUserIdKey)
            d.set(pick.credentials.none, forKey: credModelNoneKey)
            AppLogger.log("discoverBankByTerm: found \(pick.displayName)", category: "YaxiService")
            return DiscoveredBank(
                id: pick.id.description,
                displayName: pick.displayName,
                logoId: pick.logoID,
                credentials: DiscoveredBankCredentials(
                    full: pick.credentials.full,
                    userId: pick.credentials.userID,
                    none: pick.credentials.none
                ),
                userIdLabel: pick.userIDLabel?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
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
    /// `callSource` steuert ob bei `UnexpectedError` ein User-Report-Prompt
    /// erscheint (siehe `ErrorReportStore.CallSource`). Default `.normal`.
    /// - Parameter alwaysTrace: schreibt auch bei Erfolg einen YAXI-Trace. Die
    ///   Einrichtung setzt das immer: Läuft sie durch und die Bank liefert trotzdem
    ///   Unsinn, gab es hinterher nur Schrittnamen und Millisekunden — der eine
    ///   Roundtrip, auf den es ankommt, fehlte. Konten ist dabei der erste und
    ///   teuerste Schritt: Wer hier nachbessern will, zahlt eine neue Freigabe.
    static func fetchAccounts(
        userId: String,
        password: String,
        alwaysTrace: Bool = false,
        callSource: ErrorReportStore.CallSource = .normal
    ) async throws -> [RoutexModels.Account] {
        let slotSnapshot = activeSlotId
        let connIdKey = connectionIdKey(for: slotSnapshot)
        let model = loadCredentialsModel(slotId: slotSnapshot)
        let d = UserDefaults.standard
        guard let connectionId = d.string(forKey: connIdKey), !connectionId.isEmpty else {
            throw NSError(domain: "YaxiService", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "no connectionId for accounts()"])
        }
        let storedCD = await sessionStore.connectionData(slotId: slotSnapshot)
        // Alter der Zustimmung mitschreiben: Ohne sie sagt „167b" nichts darüber,
        // ob die Daten frisch sind oder seit Tagen unverändert mitgeschickt werden.
        let cdAlter = await sessionStore.connectionDataAge(slotId: slotSnapshot)
        AppLogger.log("fetchAccounts: slot=\(slotSnapshot.prefix(8)) storedCD=\(storedCD == nil ? "nil" : "\(storedCD!.count)b") alter=\(cdAlter.map { String(format: "%.1fh", $0 / 3600) } ?? "?") model.none=\(model.none)", category: "YaxiService")
        var storedSession = await sessionStore.session(for: .balances, slotId: slotSnapshot)
        let creds = try buildCredentials(
            connectionId: connectionId, model: model,
            connectionData: storedCD, userId: userId, password: password
        )

        let client = YaxiTransport.client()
        // `var` so the retry can issue a fresh ticket — after UnexpectedError the old
        // ticket's server-side state is undefined and reusing it risks another failure.
        var ticket = try YaxiTicketMaker.accountsTicket()

        AppLogger.log("fetchAccounts: slot=\(slotSnapshot.prefix(8)) connId=\(connectionId.prefix(8)) session=\(storedSession == nil ? "nil" : "present")", category: "YaxiService")

        let resp: Response<AccountsResult>
        do {
            resp = try await client.accounts(
                ticket: ticket,
                credentials: creds,
                fields: [.iban, .displayName, .ownerName, .currency],
                filter: .notEq(.iban(nil)),
                session: storedSession.map(Session.init),
                recurringConsents: true
            )
        } catch {
            // **Absichtlich jeder Fehler.** Bis SDK 0.4.1 stand hier
            // `catch let error as RoutexClientError`, und das fing die Bankfehler mit.
            // Seit 0.5 heißen die `RoutexError`; die alte Klausel hätte weiter
            // kompiliert, aber nie wieder zugegriffen — der zweite Versuch wäre
            // lautlos ausgefallen und die Einrichtung an einem Fehler gestorben, den
            // ein frisches Ticket geheilt hätte. Genau der Fall, den die
            // Migrationsanleitung als „vom Compiler nicht angemerkt" führt.
            //
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
            ticket = try YaxiTicketMaker.accountsTicket()
            do {
                resp = try await client.accounts(
                ticket: ticket,
                credentials: creds,
                fields: [.iban, .displayName, .ownerName, .currency],
                filter: .notEq(.iban(nil)),
                session: nil,
                recurringConsents: true
            )
            } catch let retryError {
                // Final failure — capture für „Problem melden"-Flow.
                // Kennung sofort lesen: siehe Erläuterung in `fetchBalances`.
                let traceId = await client.traceID
                await captureUnexpectedErrorIfNeeded(
                    error: retryError, client: client, ticket: ticket,
                    slotSnapshot: slotSnapshot, callName: "fetchAccounts",
                    callSource: callSource, traceId: traceId
                )
                throw retryError
            }
        }

        // Snapshot the final ticket value so @Sendable closures capture an immutable copy.
        let finalTicket = ticket
        let confirm: @Sendable (ConfirmationContext) async throws -> SCACommon = { ctx in
            try await toSCACommonAccounts(client.confirmAccounts(ticket: finalTicket, context: ctx))
        }
        let respond: @Sendable (InputContext, String) async throws -> SCACommon = { ctx, r in
            try await toSCACommonAccounts(client.respondAccounts(ticket: finalTicket, context: ctx, response: r))
        }

        // Datenabrufe behandeln `unklar` wie einen Fehlschlag: Ein nicht gelesener Saldo
        // richtet keinen Schaden an. Nur bei Zahlungen ist der Unterschied wichtig.
        guard case .erfolg(let outcome) = await handleSCA(
            initial: toSCACommonAccounts(resp), client: client, ticket: finalTicket, slotId: slotSnapshot,
            confirm: confirm, respond: respond
        ) else {
            throw NSError(domain: "YaxiService", code: -2,
                          userInfo: [NSLocalizedDescriptionKey: "Konten: Freigabe konnte nicht abgeschlossen werden (Schritt 1 von 3). Bitte erneut verbinden."])
        }

        // Accounts establishes recurring consent and fresh connectionData for follow-up
        // service calls, but its session must not bleed into balances/transactions.
        await sessionStore.updateConnectionData(outcome.connectionData?.bytes, slotId: slotSnapshot)

        guard case .accounts(let authResult) = outcome.payload else {
            throw NSError(domain: "YaxiService", code: -3,
                          userInfo: [NSLocalizedDescriptionKey: "unexpected result type from accounts()"])
        }
        if alwaysTrace {
            await writeTrace(client: client, label: "setup-fetchAccounts-ok",
                             ticket: finalTicket, error: nil, traceId: await client.traceID)
        }
        return try authResult.decodeUnverified().data
    }

    /// `alwaysTrace=true` schreibt nach erfolgreicher Antwort zusätzlich
    /// einen YAXI-Trace via `writeTrace()` — für Diagnose-Probes, die auch
    /// bei Erfolg den vollen HTTP-Roundtrip dokumentieren wollen. Im
    /// normalen Refresh-Pfad (default false) bleibt der Trace nur Error-Pfad.
    static func fetchBalances(
        userId: String,
        password: String,
        alwaysTrace: Bool = false,
        callSource: ErrorReportStore.CallSource = .normal
    ) async throws -> BalancesResponse {
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
                alwaysTrace: alwaysTrace,
                callSource: callSource
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
        alwaysTrace: Bool,
        callSource: ErrorReportStore.CallSource
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
        // Alter der Zustimmung mitschreiben: Ohne sie sagt „167b" nichts darüber,
        // ob die Daten frisch sind oder seit Tagen unverändert mitgeschickt werden.
        let cdAlter = await sessionStore.connectionDataAge(slotId: slotSnapshot)
        AppLogger.log("fetchBalances: slot=\(slotSnapshot.prefix(8)) storedCD=\(storedCD == nil ? "nil" : "\(storedCD!.count)b") alter=\(cdAlter.map { String(format: "%.1fh", $0 / 3600) } ?? "?") model.none=\(model.none)", category: "YaxiService")
        let storedSession = await sessionStore.session(for: .balances, slotId: slotSnapshot)
        let creds = try buildCredentials(
            connectionId: connectionId, model: model,
            connectionData: storedCD, userId: userId, password: password
        )

        // Erst der nicht-interaktive Weg. Er braucht nur die gespeicherte Zustimmung und
        // kennt keine Freigabe-Zweige; klappt er, ist der Abruf hier zu Ende. Klappt er
        // nicht, läuft unverändert alles Bisherige — inklusive Wiederholungen,
        // Zustimmungsregeln und Fehlerbericht.
        if let cd = storedCD,
           let schnell = await schnellSalden(slotSnapshot: slotSnapshot,
                                             connectionData: cd,
                                             accountRefs: accountRefs,
                                             iban: iban) {
            return schnell
        }

        let client = YaxiTransport.client()
        // Mutable — wird im retry-Pfad bei Bedarf neu ausgestellt (Yaxi-Doku:
        // nach non-RequestError frischer Ticket). Der finale Wert nach dem
        // inner-catch wird in `scaTicket` eingefroren für die SCA-Closures.
        var ticket = try YaxiTicketMaker.balancesTicket()

        AppLogger.log("fetchBalances: slot=\(slotSnapshot.prefix(8)) connId=\(connectionId.prefix(8)) iban=\(iban.isEmpty ? "(auto)" : String(iban.prefix(8))) cd=\(storedCD == nil ? "nil" : "\(storedCD!.count)b")", category: "YaxiService")

        do {
            var resp: Response<BalancesResult>
            do {
                resp = try await client.balances(
                ticket: ticket,
                credentials: creds,
                accounts: accountRefs,
                session: storedSession.map(Session.init),
                recurringConsents: true
            )
            } catch {
                // Rohfehler VOR der Einordnung: Die Zweige darunter legen ihn auf
                // eine Deutung fest („consent expired") und loggen nur diese. Bei
                // HypoVereinsbank stand das im Protokoll, obwohl die connectionData
                // vierzig Sekunden alt war — ohne den Rohwert war nicht zu sehen, ob
                // die Bank das wirklich sagte oder unsere Heuristik es hineinlas.
                AppLogger.log("fetchBalances: Rohfehler vor Einordnung: \(String(reflecting: error))",
                              category: "YaxiService", level: "WARN")
                // Einmal ermittelt, weil die Deutung im zweistufigen Wiederanlauf
                // ein zweites Mal gebraucht wird.
                let cdAlter = await sessionStore.connectionDataAge(slotId: slotSnapshot)
                // YAXI-Doku: nach jedem non-RequestError ist der Service in
                // "failed state" → "need to start it again, with a new ticket".
                // Wir holen daher in jedem retry-Branch (außer Network) einen
                // frischen Ticket. Network-Errors sind explizit ausgenommen.
                if shouldRetryWithoutUserId(error: error, model: model, userId: userId) {
                    let credsNoUserId = try buildCredentials(
                        connectionId: connectionId, model: model,
                        connectionData: storedCD, userId: nil, password: password
                    )
                    ticket = try YaxiTicketMaker.balancesTicket()
                    let retryTicket = ticket
                    resp = try await client.balances(
                ticket: retryTicket,
                credentials: credsNoUserId,
                accounts: accountRefs,
                session: storedSession.map(Session.init),
                recurringConsents: true
            )
                } else if darfOhneConnectionDataWiederholen(
                              error: error,
                              connectionDataAge: cdAlter),
                          storedCD != nil {
                    // Consent abgelaufen (Unauthorized / ConsentExpired):
                    // YAXI-Empfehlung "Restart the service without passing
                    // connection data" — frischer Ticket (Doku) + connectionData
                    // weg. Session behalten: ein Drop führt bei Sparkasse zu
                    // erzwungenem SCA-Push bei JEDEM Refresh (Regression
                    // 2026-05-12). Yaxi-Doku verlangt das nicht explizit.
                    //
                    // Beruht die Einordnung nur auf unserer Faustregel, geht ein
                    // unveränderter Versuch voran (siehe
                    // `erstMitConnectionDataWiederholen`).
                    let ohneCD: @Sendable (BalancesTicket) async throws -> Response<BalancesResult> = { t in
                        let credsNoCD = try buildCredentials(
                            connectionId: connectionId, model: model,
                            connectionData: nil, userId: userId, password: password
                        )
                        return try await client.balances(
                ticket: t,
                credentials: credsNoCD,
                accounts: accountRefs,
                session: storedSession.map(Session.init),
                recurringConsents: true
            )
                    }
                    ticket = try YaxiTicketMaker.balancesTicket()
                    if erstMitConnectionDataWiederholen(error) {
                        AppLogger.log("fetchBalances: unklarer Serverfehler — erst unverändert wiederholen, Zustimmung bleibt", category: "YaxiService", level: "WARN")
                        do {
                            let retryTicket = ticket
                            resp = try await client.balances(
                ticket: retryTicket,
                credentials: creds,
                accounts: accountRefs,
                session: storedSession.map(Session.init),
                recurringConsents: true
            )
                        } catch {
                            // Zweiter Anlauf gescheitert. Nur wenn er dieselbe Deutung
                            // trägt, ist die Zustimmung ein plausibler Verdächtiger —
                            // bei einem Netzwerkfehler wäre das Wegwerfen eine
                            // Freigabe für nichts.
                            guard darfOhneConnectionDataWiederholen(error: error, connectionDataAge: cdAlter) else {
                                throw error
                            }
                            // Bei einer Redirect-Bank wächst die Zustimmung nicht nach —
                            // siehe `darfZustimmungVerwerfen`. Lieber den Fehler zeigen
                            // als die Verbindung dauerhaft zerstören.
                            guard darfZustimmungVerwerfen(error: error, istRedirectBank: model.none) else {
                                AppLogger.log("fetchBalances: Redirect-Bank — Zustimmung wird NICHT verworfen, Fehler wird durchgereicht", category: "YaxiService", level: "WARN")
                                throw error
                            }
                            AppLogger.log("fetchBalances: auch mit Zustimmung gescheitert — jetzt ohne connectionData (kostet eine Freigabe): \(error)", category: "YaxiService", level: "WARN")
                            ticket = try YaxiTicketMaker.balancesTicket()
                            resp = try await ohneCD(ticket)
                        }
                    } else {
                        // **Auch hier die Redirect-Regel.** Dieser Zweig greift, wenn der
                        // Fehler KEIN unklarer Serverfehler ist — also gerade bei
                        // `unauthorized`. Er ging bisher ungeprüft auf `ohneCD`, und das
                        // heißt: Zustimmung beiseite, neue Freigabe anfordern. Genau
                        // diese Zeile stand am 23.08.2026 im Protokoll der gemeldeten
                        // bunq-Dauerschleife, unmittelbar vor „clearing ALL state".
                        //
                        // Dass es vorher nicht auffiel, lag daran, dass dieselbe Bank
                        // zuvor `UnexpectedError` lieferte und damit im oberen,
                        // geschützten Zweig landete.
                        guard darfZustimmungVerwerfen(error: error, istRedirectBank: model.none) else {
                            AppLogger.log("fetchBalances: Redirect-Bank — kein Abruf ohne Zustimmung, Fehler wird durchgereicht", category: "YaxiService", level: "WARN")
                            throw error
                        }
                        AppLogger.log("fetchBalances: consent expired, retrying without connectionData", category: "YaxiService", level: "WARN")
                        resp = try await ohneCD(ticket)
                    }
                } else if storedSession != nil {
                    // Retry without session token (e.g. Revolut/Open Banking returns
                    // UnexpectedError when a stale YAXI session token is sent).
                    // UnexpectedError ist explizit nicht in isConnectionResetError,
                    // dieser Branch greift also nicht für 1822-Unauthorized.
                    AppLogger.log("fetchBalances: error with session, retrying without: \(error)", category: "YaxiService", level: "WARN")
                    await sessionStore.clearSessionsOnly(slotId: slotSnapshot)
                    ticket = try YaxiTicketMaker.balancesTicket()
                    let retryTicket = ticket
                    resp = try await client.balances(
                ticket: retryTicket,
                credentials: creds,
                accounts: accountRefs,
                session: nil,
                recurringConsents: true
            )
                } else if isRequestError(error) {
                    // Netzwerkfehler: einmal automatisch wiederholen (YAXI-Empfehlung).
                    AppLogger.log("fetchBalances: network error, retrying once: \(error)", category: "YaxiService", level: "WARN")
                    resp = try await client.balances(
                ticket: ticket,
                credentials: creds,
                accounts: accountRefs,
                session: storedSession.map(Session.init),
                recurringConsents: true
            )
                } else {
                    throw error
                }
            }

            // SCA-Closures müssen let-bound Capture haben (Sendable).
            let scaTicket = ticket
            let confirm: @Sendable (ConfirmationContext) async throws -> SCACommon = { ctx in
                try await toSCACommon(client.confirmBalances(ticket: scaTicket, context: ctx)) { .balances($0) }
            }
            let respond: @Sendable (InputContext, String) async throws -> SCACommon = { ctx, r in
                try await toSCACommon(client.respondBalances(ticket: scaTicket, context: ctx, response: r)) { .balances($0) }
            }

            guard case .erfolg(let outcome) = await handleSCA(
                initial: toSCACommon(resp) { .balances($0) }, client: client, ticket: scaTicket, slotId: slotSnapshot,
                confirm: confirm, respond: respond
            ) else {
                return BalancesResponse(ok: false, booked: nil, expected: nil, session: nil,
                                       connectionData: nil, error: nil,
                                       userMessage: nil, scaRequired: true)
            }

            AppLogger.log("fetchBalances: outcome.connectionData=\(outcome.connectionData == nil ? "nil" : "\(outcome.connectionData!.bytes.count)b")", category: "YaxiService")
            await sessionStore.update(scope: .balances,
                                      session: outcome.session?.bytes,
                                      connectionData: outcome.connectionData?.bytes,
                                      slotId: slotSnapshot)

            guard case .balances(let result) = outcome.payload else {
                return BalancesResponse(ok: false, booked: nil, expected: nil, session: nil,
                                       connectionData: nil, error: "unexpected result type",
                                       userMessage: nil, scaRequired: nil)
            }
            let entschluesselt = try result.decodeUnverified().data

            // When called without IBAN (first setup), extract and persist IBAN from response
            if iban.isEmpty {
                if case .iban(let discovered) = entschluesselt.balances.first?.account.id {
                    AppLogger.log("fetchBalances: auto-stored IBAN prefix=\(String(discovered.prefix(8)))", category: "YaxiService")
                    storeDiscoveredIBAN(discovered)
                }
            }

            // **Die Bank kennt das angefragte Konto nicht.** Kein Fehler, kein leerer
            // Fehlertext — nur `entries=0` und das Konto in `missingAccounts`. Genau so
            // sah es bei bunq am 23.08.2026 aus: Der Abruf lief sauber durch und lieferte
            // trotzdem weder Saldo noch Umsätze, weil die erteilte Zustimmung ein anderes
            // Konto abdeckt als das, welches der Slot gespeichert hat.
            //
            // Dann ist die naheliegende Frage nicht „warum nicht dieses", sondern „welche
            // denn". Ein zweiter Aufruf ohne Kontoangabe holt alles, was die Zustimmung
            // hergibt. Er kostet keine weitere Freigabe — dieselbe Zustimmung, dieselbe
            // Sitzung — und nennt im Protokoll, was die Bank tatsächlich anbietet.
            if entschluesselt.balances.isEmpty, !entschluesselt.missingAccounts.isEmpty, !iban.isEmpty {
                AppLogger.log("fetchBalances: Bank kennt \(iban.prefix(8))… nicht — frage ohne Kontoangabe nach",
                              category: "YaxiService", level: "WARN")
                if let alle = try? await client.balances(
                    ticket: ticket,
                    credentials: creds,
                    accounts: [],
                    session: outcome.session,
                    recurringConsents: true
                ), case .result(let alleRes) = alle {
                    let angeboten = try alleRes.authenticated.decodeUnverified().data
                    let ibans = angeboten.balances.compactMap { eintrag -> String? in
                        if case .iban(let i) = eintrag.account.id { return String(i.prefix(12)) }
                        return nil
                    }
                    AppLogger.log("fetchBalances: Bank bietet \(angeboten.balances.count) Konto(en): \(ibans.joined(separator: ", "))",
                                  category: "YaxiService", level: "WARN")
                    // Die gespeicherte IBAN wird bewusst NICHT überschrieben: Welches
                    // Konto der Slot zeigen soll, hat der Nutzer bei der Einrichtung
                    // gewählt. Das hinter seinem Rücken umzustellen wäre schlimmer als
                    // ein leerer Kontostand.
                    //
                    // Bis 05.09.2026 folgte daraus der falsche Schluss, stattdessen den
                    // erstbesten fremden Saldo anzuzeigen. Der Zweitabruf bleibt — seine
                    // Liste im Protokoll ist bei der Fehlersuche Gold wert —, aber er
                    // liefert keinen Anzeigewert mehr. Der Slot meldet stattdessen, dass
                    // sein Konto nicht in der Zustimmung steckt.
                    return BalancesResponse(
                        ok: false, booked: nil, expected: nil,
                        session: outcome.session?.bytes.base64EncodedString(),
                        connectionData: outcome.connectionData?.bytes.base64EncodedString(),
                        error: nil, userMessage: nil, scaRequired: nil,
                        kontoNichtInZustimmung: true)
                }
            }
            if alwaysTrace {
                await writeTrace(client: client, label: "diag-fetchBalances-ok", ticket: ticket, error: nil)
            }
            return try makeBalancesResponse(result,
                                        session: outcome.session?.bytes,
                                        connectionData: outcome.connectionData?.bytes,
                                        requestedIban: iban)

        } catch {
            // Die Kennung EINMAL lesen, bevor irgendein Trace-Abruf stattfindet.
            // `traceId()` liefert laut SDK die Kennung „der letzten Anfrage" — und
            // `client.trace(…)` in `writeTrace` ist selbst eine Anfrage. Wer die Kennung
            // danach liest, bekommt die des Trace-Abrufs statt die des gescheiterten
            // Bankaufrufs. Genau das landete bisher im Diagnosebericht.
            let traceId = await client.traceID
            await writeTrace(client: client, label: "fetchBalances", ticket: ticket,
                             error: error, traceId: traceId)
            AppLogger.log("fetchBalances error: \(error.localizedDescription)", category: "YaxiService", level: "ERROR")
            await captureUnexpectedErrorIfNeeded(
                error: error, client: client, ticket: ticket,
                slotSnapshot: slotSnapshot, callName: "fetchBalances",
                callSource: callSource, traceId: traceId
            )
            // Die Frische-Regel galt bisher nur im inneren Retry-Zweig — hier, wo
            // tatsächlich gelöscht wird, fehlte sie. Das war die Lücke aus dem Fix vom
            // 31.07.: Der erste unbegründete Fehler ließ die Zustimmung stehen, der
            // zweite räumte sie samt Sitzungen ab.
            let alterHier = await sessionStore.connectionDataAge(slotId: slotSnapshot)
            if isConnectionResetError(error),
               darfOhneConnectionDataWiederholen(error: error, connectionDataAge: alterHier),
               darfZustimmungVerwerfen(error: error, istRedirectBank: model.none) {
                AppLogger.log("fetchBalances: clearing ALL state after auth reset", category: "YaxiService")
                await sessionStore.clearAll(slotId: slotSnapshot)
            } else if isConnectionResetError(error) {
                // Zustimmung behalten, Sitzungen weg: Sitzungen kommen von allein
                // zurück, die Zustimmung einer Redirect-Bank nicht.
                AppLogger.log("fetchBalances: Zustimmung bleibt, nur Sitzungen zurückgesetzt", category: "YaxiService")
                await sessionStore.clearSessionsOnly(slotId: slotSnapshot)
            } else if isObsoleteSessionError(error) || isHBCITransientError(error) {
                // HBCI gateway errors and obsolete sessions: keep connectionData, just reset sessions.
                // Avoids forcing full 2FA re-auth for transient HBCI infrastructure hiccups.
                AppLogger.log("fetchBalances: clearing sessions only (HBCI transient or obsolete)", category: "YaxiService")
                await sessionStore.clearSessionsOnly(slotId: slotSnapshot)
            }
            throw error
        }
    }

    static func fetchTransactions(
        userId: String,
        password: String,
        from: String,
        alwaysTrace: Bool = false,
        callSource: ErrorReportStore.CallSource = .normal
    ) async throws -> TransactionsResponse {
        // Snapshot slot ID immediately — activeSlotId may change during async fetch
        let slotSnapshot = activeSlotId
        // HBCI-Mutex via withSlot (siehe fetchBalances).
        let result: TransactionsResponse? = try await BankRequestQueue.shared.withSlot(slotSnapshot) {
            try await fetchTransactionsLocked(
                slotSnapshot: slotSnapshot,
                userId: userId,
                password: password,
                from: from,
                alwaysTrace: alwaysTrace,
                callSource: callSource
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
        alwaysTrace: Bool,
        callSource: ErrorReportStore.CallSource
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
        // Alter der Zustimmung mitschreiben: Ohne sie sagt „167b" nichts darüber,
        // ob die Daten frisch sind oder seit Tagen unverändert mitgeschickt werden.
        let cdAlter = await sessionStore.connectionDataAge(slotId: slotSnapshot)
        AppLogger.log("fetchTransactions: slot=\(slotSnapshot.prefix(8)) storedCD=\(storedCD == nil ? "nil" : "\(storedCD!.count)b") alter=\(cdAlter.map { String(format: "%.1fh", $0 / 3600) } ?? "?") model.none=\(model.none)", category: "YaxiService")
        let storedSession = await sessionStore.session(for: .transactions, slotId: slotSnapshot)
        let creds = try buildCredentials(
            connectionId: connectionId, model: model,
            connectionData: storedCD, userId: userId, password: password
        )

        AppLogger.log("fetchTransactions from=\(from)", category: "YaxiService")

        // Erst der nicht-interaktive Weg — siehe `schnellSalden` für die Begründung.
        if let cd = storedCD,
           let schnell = await schnellUmsaetze(
               slotSnapshot: slotSnapshot,
               connectionData: cd,
               ticket: try YaxiTicketMaker.issueTransactionsTicket(iban: iban, from: from)) {
            return schnell
        }

        let client = YaxiTransport.client()
        // Mutable — retry-Pfade ziehen neuen Ticket (Yaxi-Doku).
        var ticket = try YaxiTicketMaker.issueTransactionsTicket(iban: iban, from: from)

        do {
            var resp: Response<TransactionsResult>
            do {
                resp = try await client.transactions(
                ticket: ticket,
                credentials: creds,
                session: storedSession.map(Session.init),
                recurringConsents: true
            )
            } catch {
                // Rohfehler vor der Einordnung — wie bei fetchBalances, aus demselben Grund.
                AppLogger.log("fetchTransactions: Rohfehler vor Einordnung: \(String(reflecting: error))",
                              category: "YaxiService", level: "WARN")
                // Einmal ermittelt, weil die Deutung im zweistufigen Wiederanlauf
                // ein zweites Mal gebraucht wird.
                let cdAlter = await sessionStore.connectionDataAge(slotId: slotSnapshot)
                // YAXI-Doku: nach jedem non-RequestError ist der Service in
                // "failed state" → frischer Ticket nötig. Network-Errors
                // sind explizit ausgenommen.
                if shouldRetryWithoutUserId(error: error, model: model, userId: userId) {
                    let credsNoUserId = try buildCredentials(
                        connectionId: connectionId, model: model,
                        connectionData: storedCD, userId: nil, password: password
                    )
                    ticket = try YaxiTicketMaker.issueTransactionsTicket(iban: iban, from: from)
                    let retryTicket = ticket
                    resp = try await client.transactions(
                ticket: retryTicket,
                credentials: credsNoUserId,
                session: storedSession.map(Session.init),
                recurringConsents: true
            )
                } else if darfOhneConnectionDataWiederholen(
                              error: error,
                              connectionDataAge: cdAlter),
                          storedCD != nil {
                    // Consent abgelaufen — frischer Ticket + connectionData
                    // weg, Session behalten (siehe fetchBalances: Sparkasse-
                    // Regression bei Session-Drop, 2026-05-12). Beruht die
                    // Einordnung nur auf der Faustregel, geht ein unveränderter
                    // Versuch voran.
                    let ohneCD: @Sendable (TransactionsTicket) async throws -> Response<TransactionsResult> = { t in
                        let credsNoCD = try buildCredentials(
                            connectionId: connectionId, model: model,
                            connectionData: nil, userId: userId, password: password
                        )
                        return try await client.transactions(
                ticket: t,
                credentials: credsNoCD,
                session: storedSession.map(Session.init),
                recurringConsents: true
            )
                    }
                    ticket = try YaxiTicketMaker.issueTransactionsTicket(iban: iban, from: from)
                    if erstMitConnectionDataWiederholen(error) {
                        AppLogger.log("fetchTransactions: unklarer Serverfehler — erst unverändert wiederholen, Zustimmung bleibt", category: "YaxiService", level: "WARN")
                        do {
                            let retryTicket = ticket
                            resp = try await client.transactions(
                ticket: retryTicket,
                credentials: creds,
                session: storedSession.map(Session.init),
                recurringConsents: true
            )
                        } catch {
                            guard darfOhneConnectionDataWiederholen(error: error, connectionDataAge: cdAlter) else {
                                throw error
                            }
                            // Bei einer Redirect-Bank wächst die Zustimmung nicht nach —
                            // siehe `darfZustimmungVerwerfen`. Lieber den Fehler zeigen
                            // als die Verbindung dauerhaft zerstören.
                            guard darfZustimmungVerwerfen(error: error, istRedirectBank: model.none) else {
                                AppLogger.log("fetchTransactions: Redirect-Bank — Zustimmung wird NICHT verworfen, Fehler wird durchgereicht", category: "YaxiService", level: "WARN")
                                throw error
                            }
                            AppLogger.log("fetchTransactions: auch mit Zustimmung gescheitert — jetzt ohne connectionData (kostet eine Freigabe): \(error)", category: "YaxiService", level: "WARN")
                            ticket = try YaxiTicketMaker.issueTransactionsTicket(iban: iban, from: from)
                            resp = try await ohneCD(ticket)
                        }
                    } else {
                        // **Auch hier die Redirect-Regel.** Dieser Zweig greift, wenn der
                        // Fehler KEIN unklarer Serverfehler ist — also gerade bei
                        // `unauthorized`. Er ging bisher ungeprüft auf `ohneCD`, und das
                        // heißt: Zustimmung beiseite, neue Freigabe anfordern. Genau
                        // diese Zeile stand am 23.08.2026 im Protokoll der gemeldeten
                        // bunq-Dauerschleife, unmittelbar vor „clearing ALL state".
                        //
                        // Dass es vorher nicht auffiel, lag daran, dass dieselbe Bank
                        // zuvor `UnexpectedError` lieferte und damit im oberen,
                        // geschützten Zweig landete.
                        guard darfZustimmungVerwerfen(error: error, istRedirectBank: model.none) else {
                            AppLogger.log("fetchTransactions: Redirect-Bank — kein Abruf ohne Zustimmung, Fehler wird durchgereicht", category: "YaxiService", level: "WARN")
                            throw error
                        }
                        AppLogger.log("fetchTransactions: consent expired, retrying without connectionData", category: "YaxiService", level: "WARN")
                        resp = try await ohneCD(ticket)
                    }
                } else if storedSession != nil {
                    // Stale-Session-Retry für Revolut/Open-Banking-Quirks
                    // (UnexpectedError, nicht in isConnectionResetError).
                    AppLogger.log("fetchTransactions: error with session, retrying without: \(error)", category: "YaxiService", level: "WARN")
                    await sessionStore.clearSessionsOnly(slotId: slotSnapshot)
                    ticket = try YaxiTicketMaker.issueTransactionsTicket(iban: iban, from: from)
                    let retryTicket = ticket
                    resp = try await client.transactions(
                ticket: retryTicket,
                credentials: creds,
                session: nil,
                recurringConsents: true
            )
                } else if isRequestError(error) {
                    // Netzwerkfehler: einmal automatisch wiederholen (YAXI-Empfehlung).
                    AppLogger.log("fetchTransactions: network error, retrying once: \(error)", category: "YaxiService", level: "WARN")
                    resp = try await client.transactions(
                ticket: ticket,
                credentials: creds,
                session: storedSession.map(Session.init),
                recurringConsents: true
            )
                } else {
                    throw error
                }
            }

            // SCA-Closures müssen let-bound Capture haben (Sendable).
            let scaTicket = ticket
            let confirm: @Sendable (ConfirmationContext) async throws -> SCACommon = { ctx in
                try await toSCACommon(client.confirmTransactions(ticket: scaTicket, context: ctx)) { .transactions($0) }
            }
            let respond: @Sendable (InputContext, String) async throws -> SCACommon = { ctx, r in
                try await toSCACommon(client.respondTransactions(ticket: scaTicket, context: ctx, response: r)) { .transactions($0) }
            }

            guard case .erfolg(let outcome) = await handleSCA(
                initial: toSCACommon(resp) { .transactions($0) }, client: client, ticket: scaTicket, slotId: slotSnapshot,
                confirm: confirm, respond: respond
            ) else {
                return TransactionsResponse(ok: false, transactions: nil, session: nil,
                                           connectionData: nil, error: nil,
                                           userMessage: nil, scaRequired: true)
            }

            // Gegenstück zur Zeile in fetchBalances. Beim Umsatzabruf war bislang nicht
            // zu sehen, ob eine Zustimmung zurückkam — genau die Information, die bei
            // der bunq-Analyse gefehlt hat.
            AppLogger.log("fetchTransactions: outcome.connectionData=\(outcome.connectionData == nil ? "nil" : "\(outcome.connectionData!.bytes.count)b")", category: "YaxiService")
            await sessionStore.update(scope: .transactions,
                                      session: outcome.session?.bytes,
                                      connectionData: outcome.connectionData?.bytes,
                                      slotId: slotSnapshot)

            guard case .transactions(let result) = outcome.payload else {
                return TransactionsResponse(ok: false, transactions: nil, session: nil,
                                           connectionData: nil, error: "unexpected result type",
                                           userMessage: nil, scaRequired: nil)
            }
            if alwaysTrace {
                await writeTrace(client: client, label: "diag-fetchTransactions-ok", ticket: ticket, error: nil)
            }
            return try makeTransactionsResponse(result, session: outcome.session?.bytes, connectionData: outcome.connectionData?.bytes)

        } catch {
            // Die Kennung EINMAL lesen, bevor irgendein Trace-Abruf stattfindet.
            // `traceId()` liefert laut SDK die Kennung „der letzten Anfrage" — und
            // `client.trace(…)` in `writeTrace` ist selbst eine Anfrage. Wer die Kennung
            // danach liest, bekommt die des Trace-Abrufs statt die des gescheiterten
            // Bankaufrufs. Genau das landete bisher im Diagnosebericht.
            let traceId = await client.traceID
            await writeTrace(client: client, label: "fetchTransactions", ticket: ticket,
                             error: error, traceId: traceId)
            AppLogger.log("fetchTransactions error: \(error.localizedDescription)", category: "YaxiService", level: "ERROR")
            await captureUnexpectedErrorIfNeeded(
                error: error, client: client, ticket: ticket,
                slotSnapshot: slotSnapshot, callName: "fetchTransactions",
                callSource: callSource, traceId: traceId
            )
            // Die Frische-Regel galt bisher nur im inneren Retry-Zweig — hier, wo
            // tatsächlich gelöscht wird, fehlte sie. Das war die Lücke aus dem Fix vom
            // 31.07.: Der erste unbegründete Fehler ließ die Zustimmung stehen, der
            // zweite räumte sie samt Sitzungen ab.
            let alterHier = await sessionStore.connectionDataAge(slotId: slotSnapshot)
            if isConnectionResetError(error),
               darfOhneConnectionDataWiederholen(error: error, connectionDataAge: alterHier),
               darfZustimmungVerwerfen(error: error, istRedirectBank: model.none) {
                AppLogger.log("fetchTransactions: clearing ALL state after auth reset", category: "YaxiService")
                await sessionStore.clearAll(slotId: slotSnapshot)
            } else if isConnectionResetError(error) {
                // Zustimmung behalten, Sitzungen weg: Sitzungen kommen von allein
                // zurück, die Zustimmung einer Redirect-Bank nicht.
                AppLogger.log("fetchTransactions: Zustimmung bleibt, nur Sitzungen zurückgesetzt", category: "YaxiService")
                await sessionStore.clearSessionsOnly(slotId: slotSnapshot)
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

        let client = YaxiTransport.client()

        func searchWith(term: String, ibanDetection: Bool) async -> DiscoveredBank? {
            guard let ticket = try? YaxiTicketMaker.accountsTicket() else { return nil }
            guard let results = try? await client.search(
                ticket: ticket,
                filters: [.term(term)],
                ibanDetection: ibanDetection,
                limit: 3
            ), let pick = results.first else { return nil }
            return DiscoveredBank(
                id: pick.id.description,
                displayName: pick.displayName,
                logoId: pick.logoID,
                credentials: DiscoveredBankCredentials(
                    full: pick.credentials.full,
                    userId: pick.credentials.userID,
                    none: pick.credentials.none
                ),
                userIdLabel: pick.userIDLabel?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
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
            return CredentialsModel(full: true, userID: true, none: false)
        }
        return CredentialsModel(
            full: d.bool(forKey: fullKey),
            userID: d.bool(forKey: credModelUserIdKey(for: slotId)),
            none: d.bool(forKey: credModelNoneKey(for: slotId))
        )
    }

    /// Returns the stored credentials model as DiscoveredBankCredentials (for accounts() flow).
    static func loadStoredCredentials(slotId: String) -> DiscoveredBankCredentials {
        let m = loadCredentialsModel(slotId: slotId)
        return DiscoveredBankCredentials(full: m.full, userId: m.userID, none: m.none)
    }

    /// - Note: `ConnectionID` ist seit SDK 0.5 ein Werttyp statt eines Strings, und sein
    ///   Initialisierer wirft. Die gespeicherte Kennung stammt aus einer früheren
    ///   Antwort der Bank; ist sie unlesbar, ist die Verbindung ohnehin kaputt — der
    ///   Fehler wird deshalb durchgereicht und nicht als leere Antwort verkleidet.
    private static func buildCredentials(
        connectionId: String,
        model: CredentialsModel,
        connectionData: Data?,
        userId: String?,
        password: String?
    ) throws -> Credentials {
        let u = userId?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        let p = password?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty

        var creds = Credentials(connectionID: try ConnectionID(connectionId),
                                connectionData: connectionData.map(ConnectionData.init))

        // Priority: full > userId > none  (mirrors MoneyMoney Lua)
        // `none` only means redirect when neither `full` nor `userId` is available.
        if model.full {
            creds.userID = u
            creds.password = p
        } else if model.userID {
            creds.userID = u
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
    /// Wie lange eine gerade erst ausgestellte Zustimmung als „frisch" gilt.
    /// Großzügig bemessen: Zwischen Kontenabruf und Saldenabruf liegt die Kontoauswahl
    /// des Nutzers, und die darf dauern.
    static let frischeZustimmungSekunden: TimeInterval = 300

    /// Entscheidet, ob der „Zustimmung abgelaufen"-Zweig genommen werden darf.
    ///
    /// `isConnectionResetError` deutet `UnexpectedError(userMessage: nil)` als veraltete
    /// connectionData — eine Faustregel, die für Sparkassen eingeführt wurde. Bei der
    /// HypoVereinsbank liegt sie nachweislich falsch: Dort scheitert der Saldenabruf mit
    /// genau diesem Fehler, obwohl die Zustimmung Sekunden zuvor aus der ersten TAN
    /// entstanden ist. Wir warfen sie daraufhin weg und forderten eine zweite TAN an —
    /// die mit demselben Fehler scheiterte. Gemessen am 29.07. bei zwei Kunden, je
    /// zweimal.
    ///
    /// Eine Zustimmung, die eben erst ausgestellt wurde, kann nicht abgelaufen sein.
    /// Der eindeutige `Unauthorized`/`ConsentExpired` bleibt unberührt — nur die
    /// Faustregel wird ausgesetzt.
    /// Ob vor dem Wegwerfen der Zustimmung ein Versuch **mit** ihr gemacht werden muss.
    ///
    /// `UnexpectedError` ohne Meldung ist keine Aussage der Bank, sondern unsere
    /// Vermutung — YAXI liefert ihn auch für serverseitige Fehler, die mit der
    /// Zustimmung nichts zu tun haben (HypoVereinsbank, 31.07.: „Der Fehler geht primär
    /// auf uns"). Ihn sofort als veraltete connectionData zu deuten, kostet den Nutzer
    /// eine Freigabe für eine Vermutung.
    ///
    /// Deshalb zwei Stufen: erst unverändert wiederholen — das kostet nichts und deckt
    /// den vorübergehenden Serverfehler ab. Erst wenn auch das scheitert, ist die
    /// Zustimmung ein plausibler Verdächtiger und darf weggeworfen werden. Für den
    /// Sparkassen-Fall, für den die Faustregel eingeführt wurde, bleibt der Weg damit
    /// offen; er dauert nur einen Aufruf länger.
    ///
    /// Sagt die Bank ausdrücklich `unauthorized`, entfällt die Zwischenstufe — dann ist
    /// nichts zu vermuten.
    ///
    /// - Note: Der Typ heißt seit SDK 0.5 `RoutexError`; `RoutexClientError` steht dort
    ///   nur noch für Fehler im Client selbst. Die alte Abfrage hätte weiter übersetzt,
    ///   aber nie wieder zugetroffen — und damit still die Zwei-Stufen-Regel abgeschaltet.
    static func erstMitConnectionDataWiederholen(_ error: Error) -> Bool {
        guard let re = error as? RoutexError, case .unexpectedError = re else { return false }
        return true
    }

    /// Darf die Zustimmung dieses Kontos überhaupt verworfen werden?
    ///
    /// **Bei einer Redirect-Bank ist Verwerfen eine Einbahnstraße.** Zugangsdaten-Banken
    /// liefern mit der nächsten normalen Antwort eine frische Zustimmung nach; darauf
    /// beruht die ganze „wegwerfen und neu holen"-Strategie. Redirect-Banken tun das
    /// nicht: Im Protokoll des gemeldeten bunq-Falls stehen 33 von 33 SCA-Ergebnissen
    /// mit `connectionData=nil`. Neue Zustimmung entsteht dort nur beim `fetchAccounts`
    /// der Ersteinrichtung — einmal weggeworfen, verlangt jeder Abruf für immer einen
    /// neuen QR-Scan. Genau das war der Fehler.
    ///
    /// **Bei einer Redirect-Bank wird nie automatisch verworfen — auch nicht bei
    /// `unauthorized`.**
    ///
    /// Bis zum 23.08.2026 war hier eine Ausnahme: Sagt die Bank ausdrücklich
    /// `unauthorized`, sei die Zustimmung ohnehin hin, also könne man sie wegwerfen und
    /// neu holen. Das Feld hat diese Annahme widerlegt. Gemeldet wurde eine Dauerschleife
    /// bei bunq: zweimal QR bestätigt, danach beim nächsten Umsatzabruf wieder von vorn.
    /// Verwerfen war also nicht die Heilung, sondern die Schleife.
    ///
    /// Der Denkfehler steckte im „ohnehin hin". Eine Zustimmung, die die Bank in einem
    /// Aufruf als ungültig meldet, kann im nächsten wieder tragen — sei es, weil die
    /// Sitzung das Problem war und nicht die Zustimmung, sei es, weil ein
    /// vorangegangener Aufruf sie verbrannt hat. Wegwerfen kostet dagegen sicher einen
    /// Scan, und bei Redirect-Banken wächst nichts nach: Neue Zustimmung entsteht dort
    /// ausschließlich bei der Einrichtung.
    ///
    /// Der Preis dieser Entscheidung ist ehrlich zu nennen: Ist die Zustimmung
    /// tatsächlich abgelaufen — nach PSD2 spätestens nach 90 Tagen —, kommt der Abruf
    /// nicht mehr von selbst in Gang, und der Nutzer muss die Bank neu einrichten. Ein
    /// wiederkehrender Fehler mit klarer Ansage ist aber besser als ein QR-Scan, der
    /// nichts ändert und beim nächsten Abruf erneut verlangt wird.
    static func darfZustimmungVerwerfen(error: Error, istRedirectBank: Bool) -> Bool {
        !istRedirectBank
    }

    /// - Parameter istZahlung: Bei Zahlungen gelten andere Regeln als beim Lesen.
    ///
    ///   Ein `UnexpectedError` ohne Nutzertext wird sonst als veraltete Zustimmung
    ///   gelesen und der Aufruf wiederholt. Beim Abruf von Salden kostet das nichts.
    ///   Bei einer Überweisung schickt es womöglich **eine zweite Zahlung** — YAXI sagt
    ///   ausdrücklich, dass ein `UnexpectedError` kein Beleg dafür ist, dass die
    ///   Operation nicht ausgeführt wurde. Genau diese Vermutung stand hier.
    ///
    ///   Eine ausdrückliche Aussage der Bank (`unauthorized`) bleibt auch für Zahlungen
    ///   ein gültiger Grund: Dort steht fest, dass nichts angenommen wurde.
    static func darfOhneConnectionDataWiederholen(error: Error,
                                                  connectionDataAge: TimeInterval?,
                                                  istZahlung: Bool = false) -> Bool {
        guard isConnectionResetError(error) else { return false }
        guard let re = error as? RoutexError, case .unexpectedError = re else {
            return true   // ausdrückliche Aussage der Bank — immer folgen
        }
        // Ab hier: unklarer Fehler. Beim Lesen wiederholen, beim Zahlen niemals.
        if istZahlung { return false }
        guard let alter = connectionDataAge else { return true }  // Alter unbekannt
        return alter >= frischeZustimmungSekunden
    }

    static func isConnectionResetError(_ error: Error) -> Bool {
        guard let re = error as? RoutexError else { return false }
        switch re {
        case .unauthorized:
            return true
        case .unexpectedError(let userMessage):
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

    /// Transportfehler. Hieß bis SDK 0.4.1 `RoutexClientError.RequestError`; seit 0.5
    /// ist es ein eigener Typ aus `RoutexTransport`.
    private static func isRequestError(_ error: Error) -> Bool {
        error is HTTPError
    }

    private static func shouldRetryWithoutUserId(error: Error, model: CredentialsModel, userId: String?) -> Bool {
        guard model.full, !model.userID, userId?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty != nil else {
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
        let creds = try buildCredentials(
            connectionId: connectionId, model: model,
            connectionData: storedCD, userId: userId, password: password
        )

        let client = YaxiTransport.client()
        // Mutable, damit retry-Pfade einen frischen Ticket ziehen können
        // (Yaxi-Doku: nach non-RequestError neuer Ticket nötig). Der finale
        // Wert nach dem inner-catch wird in `scaTicket` eingefroren und an die
        // confirm/respond-Closures übergeben.
        var ticket = try await YaxiTicketMaker.issueTransferTicket()

        // **Quellkonto ausdrücklich benennen.** Ohne `debtorAccount` fragt die Bank
        // laut SDK-Doku selbst nach („the bank prompts the user when omitted") — und
        // diese Rückfrage kommt als `.selection`, die `handleSCA` mit einer Heuristik
        // für TAN-*Verfahren* beantwortet. Bei einem Zugang mit mehreren
        // überweisungsfähigen Konten konnte so Geld von einem anderen Konto abgehen,
        // als im Formular stand. Die IBAN ist dieselbe, gegen die `TransferSheet` den
        // Slot bereits absichert.
        //
        // Währung fest EUR wie der Betrag darunter: Die App überweist ausschließlich
        // SEPA in Euro. Ist keine IBAN hinterlegt, bleibt es bei `nil` und damit beim
        // bisherigen Verhalten — mehr wäre geraten.
        let quellIban = Quellkonto.iban(
            ausGespeicherter: UserDefaults.standard.string(forKey: ibanKey(for: slotSnapshot)))
        let quellkonto: DebtorAccountReference? = quellIban.map {
            DebtorAccountReference(id: .iban($0), currency: Quellkonto.waehrung)
        }
        if quellkonto == nil {
            AppLogger.log("sendTransfer: keine IBAN am Slot \(slotSnapshot.prefix(8)) — Quellkonto bleibt offen",
                          category: "YaxiService", level: "WARN")
        }

        let amountString = NSDecimalNumber(decimal: request.amountEUR).stringValue
        let amount = RoutexModels.Amount(amount: Decimal(string: amountString) ?? request.amountEUR, currency: "EUR")
        let details = [
            RoutexModels.TransferDetails(
                endToEndIdentification: request.endToEndId,
                amount: amount,
                creditorAccount: .iban(request.creditorIban),
                creditorAgentBIC: nil,
                creditorName: request.creditorName,
                creditorAddress: nil,
                remittance: request.remittance,
                chargeBearer: nil
            )
        ]

        AppLogger.log("sendTransfer: slot=\(slotSnapshot.prefix(8)) connId=\(connectionId.prefix(8)) → \(request.creditorIban.prefix(8))… amount=\(amountString)€", category: "YaxiService")

        // SDK 0.5 unterscheidet Zeitpunkt und Kalendertag. Ein Ausführungstermin ist ein
        // Tag ohne Uhrzeit — als `Date` übergeben hätte ihn eine Zeitzone verschieben
        // können. `ISODate` validiert die Zeichenkette und wirft bei Unsinn.
        let ausfuehrungstag: ISODateTimeOrDate? = try requestedExecutionDate.map {
            .date(try ISODate(TransferScheduleHelpers.formatDateISO($0)))
        }

        do {
            var resp: Response<TransferResult>
            do {
                resp = try await client.transfer(
                ticket: ticket,
                credentials: creds,
                product: .sepaCreditTransfer,
                details: details,
                debtorAccount: quellkonto,
                debtorName: nil,
                requestedExecutionDate: ausfuehrungstag,
                session: storedSession.map(Session.init),
                recurringConsents: true
            )
            } catch {
                // YAXI-Doku: nach non-RequestError frischer Ticket nötig.
                if shouldRetryWithoutUserId(error: error, model: model, userId: userId) {
                    let credsNoUserId = try buildCredentials(
                        connectionId: connectionId, model: model,
                        connectionData: storedCD, userId: nil, password: password
                    )
                    ticket = try await YaxiTicketMaker.issueTransferTicket()
                    resp = try await client.transfer(
                ticket: ticket,
                credentials: credsNoUserId,
                product: .sepaCreditTransfer,
                details: details,
                debtorAccount: quellkonto,
                debtorName: nil,
                requestedExecutionDate: ausfuehrungstag,
                session: storedSession.map(Session.init),
                recurringConsents: true
            )
                } else if darfOhneConnectionDataWiederholen(
                              error: error,
                              connectionDataAge: await sessionStore.connectionDataAge(slotId: slotSnapshot),
                              istZahlung: true),
                          storedCD != nil {
                    // Yaxi-Empfehlung „Restart the service without passing
                    // connection data" — frischer Ticket + connectionData weg,
                    // Session behalten (Sparkasse-Regression bei Drop, 2026-05-12).
                    AppLogger.log("sendTransfer: consent expired, retrying without connectionData", category: "YaxiService", level: "WARN")
                    let credsNoCD = try buildCredentials(
                        connectionId: connectionId, model: model,
                        connectionData: nil, userId: userId, password: password
                    )
                    ticket = try await YaxiTicketMaker.issueTransferTicket()
                    resp = try await client.transfer(
                ticket: ticket,
                credentials: credsNoCD,
                product: .sepaCreditTransfer,
                details: details,
                debtorAccount: quellkonto,
                debtorName: nil,
                requestedExecutionDate: ausfuehrungstag,
                session: storedSession.map(Session.init),
                recurringConsents: true
            )
                } else {
                    throw error
                }
            }

            // Einfrieren des aktuellen (ggf. nach retry getauschten) Tickets,
            // damit die @Sendable-Closures eine let-bound Capture haben.
            let scaTicket = ticket
            let confirm: @Sendable (ConfirmationContext) async throws -> SCACommon = { ctx in
                try await toSCACommon(client.confirmTransfer(ticket: scaTicket, context: ctx)) { .transfer($0) }
            }
            let respond: @Sendable (InputContext, String) async throws -> SCACommon = { ctx, r in
                try await toSCACommon(client.respondTransfer(ticket: scaTicket, context: ctx, response: r)) { .transfer($0) }
            }

            let freigabe = await handleSCA(
                initial: toSCACommon(resp) { .transfer($0) }, client: client, ticket: scaTicket, slotId: slotSnapshot,
                confirm: confirm, respond: respond
            )
            let outcome: SCAOutcome
            switch freigabe {
            case .erfolg(let o):
                outcome = o
            case .abgebrochen:
                return TransferOutcome(ok: false, scaRequired: true, error: nil,
                                       userMessage: nil, mayHaveBeenExecuted: false)
            case .unklar:
                // Hier stand bisher ebenfalls `mayHaveBeenExecuted: false` — eine
                // Gewissheit, die die App nicht hat. Es ging bereits etwas an die Bank;
                // ob die Zahlung ausgeführt wurde, weiß nur der Kontoauszug.
                AppLogger.log("sendTransfer: Ausgang unklar — kein Fehlschlag behaupten, slot=\(slotSnapshot.prefix(8))",
                              category: "YaxiService", level: "WARN")
                return TransferOutcome(
                    ok: false, scaRequired: false, error: nil,
                    userMessage: L10n.t(
                        "Status unklar: Die Bank hat die Freigabe entgegengenommen, aber kein Ergebnis geliefert. Bitte prüfe deine Umsätze, bevor du erneut überweist.",
                        "Status unclear: the bank accepted the approval but returned no result. Check your transactions before sending again."),
                    mayHaveBeenExecuted: true)
            }

            // Connection-Data refreshen (Session ist out-of-band sowieso obsolete
            // nach dem Call, aber connectionData kann erneuert worden sein).
            // Transfer hat eigenen Scope, damit der Session-Token nicht in
            // Folge-Balance/Transactions-Calls leakt.
            await sessionStore.update(scope: .transfer,
                                      session: outcome.session?.bytes,
                                      connectionData: outcome.connectionData?.bytes,
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

    // MARK: - Nicht-interaktiver Abruf (RoutexRefresh)

    /// Ist der Schnellabruf eingeschaltet? **Standard: nein.**
    ///
    /// War einen Tag lang an und ist es nicht mehr. Gemeldet am 23.08.2026: bunq in
    /// Dauerschleife, zwei bestätigte QR-Scans, danach wieder von vorn. Im Protokoll
    /// steht die Ursachenkette:
    ///
    ///     Schnellabruf nicht möglich (unauthorized) — interaktiv weiter
    ///     Rohfehler vor Einordnung: unauthorized
    ///     consent expired, retrying without connectionData
    ///     clearing ALL state after auth reset      ← Zustimmung weg
    ///
    /// `unauthorized` als Rohfehler gab es in der gesamten Protokollhistorie **nur an
    /// diesem Tag** — davor meldete dieselbe Bank `UnexpectedError`. Der zeitliche
    /// Zusammenhang mit dem neuen Weg ist zu deutlich, um ihn eingeschaltet zu lassen,
    /// solange nicht geklärt ist, ob der Schnellabruf die Sitzung verbrennt, auf der der
    /// interaktive Aufruf unmittelbar danach aufsetzt.
    ///
    /// Einschalten zum Erproben:
    /// `defaults write tech.yaxi.simplebanking yaxiNonInteractiveRefreshEnabled -bool YES`
    static var schnellabrufAktiv: Bool {
        UserDefaults.standard.object(forKey: "yaxiNonInteractiveRefreshEnabled") as? Bool ?? false
    }

    /// Saldenabruf ohne jede Freigabe-Maschinerie.
    ///
    /// **Warum das ein eigener Weg ist.** Der interaktive Dienst kann jederzeit mit einem
    /// Dialog, einer Weiterleitung oder einem Freigabe-Handle antworten; die halbe
    /// SCA-Schleife existiert nur, um das aufzufangen. Für eine Verbindung, die den
    /// interaktiven Teil längst hinter sich hat, ist das der falsche Dienst — YAXI hat
    /// dafür seit SDK 0.5 `RoutexRefresh`. Dort gibt es diese Zweige gar nicht: entweder
    /// kommen Daten, oder es kommt ein Fehler.
    ///
    /// Für Redirect-Banken ist das der eigentliche Gewinn. bunq, N26 und Revolut liefern
    /// nie eine frische Zustimmung nach; alles, was sie brauchen, ist die gespeicherte.
    /// Genau die reicht dieser Weg durch.
    ///
    /// - Returns: `nil`, wenn der Weg nicht gangbar ist — dann übernimmt der interaktive.
    ///   Ein `nil` ist ausdrücklich kein Fehler, sondern die Aufforderung weiterzumachen.
    /// - Parameter session: **wird nicht mehr durchgereicht.** Der Schnellabruf lief
    ///   zuvor auf derselben Sitzung, auf der unmittelbar danach der interaktive Aufruf
    ///   aufsetzt. Scheitert der erste und macht die Bank die Sitzung dabei ungültig,
    ///   erbt der zweite ein `unauthorized` — und das deutete simplebanking als
    ///   abgelaufene Zustimmung und warf sie weg. Ein neuer Weg darf dem alten nichts
    ///   unter den Füßen wegziehen; er beginnt jetzt mit leerer Sitzung.
    private static func schnellSalden(slotSnapshot: String,
                                      connectionData: Data,
                                      accountRefs: [AccountReference],
                                      iban: String) async -> BalancesResponse? {
        guard schnellabrufAktiv else { return nil }
        do {
            let ticket = try YaxiTicketMaker.balancesTicket()
            let antwort = try await YaxiTransport.refreshClient().balances(
                ticket: ticket,
                connectionData: ConnectionData(connectionData),
                accounts: accountRefs
            )
            AppLogger.log("fetchBalances: Schnellabruf ok slot=\(slotSnapshot.prefix(8))",
                          category: "YaxiService")
            // Erste Einrichtung ohne gespeicherte IBAN: aus der Antwort übernehmen —
            // dieselbe Regel wie im interaktiven Weg.
            if iban.isEmpty, case .iban(let gefunden)? = antwort.result.balances.first?.account.id {
                AppLogger.log("fetchBalances: auto-stored IBAN prefix=\(String(gefunden.prefix(8)))",
                              category: "YaxiService")
                storeDiscoveredIBAN(gefunden)
            }
            await sessionStore.update(scope: .balances,
                                      session: antwort.session?.bytes,
                                      connectionData: antwort.connectionData?.bytes,
                                      slotId: slotSnapshot)
            return try makeBalancesResponse(antwort.result,
                                            session: antwort.session?.bytes,
                                            connectionData: antwort.connectionData?.bytes,
                                            requestedIban: iban)
        } catch {
            // Bewusst still herabgestuft: Der interaktive Weg läuft gleich und meldet
            // den Fehler dann selbst — mit Trace und Fehlerbericht. Ihn hier schon als
            // Fehler zu behandeln, hieße einen zu zählen, der noch gar nicht feststeht.
            AppLogger.log("fetchBalances: Schnellabruf nicht möglich (\(error)) — interaktiv weiter",
                          category: "YaxiService", level: "WARN")
            return nil
        }
    }

    /// Gegenstück für die Umsätze. Konto und Zeitraum stecken im Ticket.
    /// Gegenstück für die Umsätze. Konto und Zeitraum stecken im Ticket. Auch hier ohne
    /// Sitzung — siehe `schnellSalden`.
    private static func schnellUmsaetze(slotSnapshot: String,
                                        connectionData: Data,
                                        ticket: TransactionsTicket) async -> TransactionsResponse? {
        guard schnellabrufAktiv else { return nil }
        do {
            let antwort = try await YaxiTransport.refreshClient().transactions(
                ticket: ticket,
                connectionData: ConnectionData(connectionData)
            )
            AppLogger.log("fetchTransactions: Schnellabruf ok slot=\(slotSnapshot.prefix(8)) n=\(antwort.result?.count ?? 0)",
                          category: "YaxiService")
            await sessionStore.update(scope: .transactions,
                                      session: antwort.session?.bytes,
                                      connectionData: antwort.connectionData?.bytes,
                                      slotId: slotSnapshot)
            return makeTransactionsResponse(antwort.result,
                                            session: antwort.session?.bytes,
                                            connectionData: antwort.connectionData?.bytes)
        } catch {
            AppLogger.log("fetchTransactions: Schnellabruf nicht möglich (\(error)) — interaktiv weiter",
                          category: "YaxiService", level: "WARN")
            return nil
        }
    }

    // MARK: - Response mapping

    private static func makeBalancesResponse(
        _ result: Authenticated<BalancesResult>,
        session: Data?,
        connectionData: Data?,
        requestedIban: String = ""
    ) throws -> BalancesResponse {
        try makeBalancesResponse(try result.decodeUnverified().data,
                                 session: session, connectionData: connectionData,
                                 requestedIban: requestedIban)
    }

    /// Dieselbe Übersetzung für die reine Nutzlast — der nicht-interaktive Weg liefert
    /// sie ohne JWT-Umschlag, der interaktive packt sie vorher aus. Beide sollen zu
    /// demselben Ergebnis kommen; zwei Kopien dieser IBAN-Auswahl wären eine Einladung,
    /// dass sie auseinanderlaufen.
    private static func makeBalancesResponse(
        _ nutzlast: Balances,
        session: Data?,
        connectionData: Data?,
        requestedIban: String = ""
    ) throws -> BalancesResponse {
        // YAXI liefert für Banken wie 1822direkt mehrere Account-Einträge zurück
        // (Girokonto + Tagesgeld + Visa-Karten-Subkonto). `first` ist russisches
        // Roulette — kann ein Subaccount ohne Booked-Balance treffen.
        // Per IBAN matchen, Fallback auf first wie bisher.
        let allEntries = nutzlast.balances
        // Was die Bank tatsächlich geschickt hat. Ohne diese Zeile war ein leerer
        // Saldenabruf von einem erfolgreichen nicht zu unterscheiden: kein Fehler, keine
        // Warnung, nur kein Kontostand. `missingAccounts` ist dabei die eigentliche
        // Auskunft — sie nennt die angefragten Konten, die die Bank nicht liefern wollte
        // oder konnte. Aufgefallen bei bunq am 23.08.2026.
        AppLogger.log("makeBalancesResponse: entries=\(allEntries.count) missing=\(nutzlast.missingAccounts.count) requested=\(requestedIban.isEmpty ? "(alle)" : String(requestedIban.prefix(8)))",
                      category: "YaxiService",
                      level: allEntries.isEmpty ? "WARN" : "INFO")
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
            // Hier stand „using first as fallback". Das lieferte den Saldo eines
            // fremden Kontos unter dem Namen des eigenen. Wurde eine bestimmte IBAN
            // angefragt und ist sie nicht dabei, gibt es keinen Saldo — nur den Hinweis.
            AppLogger.log("makeBalancesResponse: angefragte IBAN \(target.prefix(8))… nicht in der Antwort (\(allEntries.count) andere) — kein Saldo",
                          category: "YaxiService", level: "WARN")
            return BalancesResponse(
                ok: false, booked: nil, expected: nil,
                session: session?.base64EncodedString(),
                connectionData: connectionData?.base64EncodedString(),
                error: nil, userMessage: nil, scaRequired: nil,
                kontoNichtInZustimmung: true)
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
        _ result: Authenticated<TransactionsResult>,
        session: Data?,
        connectionData: Data?
    ) throws -> TransactionsResponse {
        makeTransactionsResponse(try result.decodeUnverified().data,
                                 session: session, connectionData: connectionData)
    }

    /// Gegenstück zu `makeBalancesResponse` für die reine Nutzlast.
    private static func makeTransactionsResponse(
        _ nutzlast: [RoutexModels.Transaction]?,
        session: Data?,
        connectionData: Data?
    ) -> TransactionsResponse {
        let transactions = nutzlast ?? []

        let mapped = transactions.map { tx -> TransactionsResponse.Transaction in
            let amountVal = (tx.amount.amount as NSDecimalNumber).doubleValue
            // Keep German comma format for stableIdentifier compatibility with existing DB entries
            let amountStr = String(format: "%.2f", amountVal).replacingOccurrences(of: ".", with: ",")

            return TransactionsResponse.Transaction(
                // `ISODate` ist seit SDK 0.5 ein Kalendertag ohne Uhrzeit und trägt die
                // Zeichenkette von der Leitung unverändert in `rawValue`. Genau die
                // wollen wir: Ein Umweg über `Date` würde in einer anderen Zeitzone
                // gelegentlich auf den Vortag rutschen.
                bookingDate: tx.bookingDate?.rawValue,
                valueDate:   tx.valueDate?.rawValue,
                status:      statusString(tx.status),
                endToEndId:  tx.endToEndID,
                amount: TransactionsResponse.Amount(currency: tx.amount.currency, amount: amountStr),
                creditor: tx.creditor.map {
                    TransactionsResponse.Party(name: truncateName($0.name), fullName: $0.name,
                                               iban: $0.iban, bic: $0.bic)
                },
                debtor: tx.debtor.map {
                    TransactionsResponse.Party(name: truncateName($0.name), fullName: $0.name,
                                               iban: $0.iban, bic: $0.bic)
                },
                remittanceInformation: tx.remittanceInformation.isEmpty ? nil : tx.remittanceInformation,
                additionalInformation: tx.additionalInformation,
                purposeCode: tx.purposeCode,
                bankTransactionCode: compactBankTransactionCode(tx.bankTransactionCodes)
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

    /// Kürzt auf die ersten zwei Wörter.
    ///
    /// Das ist der **Gruppierungsschlüssel**, nicht die Anzeige: Fixkosten, Abo-Erkennung,
    /// Zuordnungsregeln und die Ausschlüsse des Nutzers hängen daran, und ein geänderter
    /// Schlüssel lässt bestehende Gruppen zerfallen. Der ungekürzte Name wandert seit dem
    /// 29.08.2026 als `fullName` daneben mit — vorher ging er verloren, und in der Liste
    /// stand „Dornseifers Frischeb" statt „Dornseifers Frischeb. Siegen".
    static func truncateName(_ name: String?) -> String? {
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

    /// Verdichtet `bankTransactionCodes` zu EINEM Text, der in eine Spalte passt.
    ///
    /// Die API liefert je Buchung mehrere Codes in verschiedenen Systemen (ISO 20022,
    /// deutscher GVC, SWIFT, BAI). Statt sie zu interpretieren und dabei Information
    /// zu verlieren, werden sie normiert aneinandergereiht — `BookingType` liest
    /// daraus, was es braucht, und spätere Auswertungen (Lastschrift, Kartenzahlung)
    /// finden die Rohdaten noch vor. Bisher wurde das Feld komplett verworfen und war
    /// nach dem Abruf unwiederbringlich weg — auch aus `raw_json`, denn das ist die
    /// Serialisierung des App-eigenen Structs, nicht der Bankantwort.
    ///
    /// Format: `ISO:PMNT/ICDT/STDO`, `GVC:52`, `SWIFT:…`, `BAI:…`, `OTHER:…`,
    /// mehrere getrennt durch `;`.
    static func compactBankTransactionCode(_ codes: [BankTransactionCode]) -> String? {
        let parts: [String] = codes.map { code in
            switch code {
            case let .iso(domain, family, subFamily):
                return "ISO:\(domain)/\(family)/\(subFamily)"
            case let .national(code, country):
                // Deutschland: GVC (Geschäftsvorfallcode). Andere Länder mit
                // Länderkennung, damit die Codes unterscheidbar bleiben.
                let land = country.rawValue.uppercased()
                return land == "DE" ? "GVC:\(code)" : "NAT-\(land):\(code)"
            case let .swift(code):
                return "SWIFT:\(code)"
            case let .bai(code):
                return "BAI:\(code)"
            case let .other(code, issuer):
                return issuer.map { "OTHER-\($0):\(code)" } ?? "OTHER:\(code)"
            }
        }
        return parts.isEmpty ? nil : parts.joined(separator: ";")
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
        case balances(Authenticated<BalancesResult>)
        case transactions(Authenticated<TransactionsResult>)
        case accounts(Authenticated<AccountsResult>)
        case transfer(Authenticated<TransferResult>)
    }

    private struct SCAOutcome {
        let payload: SCAPayload
        let session: Session?
        let connectionData: ConnectionData?
    }

    /// Ausgang eines Freigabe-Ablaufs.
    ///
    /// Bis 05.09.2026 war das ein `SCAOutcome?`, und jedes `nil` bedeutete für den
    /// Aufrufer dasselbe: fehlgeschlagen. Bei einer **Zahlung** ist das eine Behauptung,
    /// die die App nicht belegen kann — YAXI sagt ausdrücklich, dass ein
    /// `UnexpectedError` kein Beleg dafür ist, dass die Operation nicht ausgeführt
    /// wurde. Wer nach einer abgeschickten Bestätigung einen Fehler bekommt, weiß
    /// schlicht nicht, ob das Geld unterwegs ist.
    ///
    /// Drei Zustände statt zwei. Die Regel für die Einordnung: Ging vor dem Abbruch
    /// schon etwas an die Bank (`confirm`/`respond`), ist es `unklar` — sonst
    /// `abgebrochen`.
    private enum SCAErgebnis {
        case erfolg(SCAOutcome)
        /// Nichts wurde an die Bank geschickt, oder der Nutzer hat abgebrochen.
        case abgebrochen
        /// Der Ablauf brach ab, **nachdem** etwas an die Bank ging. Bei Zahlungen darf
        /// daraus weder ein „fehlgeschlagen" noch ein neuer Versuch werden.
        case unklar
    }

    private enum SCACommon {
        case result(SCAPayload, Session?, ConnectionData?)
        /// `String?` = optionale Challenge-Nachricht der Bank (z.B. „TAN an ***1234"),
        /// `Aufgabenbild?` = die optische Aufgabe (chipTAN-QR, Flicker, photoTAN).
        /// Beides wird im Field-Input-Sheet angezeigt.
        ///
        /// Das Bild fehlte hier bis 02.09.2026. Es kam im SDK längst mit
        /// (`Dialog.image`), wurde beim Übersetzen aber weggeworfen — und damit stand
        /// im chipTAN-Dialog nur der Begleittext. Ohne QR-Code erzeugt der Generator
        /// keine TAN, der Dialog war also nicht zu beantworten.
        case dialog(DialogInput, String?, SCAFieldInput.Aufgabenbild?)
        case redirect(URL, ConfirmationContext)
        case redirectHandle(String, ConfirmationContext)
    }

    /// Übersetzt die Antwort eines beliebigen Dienstes in unsere gemeinsame Form.
    ///
    /// Bis 0.4.1 gab es dafür vier fast gleiche Überladungen, weil jeder Dienst seinen
    /// eigenen Antworttyp hatte. 0.5.0 liefert `Response<T>` für alle, also genügt eine
    /// generische Fassung; `verpacken` sagt nur noch, welcher Dienst geantwortet hat.
    private static func toSCACommon<R>(_ r: Response<R>,
                                       _ verpacken: (Authenticated<R>) -> SCAPayload) -> SCACommon {
        switch r {
        case .result(let res):
            return .result(verpacken(res.authenticated), res.session, res.connectionData)
        case .dialog(let d):
            return .dialog(d.input, d.message, d.image.map {
                SCAFieldInput.Aufgabenbild(mimeType: $0.mimeType, daten: $0.data, hhdUC: $0.hhdUCData)
            })
        case .redirect(let red):
            return .redirect(red.url, red.context)
        case .redirectHandle(let h):
            return .redirectHandle(h.handle, h.context)
        }
    }

    /// Für Konten zusätzlich protokolliert — der Dialog dieses Dienstes war bei der
    /// bunq-Diagnose die einzige Stelle, an der sich die Freigabe-Runden zählen ließen.
    private static func toSCACommonAccounts(_ r: Response<AccountsResult>) -> SCACommon {
        if case .dialog(let d) = r {
            AppLogger.log("AccountsResponse dialog: ctx=\(d.context.map{"\($0)"} ?? "nil") msg=\(d.message ?? "nil") input=\(d.input)", category: "YaxiService")
        }
        return toSCACommon(r) { .accounts($0) }
    }

    /// `slotId` ist das Konto, zu dem dieser Aufruf gehört — nicht das gerade aktive.
    /// Beide fallen auseinander, sobald während einer Einrichtung ein anderes Konto
    /// aktiv ist: Ein Kunde richtete die HypoVereinsbank ein und bekam im TAN-Dialog
    /// „REWE" als Bank genannt, weil ein REWE-Slot aktiv war (gemeldet 29.07.). In
    /// einem Dialog, in den jemand eine TAN tippt, ist die falsche Bank kein
    /// Schönheitsfehler.
    private static func handleSCA(
        initial: SCACommon,
        client: RoutexClient,
        ticket: some RoutexTicket,
        slotId: String,
        confirm: @escaping @Sendable (ConfirmationContext) async throws -> SCACommon,
        respond: @escaping @Sendable (InputContext, String) async throws -> SCACommon,
        depth: Int = 0
    ) async -> SCAErgebnis {
        if depth > 5 {
            AppLogger.log("SCA: max depth exceeded", category: "YaxiService", level: "WARN")
            return .unklar
        }

        switch initial {

        case .result(let payload, let session, let connectionData):
            setupPhaseReporter?("sca_result", ["connection_data": connectionData == nil ? "none" : "\(connectionData!.bytes.count)b"])
            AppLogger.log("SCA result: connectionData=\(connectionData == nil ? "nil" : "\(connectionData!.bytes.count)b") slot=\(slotId.prefix(8)) schritte=\(depth)", category: "YaxiService")
            // `depth > 0` heißt: Zwischen Anfrage und Ergebnis lag mindestens ein
            // Dialog oder ein Redirect — der Nutzer hat also etwas bestätigt. Kommt
            // dabei keine neue Zustimmung zurück, kann die App die gespeicherte nicht
            // erneuern und schickt beim nächsten Mal wieder die alte. Genau diese
            // Sackgasse ließ sich am 02.09.2026 für bunq nur mühsam aus Zählwerten
            // zurückrechnen; sie gehört als eine Zeile ins Protokoll.
            if depth > 0, connectionData == nil {
                let alter = await sessionStore.connectionDataAge(slotId: slotId)
                let alterText = alter.map { String(format: "%.1f h", $0 / 3600) } ?? "unbekannt"
                AppLogger.log(
                    "SCA: Freigabe durchlaufen (\(depth) Schritte), aber KEINE neuen " +
                    "Verbindungsdaten — gespeicherte sind \(alterText) alt, slot=\(slotId.prefix(8))",
                    category: "YaxiService", level: "WARN")
            }
            return .erfolg(SCAOutcome(payload: payload, session: session, connectionData: connectionData))

        case .dialog(let input, let dialogMsg, let dialogBild):
            switch input {

            case .selection(let options, let context):
                let preferred = options.first(where: { o in
                    let s = "\(o.key) \(o.label) \(o.explanation ?? "")".lowercased()
                    return s.contains("push") || s.contains("app") || s.contains("decoupled")
                }) ?? options.first
                guard let preferred else {
                    AppLogger.log("SCA Selection: no options available", category: "YaxiService", level: "WARN")
                    return .abgebrochen
                }
                // Sieht die Auswahl nach Konten statt nach TAN-Verfahren aus, ist die
                // Heuristik unten die falsche — sie kennt nur Verfahren. Seit die App
                // das Quellkonto benennt, sollte das nicht mehr auftreten; falls doch,
                // steht der Grund hier statt nirgends.
                if Auswahlart.sindKonten(options.map { "\($0.key) \($0.label) \($0.explanation ?? "")" }) {
                    AppLogger.log(
                        "SCA Selection: Optionen sehen nach KONTEN aus (\(options.count)) — " +
                        "die Auswahl trifft die App, nicht der Nutzer. slot=\(slotId.prefix(8))",
                        category: "YaxiService", level: "WARN")
                }
                AppLogger.log("SCA Selection: picking '\(preferred.key)'", category: "YaxiService")
                do {
                    let next = try await respond(context, preferred.key)
                    return await handleSCA(initial: next, client: client, ticket: ticket, slotId: slotId,
                                           confirm: confirm, respond: respond, depth: depth + 1)
                } catch {
                    AppLogger.log("SCA respond error: \(error.localizedDescription)", category: "YaxiService", level: "ERROR")
                    return .unklar
                }

            case .confirmation(let context, let pollingDelaySecs):
                // Push/Decoupled-Freigabe → Setup-UI auf „Banking-App öffnen…" stellen.
                scaMethodReporter?(.decoupledApproval)
                if let delay = pollingDelaySecs {
                    // YAXI: pollingDelay set → poll until confirmed
                    AppLogger.log("SCA Confirmation: polling delay=\(delay)s", category: "YaxiService")
                    return await pollConfirmation(
                        context: context,
                        delay: TimeInterval(delay),
                        client: client, ticket: ticket, slotId: slotId,
                        confirm: confirm, respond: respond, depth: depth
                    )
                } else {
                    // Ohne `pollingDelay` **nicht** pollen. Hier standen früher feste 5 s
                    // mit der Begründung, das habe zuverlässig funktioniert. YAXI erlaubt
                    // automatisches Nachfragen aber nur mit angegebenem Abstand — ohne ihn
                    // fragt die App die Bank ungefragt in einem Takt ab, den diese nie
                    // genannt hat.
                    //
                    // Stattdessen: Bankmeldung zeigen und den Nutzer sagen lassen, wann er
                    // bestätigt hat. Genau ein `confirm` danach.
                    AppLogger.log("SCA Confirmation: kein pollingDelay — Bestätigung wird erfragt statt gepollt",
                                  category: "YaxiService")
                    guard let provider = fieldInputProvider else {
                        AppLogger.log("SCA Confirmation: kein Provider — ohne Polling-Freigabe nicht fortsetzbar",
                                      category: "YaxiService", level: "WARN")
                        return .abgebrochen
                    }
                    let slotEpochSnapshot = await onMainRunLoop {
                        MultibankingStore.shared.activeSlotEpoch
                    }
                    let slotName = await onMainRunLoop {
                        MultibankingStore.shared.slots.first(where: { $0.id == slotId })?.displayName
                    }
                    let spec = SCAFieldInput.Spec(
                        type: .text, secrecyLevel: .plain,
                        minLength: nil, maxLength: nil,
                        bankDisplayName: scaBankLabel(
                            slotName: slotName,
                            connectionName: UserDefaults.standard.string(forKey: connectionNameKey(for: slotId))),
                        msg: dialogMsg ?? L10n.t(
                            "Bitte bestätige die Anfrage in deiner Banking-App.",
                            "Please approve the request in your banking app."),
                        slotEpochAtRequest: slotEpochSnapshot,
                        bild: dialogBild,
                        nurBestaetigen: true
                    )
                    let bestaetigt = await withCheckedContinuation {
                        (cont: CheckedContinuation<String?, Never>) in
                        RunLoop.main.perform(inModes: [.default, .modalPanel]) {
                            MainActor.assumeIsolated {
                                let guard_ = FieldInputResumeGuard(cont)
                                provider(spec) { wert in guard_.resume(wert) }
                            }
                        }
                    }
                    guard bestaetigt != nil else {
                        AppLogger.log("SCA Confirmation: vom Nutzer abgebrochen", category: "YaxiService")
                        return .abgebrochen
                    }
                    do {
                        let next = try await confirm(context)
                        return await handleSCA(initial: next, client: client, ticket: ticket, slotId: slotId,
                                               confirm: confirm, respond: respond, depth: depth + 1)
                    } catch {
                        AppLogger.log("SCA Confirmation: confirm nach Bestätigung fehlgeschlagen: \(String(reflecting: error))",
                                      category: "YaxiService", level: "ERROR")
                        await writeTrace(client: client, label: "sca-confirm-manuell",
                                         ticket: ticket, error: error)
                        return .unklar
                    }
                }

            case .field(let type, let secrecy, let minLen, let maxLen, let context):
                // Kein Provider gesetzt = wir laufen ohne UI (Tests/CLI). Sauberer
                // Abbruch wie bisher, damit nicht-UI-Konsumenten nicht crashen.
                guard let provider = fieldInputProvider else {
                    AppLogger.log("SCA field: no provider registered, aborting",
                                  category: "YaxiService", level: "WARN")
                    return .abgebrochen
                }
                // Tipp-TAN/PIN → Setup-UI auf „Code eingeben" stellen (nicht App-Freigabe).
                scaMethodReporter?(.fieldInput)
                // Ab hier NUR noch `onMainRunLoop`, kein `MainActor.run`: Während der
                // Einrichtungsassistent modal läuft, bliebe jeder gewöhnliche Hop bis
                // zum Abbruch liegen — siehe die Begründung an `onMainRunLoop`.
                let slotEpochSnapshot = await onMainRunLoop {
                    MultibankingStore.shared.activeSlotEpoch
                }
                // Ausdrücklich der Slot DIESES Aufrufs, nicht der aktive.
                let slotName = await onMainRunLoop {
                    MultibankingStore.shared.slots.first(where: { $0.id == slotId })?.displayName
                }
                let bankName = scaBankLabel(
                    slotName: slotName,
                    connectionName: UserDefaults.standard.string(forKey: connectionNameKey(for: slotId))
                )
                let spec = SCAFieldInput.Spec(
                    type: type, secrecyLevel: secrecy,
                    minLength: minLen, maxLength: maxLen,
                    bankDisplayName: bankName,
                    msg: dialogMsg,
                    slotEpochAtRequest: slotEpochSnapshot,
                    bild: dialogBild
                )
                // Nur Metadaten loggen — der eingegebene Wert ist Secret.
                AppLogger.log(
                    "SCA field: requesting input type=\(type) secrecy=\(secrecy) " +
                    "min=\(minLen.map(String.init) ?? "—") max=\(maxLen.map(String.init) ?? "—")",
                    category: "YaxiService"
                )
                // Das Panel wird aus dem Runloop-Callback heraus aufgebaut und gezeigt.
                // Es MUSS synchron dort geschehen: Ein `Task { @MainActor }` landete
                // wieder auf der Main-Queue und damit im selben Stau.
                let userValue = await withCheckedContinuation {
                    (cont: CheckedContinuation<String?, Never>) in
                    RunLoop.main.perform(inModes: [.default, .modalPanel]) {
                        MainActor.assumeIsolated {
                            let guard_ = FieldInputResumeGuard(cont)
                            provider(spec) { guard_.resume($0) }
                        }
                    }
                }
                guard let userValue else {
                    AppLogger.log("SCA field: user cancelled", category: "YaxiService")
                    return .abgebrochen
                }
                // Slot-Race: User hat während Eingabe Bank gewechselt → der
                // InputContext zeigt auf eine fremde Session, nicht abschicken.
                // Auch hier `onMainRunLoop`: Die verschachtelte TAN-Session ist zwar
                // vorbei, die äußere Assistenten-Session läuft aber weiter.
                let currentEpoch = await onMainRunLoop {
                    MultibankingStore.shared.activeSlotEpoch
                }
                guard currentEpoch == slotEpochSnapshot else {
                    AppLogger.log("SCA field: slot epoch changed during input, aborting",
                                  category: "YaxiService", level: "WARN")
                    return .abgebrochen
                }
                do {
                    let next = try await respond(context, userValue)
                    return await handleSCA(initial: next, client: client, ticket: ticket, slotId: slotId,
                                           confirm: confirm, respond: respond, depth: depth + 1)
                } catch {
                    // `localizedDescription` ist hier wertlos: `UnexpectedError(userMessage: nil)`
                    // beschreibt sich damit als nichts. Deshalb der volle Typ — und ein Trace,
                    // denn dieser Zweig kehrt mit nil zurück statt zu werfen, weshalb der
                    // Trace-Schreiber in fetchBalances/fetchTransactions nie erreicht wird.
                    // Genau der Fehler, auf den es ankommt, hinterließ bisher keine Spur.
                    AppLogger.log("SCA field respond error: \(String(reflecting: error))",
                                  category: "YaxiService", level: "ERROR")
                    await writeTrace(client: client, label: "sca-field-respond",
                                     ticket: ticket, error: error)
                    return .unklar
                }
            }

        case .redirect(let url, let context):
            // Läuft für dieses Konto schon eine Freigabe, wird **keine zweite Seite**
            // geöffnet. Siehe `Freigabewache`: Der Nutzer bestätigt gerade im Browser;
            // eine weitere Seite macht die begonnene nur wertlos.
            guard await Freigabewache.shared.beginnen(slotId) else {
                AppLogger.log("SCA Redirect: Freigabe für diesen Slot läuft bereits — keine zweite Seite",
                              category: "YaxiService", level: "WARN")
                return .abgebrochen
            }
            defer { Task { await Freigabewache.shared.beenden(slotId) } }
            AppLogger.log("SCA Redirect: opening browser", category: "YaxiService")
            await openRedirectURL(url, vorgang: redirectVorgang(slotId: slotId, ticket: ticket))
            return await pollRedirect(context: context, client: client, ticket: ticket, slotId: slotId,
                                      confirm: confirm, respond: respond)

        case .redirectHandle(let handle, let context):
            guard await Freigabewache.shared.beginnen(slotId) else {
                AppLogger.log("SCA RedirectHandle: Freigabe für diesen Slot läuft bereits — keine zweite Seite",
                              category: "YaxiService", level: "WARN")
                return .abgebrochen
            }
            defer { Task { await Freigabewache.shared.beenden(slotId) } }
            AppLogger.log("SCA RedirectHandle: registering redirect URI", category: "YaxiService")
            let callbackServer = YaxiOAuthCallback()
            guard let port = try? await callbackServer.start(), port > 0 else {
                AppLogger.log("SCA: failed to start callback server", category: "YaxiService", level: "ERROR")
                return .abgebrochen
            }
            let bankURL: URL
            do {
                bankURL = try await client.registerRedirectURI(
                    ticket: ticket,
                    handle: handle,
                    redirectURI: "http://localhost:\(port)/simplebanking-auth-callback"
                )
            } catch {
                callbackServer.stop()
                AppLogger.log("SCA registerRedirectURI failed: \(error.localizedDescription)", category: "YaxiService", level: "ERROR")
                return .abgebrochen
            }
            AppLogger.log("SCA RedirectHandle: opening bank URL in browser", category: "YaxiService")
            await openRedirectURL(bankURL, vorgang: redirectVorgang(slotId: slotId, ticket: ticket))
            // Signal stream: fires immediately when localhost callback arrives
            let callbackSignal = AsyncStream<Void> { continuation in
                callbackServer.onCallbackReceived = { continuation.yield(); continuation.finish() }
            }
            let result = await pollRedirect(context: context, client: client, ticket: ticket, slotId: slotId,
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
        ticket: some RoutexTicket,
        slotId: String,
        confirm: @escaping @Sendable (ConfirmationContext) async throws -> SCACommon,
        respond: @escaping @Sendable (InputContext, String) async throws -> SCACommon,
        depth: Int
    ) async -> SCAErgebnis {
        Task { @MainActor in YaxiService.onTanStateChanged?(true, slotId) }
        defer { Task { @MainActor in YaxiService.onTanStateChanged?(false, slotId) } }
        var ctx = context
        var currentDelay = delay
        var consecutiveErrors = 0
        var errorBackoff: TimeInterval = 0
        for i in 0..<180 {
            let sleepSeconds = max(currentDelay, 1.0) + errorBackoff
            try? await Task.sleep(nanoseconds: UInt64(sleepSeconds * 1_000_000_000))
            if Task.isCancelled { return .unklar }
            do {
                let next = try await confirm(ctx)
                consecutiveErrors = 0
                errorBackoff = 0  // reset nach erfolgreicher Antwort
                switch next {
                case .result:
                    return await handleSCA(initial: next, client: client, ticket: ticket, slotId: slotId,
                                           confirm: confirm, respond: respond, depth: depth + 1)
                case .dialog(let input, _, _):
                    if case .confirmation(let newCtx, let newDelay) = input {
                        let ctxChanged = newCtx != ctx
                        ctx = newCtx
                        currentDelay = newDelay.map { TimeInterval($0) } ?? currentDelay
                        AppLogger.log("SCA poll[\(i)]: still pending ctx=\(ctx.bytes.count)b changed=\(ctxChanged) delay=\(currentDelay)s", category: "YaxiService")
                        // Nicht jede Runde melden — sonst erschlägt das Warten die
                        // Diagnosedatei. Alle zehn genügt, um zu sehen, wie lange
                        // gewartet wurde und ob sich überhaupt etwas bewegt.
                        if i % 10 == 0 {
                            setupPhaseReporter?("sca_waiting",
                                                ["poll": String(i), "ctx_changed": ctxChanged ? "yes" : "no"])
                        }
                        continue
                    }
                    // Non-confirmation dialog arrived during polling — log it
                    if case .selection(let opts, _) = input {
                        AppLogger.log("SCA poll[\(i)]: got Selection with \(opts.count) options: \(opts.map{$0.key}.joined(separator:", "))", category: "YaxiService")
                    } else {
                        AppLogger.log("SCA poll[\(i)]: got non-confirmation dialog: \(input)", category: "YaxiService", level: "WARN")
                    }
                    return await handleSCA(initial: next, client: client, ticket: ticket, slotId: slotId,
                                           confirm: confirm, respond: respond, depth: depth + 1)
                default:
                    return await handleSCA(initial: next, client: client, ticket: ticket, slotId: slotId,
                                           confirm: confirm, respond: respond, depth: depth + 1)
                }
            } catch {
                consecutiveErrors += 1
                errorBackoff = scaBackoffSeconds(forConsecutiveErrors: consecutiveErrors)
                AppLogger.log("SCA Confirmation poll \(i) error (\(consecutiveErrors) consecutive, next backoff \(errorBackoff)s): \(error.localizedDescription)", category: "YaxiService", level: "WARN")
                // Höherer Threshold + Backoff schützt gegen 429-Rate-Limit-Bursts.
                if consecutiveErrors >= scaMaxConsecutiveErrors { return .unklar }
            }
        }
        setupPhaseReporter?("sca_confirmation_timeout", ["attempts": "180"])
        AppLogger.log("SCA Confirmation: timeout (180 attempts)", category: "YaxiService", level: "WARN")
        return .unklar
    }

    private static func pollRedirect(
        context: ConfirmationContext,
        client: RoutexClient,
        ticket: some RoutexTicket,
        slotId: String,
        confirm: @escaping @Sendable (ConfirmationContext) async throws -> SCACommon,
        respond: @escaping @Sendable (InputContext, String) async throws -> SCACommon,
        callbackSignal: AsyncStream<Void>? = nil
    ) async -> SCAErgebnis {
        Task { @MainActor in YaxiService.onTanStateChanged?(true, slotId) }
        defer { Task { @MainActor in YaxiService.onTanStateChanged?(false, slotId) } }
        let ctx = context   // unverändert: ein neuer Kontext geht an handleSCA
        var callbackFired = false
        var consecutiveErrors = 0

        for _ in 0..<120 {
            if !callbackFired {
                // Race: wait up to 5s OR until redirect callback arrives (whichever first).
                // Use a CheckedContinuation so each racer holds only Sendable values and
                // Swift 6 does not flag mutable-iterator captures inside task-group closures.
                let once = EinmaligerAusloeser()
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
                if Task.isCancelled { return .unklar }
                callbackFired = true // after first callback, fall through to normal 5s polling
            } else {
                try? await Task.sleep(nanoseconds: 5_000_000_000) // 5 s
                if Task.isCancelled { return .unklar }
            }
            do {
                let next = try await confirm(ctx)
                switch next {
                case .result:
                    return await handleSCA(initial: next, client: client, ticket: ticket, slotId: slotId,
                                           confirm: confirm, respond: respond)
                case .dialog(let input, _, _):
                    // Eine Bestätigung mit unverändertem Kontext heißt „noch nicht
                    // fertig" — dafür ist diese Schleife da, sie läuft weiter.
                    if case .confirmation(let newCtx, _) = input, newCtx == ctx {
                        break
                    }
                    // Alles andere gibt `handleSCA` weiter. Vorher endete hier jede
                    // Auswahl und jede Eingabe mit „unexpected dialog" und einem
                    // Abbruch — eine Bank, die NACH dem Browserschritt nach der TAN
                    // fragt, war damit nicht bedienbar, und die chipTAN-Anzeige lief
                    // ins Leere.
                    return await handleSCA(initial: next, client: client, ticket: ticket, slotId: slotId,
                                           confirm: confirm, respond: respond)
                case .redirect, .redirectHandle:
                    // Ein zweiter Browserschritt. Bisher wurde nur der Kontext
                    // übernommen und weitergepollt — die neue Seite hat nie jemand
                    // geöffnet, also konnte die Freigabe nicht fertig werden.
                    return await handleSCA(initial: next, client: client, ticket: ticket, slotId: slotId,
                                           confirm: confirm, respond: respond)
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
                    return .unklar
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
        return .unklar
    }

    // MARK: - Trace

    /// Fetches the trace for the last client operation and writes it to
    /// ~/Library/Logs/simplebanking/yaxi-trace-<timestamp>-<label>.txt
    /// Always creates a file — even when no traceId is available — so that
    /// the call site can be confirmed and the triggering error is recorded.
    /// - Parameter traceId: Kennung des Aufrufs, um den es geht. Wird sie nicht
    ///   übergeben, fragt die Funktion den Client — was nur solange stimmt, wie seither
    ///   keine weitere Anfrage lief. Aufrufer in einem `catch` sollten sie deshalb
    ///   ausdrücklich mitgeben.
    static func writeTrace(client: RoutexClient, label: String, ticket: some RoutexTicket,
                           error: Error? = nil, traceId: TraceID? = nil) async {
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

        let aktuelleKennung = await client.traceID
        if let traceId = traceId ?? aktuelleKennung {
            do {
                let text = try await client.trace(ticket: ticket, traceID: traceId)
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

    // MARK: - Error-Report-Capture (für „Problem melden"-Flow)

    /// Schreibt einen Trace ins `reports/`-Verzeichnis — bypassed bewusst den
    /// `AppLogger.isEnabled`-Gate (`writeTrace` respektiert den noch), weil
    /// der User durch den expliziten „Problem melden"-Klick später Consent
    /// gibt. Trace ist YAXI-AGE-encrypted, Klartext-Bank-Daten landen nicht
    /// im File. Gibt den File-URL zurück oder nil bei Schreib-Fehler.
    static func writeTraceForReport(
        client: RoutexClient,
        ticket: some RoutexTicket,
        callName: String,
        traceId: TraceID? = nil
    ) async -> URL? {
        let dir = ErrorReportStore.reportsDirectoryURL
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let ts = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let file = dir.appendingPathComponent("simplebanking-diagnose-\(ts)-\(callName).txt")

        var content = ""
        let aktuelleKennung = await client.traceID
        if let traceId = traceId ?? aktuelleKennung {
            do {
                let text = try await client.trace(ticket: ticket, traceID: traceId)
                content = "=== YAXI trace ===\n\(text)\n"
            } catch let traceError {
                content = "=== trace() call failed ===\n\(traceError)\n"
            }
        } else {
            content = "=== No traceId available from SDK ===\n"
        }

        do {
            try content.write(to: file, atomically: true, encoding: .utf8)
            return file
        } catch {
            AppLogger.log("ErrorReport: trace file write failed: \(error)",
                          category: "ErrorReport", level: "WARN")
            return nil
        }
    }

    /// Capturet einen `UnexpectedError` für den User-Report-Flow. Skipt
    /// stillschweigend bei anderen Error-Typen, in Demo-Mode, und bei
    /// `CallSource`-Quellen die nicht reporten sollen (siehe Doku in
    /// `ErrorReportStore.CallSource`). Trace-Fetch + Store-Registrierung
    /// laufen NACH dem bestehenden `writeTrace`/`clearAll`-Pfad — kein
    /// Eingriff in existierende Recovery-Logik.
    static func captureUnexpectedErrorIfNeeded(
        error: Error,
        client: RoutexClient,
        ticket: some RoutexTicket,
        slotSnapshot: String,
        callName: String,
        callSource: ErrorReportStore.CallSource,
        traceId: TraceID? = nil
    ) async {
        // Nur `RoutexError.unexpectedError` löst den Melde-Fluss aus — der Fehler, für den
        // YAXI einen Trace braucht. Seit SDK 0.5 ist das `RoutexError`; eine Abfrage auf
        // `RoutexClientError` würde hier stillschweigend nie mehr zutreffen und es
        // entstünde kein einziger Fehlerbericht mehr.
        guard let routexErr = error as? RoutexError else { return }
        var userMsgFromBank: String? = nil
        if case .unexpectedError(let m) = routexErr {
            userMsgFromBank = m
        } else {
            return
        }

        // CallSource-Filter (Diagnose, CLI, etc. skippen).
        guard callSource.capturesReports else { return }

        // Demo-Mode skip.
        if UserDefaults.standard.bool(forKey: "demoMode") { return }

        // 1. Trace ins reports/-Verzeichnis (kann nil sein bei Fail).
        let attachmentURL = await writeTraceForReport(
            client: client, ticket: ticket, callName: callName, traceId: traceId
        )
        // Cleanup alter Reports.
        ErrorReportStore.pruneOldReports()

        // 2. Context capturen (alle non-Main).
        // `traceID` ist seit SDK 0.5 eine asynchrone Eigenschaft. Ohne die übergebene
        // Kennung stünde hier die des Trace-Abrufs von oben — siehe writeTrace.
        let ersatzKennung = await client.traceID
        let traceIdData = traceId ?? ersatzKennung
        let traceIdHex: String? = traceIdData.map { $0.bytes.map { String(format: "%02x", $0) }.joined() }
        // Die Ticket-Kennung liefert das SDK jetzt selbst — kein eigenes JWT-Zerlegen mehr.
        let ticketId = ticket.id.uuidString
        let connectionId = UserDefaults.standard.string(forKey: connectionIdKey(for: slotSnapshot))
        let alertTitle = RoutexErrorMapper.userMessage(for: error).title
        let createdAt = Date()
        let userMsgFromBankCopy = userMsgFromBank

        // 3. Hop auf MainActor für Bank-Name + Store-Register.
        await MainActor.run {
            let bankName = MultibankingStore.shared.slots
                .first(where: { $0.id == slotSnapshot })?.displayName
            let report = ErrorReportStore.PendingErrorReport(
                id: UUID(),
                createdAt: createdAt,
                callName: callName,
                slotId: slotSnapshot,
                bankDisplayName: bankName,
                connectionId: connectionId,
                traceId: traceIdHex,
                ticketId: ticketId,
                userMessageFromBank: userMsgFromBankCopy,
                attachmentURL: attachmentURL,
                alertTitle: alertTitle
            )
            ErrorReportStore.shared.register(report, source: callSource)
        }
    }

    // MARK: - Redirect URL throttling and browser opening

    /// Öffnet die Freigabe-URL der Bank im Browser.
    ///
    /// Die Drossel verhindert, dass parallel laufende Abrufe **dieselbe** Freigabe
    /// mehrfach aufreißen. Sie verglich bisher nur die Zeit, nicht die URL — und war
    /// damit prozessweit blind gegenüber einer NEUEN Freigabe-Anforderung.
    ///
    /// Das brach Banken mit mehreren Freigaben pro Einrichtung, allen voran bunq: Der
    /// Konten-Abruf öffnet den QR-Code, der Nutzer scannt und gibt auf dem Telefon frei
    /// (ein bis drei Minuten), danach verlangt der Umsatzabruf eine zweite Freigabe —
    /// deren URL wurde verworfen, weil die erste keine 290 s zurücklag. Kein Browser,
    /// kein neuer QR-Code, nichts erreichte das Telefon; `pollRedirect` lief zehn
    /// Minuten ins Leere und die Einrichtung scheiterte.
    ///
    /// Jetzt greift die Drossel nur noch bei **identischer** URL. Eine neue Freigabe
    /// hat einen neuen Zustandsparameter und damit eine neue URL, kommt also durch.
    /// Ein Fenster-Sturm droht dadurch nicht: `pollRedirect` öffnet URLs nicht erneut
    /// (`:2026-2029` aktualisiert nur den Kontext), diese Funktion läuft genau einmal
    /// je Freigabe-Zyklus.
    /// Öffnet die Freigabe-Seite — höchstens einmal je Freigabe-Vorgang.
    ///
    /// `vorgang` ist Slot plus Ticket. Das Ticket wird pro Dienstaufruf neu ausgestellt,
    /// ist also genau die Einheit, die der Nutzer als „eine Freigabe" erlebt.
    ///
    /// Vorher war der Schlüssel die vollständige URL, und der Zustand lag in zwei
    /// prozessweiten Variablen. Beides war falsch, in beide Richtungen: Bei bunq, das je
    /// Dienst eine eigene Freigabe verlangt, wurde die zweite verschluckt, weil sie in
    /// dasselbe Zeitfenster fiel — und umgekehrt hätte ein Wiederholungsversuch, der nur
    /// `state` oder eine Nonce ändert, ein zweites Browserfenster aufgemacht, obwohl es
    /// logisch dieselbe Freigabe ist. Über das Ticket sind beide Fälle richtig: neuer
    /// Dienstaufruf → neues Ticket → neues Fenster; Wiederholung derselben Anfrage →
    /// gleiches Ticket → kein zweites Fenster.
    private static func openRedirectURL(_ url: URL, vorgang: String) async {
        guard await RedirectCoordinator.shared.darfOeffnen(vorgang: vorgang) else {
            AppLogger.log("SCA: Freigabe-Seite für diesen Vorgang bereits geöffnet — kein zweites Fenster",
                          category: "YaxiService")
            return
        }
        setupPhaseReporter?("sca_redirect_open", ["host": url.host ?? "?"])
        AppLogger.log("SCA: öffne Freigabe-Seite (host=\(url.host ?? "?"))", category: "YaxiService")
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

/// Genau-einmal-Wrapper für die Continuation der TAN-Eingabe.
///
/// Der Presenter garantiert einen einzigen Completion-Aufruf selbst (Coordinator bzw.
/// ContinuationBox), aber diese Zusage steht in einer anderen Datei — und ein zweites
/// `resume` auf derselben Continuation ist kein Fehlverhalten, sondern ein Absturz.
@MainActor
final class FieldInputResumeGuard {
    private var cont: CheckedContinuation<String?, Never>?
    init(_ cont: CheckedContinuation<String?, Never>) { self.cont = cont }
    func resume(_ value: String?) {
        guard let c = cont else { return }
        cont = nil
        c.resume(returning: value)
    }
}

// MARK: - Freigabe-Weiterleitungen

/// Merkt sich, für welchen Freigabe-Vorgang schon eine Browser-Seite geöffnet wurde.
///
/// Ein Actor, weil der Zustand vorher in zwei `nonisolated(unsafe)`-Variablen lag und
/// von jedem SCA-Ablauf ohne Absicherung verändert wurde. In der Praxis serialisieren
/// `BankRequestQueue` und `isHBCICallInFlight` die meisten Bank-Aufrufe, aber nicht alle
/// Pfade gehen dort durch — eine Einrichtung und ein Hintergrund-Abgleich auf einem
/// anderen Konto können sich überschneiden.
actor RedirectCoordinator {

    static let shared = RedirectCoordinator()

    /// So lange gilt ein Vorgang als „schon geöffnet". Entspricht der bisherigen
    /// Drosselzeit; die Freigabefrist der Banken liegt darunter.
    static let frist: TimeInterval = 290

    private var geoeffnet: [String: Date] = [:]

    /// `true`, wenn für diesen Vorgang noch keine Seite geöffnet wurde (oder die Frist
    /// abgelaufen ist). Der Aufrufer öffnet dann und gilt als vermerkt.
    func darfOeffnen(vorgang: String, jetzt: Date = Date()) -> Bool {
        aufraeumen(jetzt: jetzt)
        if let zuvor = geoeffnet[vorgang], jetzt.timeIntervalSince(zuvor) < Self.frist {
            return false
        }
        geoeffnet[vorgang] = jetzt
        return true
    }

    /// Alte Einträge verwerfen, damit die Tabelle nicht mit jedem Vorgang wächst.
    private func aufraeumen(jetzt: Date) {
        geoeffnet = geoeffnet.filter { jetzt.timeIntervalSince($0.value) < Self.frist }
    }

    #if DEBUG
    func zuruecksetzenFuerTests() { geoeffnet = [:] }
    #endif
}

extension YaxiService {

    /// Welche Bank der TAN-Dialog nennt.
    ///
    /// Reihenfolge: erst der Name des Slots, zu dem **dieser Aufruf** gehört, dann der
    /// Name aus der Banksuche. Beides ist nötig, und die Reihenfolge ist es auch:
    ///
    /// - Beim **Abruf eines bestehenden Kontos** trägt der Slot den Namen, den der
    ///   Nutzer vergeben hat. Der muss gewinnen, sonst überschreibt der Katalogname
    ///   („UniCredit Bank - HypoVereinsbank") die eigene Benennung.
    /// - Beim **Hinzufügen eines Kontos** ist der Slot noch nicht im Store — die
    ///   vorläufige ID wird vor dem Assistenten aktiviert und erst bei Erfolg zu einem
    ///   sichtbaren Konto. `slotName` ist dann nil, und der Name der gerade eingerichteten
    ///   Verbindung greift.
    ///
    /// Genau hier lag ein Fehler: Solange über den **aktiven** Slot gegangen wurde, nannte
    /// der Dialog beim Hinzufügen das bisherige Konto — gemeldet als „REWE" während einer
    /// HypoVereinsbank-Einrichtung. In einem Fenster, in das jemand eine TAN tippt, ist
    /// die falsche Bank kein Schönheitsfehler.
    static func scaBankLabel(slotName: String?, connectionName: String?) -> String {
        [slotName, connectionName]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first(where: { !$0.isEmpty }) ?? "Bank"
    }

    /// Der Vorgangsschlüssel: Konto plus Ticket.
    ///
    /// Das Ticket ist ein signiertes Token und gehört nicht ins Protokoll — deshalb geht
    /// nur seine Länge und ein kurzer Ausschnitt in den Schlüssel ein, nie der ganze
    /// Wert. Für die Unterscheidung zweier Dienstaufrufe genügt das: Jedes Ticket trägt
    /// eine eigene UUID (siehe `YaxiTicketMaker.issueTicket`).
    static func redirectVorgang(slotId: String, ticket: some RoutexTicket) -> String {
        "\(slotId)|\(ticket.hashValue)"
    }
}
