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
    /// `await MainActor.run` reiht den Block in die Main-Dispatch-Queue ein.
    /// `NSApp.runModal()` fährt die Runloop in `NSModalPanelRunLoopMode`, und dort kam
    /// so ein Hop nicht rechtzeitig an: Bei Banken mit Tipp-TAN (HypoVereinsbank)
    /// erschien das TAN-Feld erst beim Abbruch der Einrichtung — gemessen 17 bis 60
    /// Sekunden zu spät, die TAN war dann abgelaufen. `RunLoop.perform(inModes:)` nennt
    /// die Modes ausdrücklich und kommt an; `SetupFlowPanel.enqueueOnMainRunLoop` nimmt
    /// für seine Callbacks denselben Weg.
    ///
    /// **Korrektur vom 25.09.2026.** Hier stand als Begründung, der Modal-Mode gehöre
    /// nicht zu den Common-Modes und die Main-Queue werde dort deshalb *gar nicht*
    /// bedient. Das ist so nicht richtig. Im selben Prozess nachgemessen:
    ///
    ///     ohne Fenster im Prozess → Main-Queue im Modal-Mode NICHT bedient
    ///     mit einem Fenster       → bedient
    ///
    /// Ein Programm hat immer Fenster, die Absolutaussage traf also nie zu. Sie stammte
    /// aus einem Test, der nur deshalb bestand, weil vor ihm noch kein AppKit-Fenster
    /// entstanden war (siehe `ModalRunLoopDeliveryTests`).
    ///
    /// Am Code ändert das nichts, und zwar aus einem Grund, der die Unterscheidung wert
    /// ist: „wird bedient" heißt nicht „rechtzeitig". Der Feldbefund steht — über die
    /// Main-Queue kam der Hop eine Minute zu spät, über `perform(inModes:)` sofort.
    /// Dieser Weg nennt die Modes ausdrücklich und hängt an keiner Annahme darüber,
    /// welche Quellen AppKit gerade wo eingehängt hat.
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

    /// Die Bankverbindung zu einer IBAN, oder `nil`, wenn YAXI keine kennt.
    ///
    /// Das ist die **belastbare** Antwort auf „ist dieses Konto über Open Banking
    /// erreichbar" — belastbarer als der Kontotyp, den eine fremde App draufschreibt.
    /// Das SDK zieht aus einem IBAN-förmigen Suchbegriff die Bankleitzahl und gibt
    /// die Verbindungen dieses Bereichs heraus (`ibanDetection`).
    ///
    /// Anders als `searchBanks` **wirft** die Funktion: Für den MoneyMoney-Import ist
    /// „YAXI kennt diese Bank nicht" eine Absage an den Nutzer, „die Abfrage ist
    /// fehlgeschlagen" aber nur fehlendes Netz. Beides als leere Liste zu melden
    /// hieße, einem Umsteiger ohne Verbindung zu sagen, seine Banken gingen nicht.
    ///
    /// Bei mehreren Verbindungen zur gleichen Bankleitzahl (etwa FinTS und Weiterleitung)
    /// kommt die erste. Das ist eine Annahme, keine Auskunft — darum führt der
    /// Zurück-Weg aus dem Zugangsdaten-Schritt weiter in die Banksuche, wo der Nutzer
    /// die Verbindung selbst wählen kann.
    static func verbindung(fuerIban iban: String) async throws -> ConnectionInfo? {
        let begriff = iban.replacingOccurrences(of: " ", with: "").uppercased()
        guard begriff.count >= 5 else { return nil }
        let client = YaxiTransport.client()
        let ticket = try YaxiTicketMaker.accountsTicket()
        let gefunden = try await client.search(
            ticket: ticket,
            filters: [.term(begriff)],
            ibanDetection: true,
            limit: 5
        )
        return gefunden.first
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
        callSource: ErrorReportStore.CallSource = .normal,
        ausloeser: Freigabeausloeser = .hintergrund
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
        let freigabe = await handleSCA(
            initial: toSCACommonAccounts(resp), client: client, ticket: finalTicket, slotId: slotSnapshot,
            confirm: confirm, respond: respond, ausloeser: ausloeser
        )
        guard case .erfolg(let outcome) = freigabe else {
            throw scaFehler(freigabe, schritt: L10n.t("Konten", "Accounts"), von: 1, bis: 3)
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
        callSource: ErrorReportStore.CallSource = .normal,
        ausloeser: Freigabeausloeser = .hintergrund
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
                callSource: callSource,
                ausloeser: ausloeser
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
        callSource: ErrorReportStore.CallSource,
        ausloeser: Freigabeausloeser
    ) async throws -> BalancesResponse {
        let connIdKey = connectionIdKey(for: slotSnapshot)
        let ibanKeySnap = ibanKey(for: slotSnapshot)
        let model = loadCredentialsModel(slotId: slotSnapshot)
        let d = UserDefaults.standard
        guard let connectionId = d.string(forKey: connIdKey), !connectionId.isEmpty else {
            // Hier gibt es noch keinen Client und damit keinen Trace. Dann muss die Zeile
            // es sagen, sonst sieht die Diagnose nur eine leere Trace-Ablage und der
            // Nutzer meldet „erstellt kein Trace".
            ohneTraceWeil("fetchBalances", "keine connectionId — der Slot war nie eingerichtet",
                          alwaysTrace: alwaysTrace)
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
        //
        // **Außer in der Diagnose.** `RoutexRefreshClient` hat keine
        // Trace-Schnittstelle; wer diesen Weg nimmt, kann keinen Trace liefern. Gemeldet
        // am 06.11.2026 („Diagnose erstellt kein Trace"), und auf diesem Rechner war
        // genau das die Ursache: Schalter gesetzt, Schnellabruf geglückt, kein Trace.
        // Eine Zeile im Protokoll hat dafür nicht gereicht — die Diagnose fährt man, um
        // den Trace zu bekommen, also nimmt sie hier den langen Weg.
        if !alwaysTrace,
           let cd = storedCD,
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

            let freigabe = await handleSCA(
                initial: toSCACommon(resp) { .balances($0) }, client: client, ticket: scaTicket, slotId: slotSnapshot,
                confirm: confirm, respond: respond, ausloeser: ausloeser
            )
            guard case .erfolg(let outcome) = freigabe else {
                // `userMessage` war hier immer nil, und der Aufrufer setzte dafür einen
                // allgemeinen Satz ein. Bei der eigenen Wache ist der Grund bekannt —
                // dann soll er auch dastehen.
                var meldung: String? = nil
                var freigabeNoetig = false
                if case .freigabeLaeuftBereits = freigabe { meldung = Self.freigabeLaeuftText }
                if case .freigabeNoetig = freigabe {
                    meldung = Self.freigabeNoetigText
                    freigabeNoetig = true
                }
                await traceBeiAusgang(client: client, ticket: ticket,
                                      label: "diag-fetchBalances-sca-\(freigabe.kurzname)",
                                      alwaysTrace: alwaysTrace)
                return BalancesResponse(ok: false, booked: nil, expected: nil, session: nil,
                                       connectionData: nil, error: nil,
                                       userMessage: meldung, scaRequired: true,
                                       freigabeNoetig: freigabeNoetig)
            }

            AppLogger.log("fetchBalances: outcome.connectionData=\(outcome.connectionData == nil ? "nil" : "\(outcome.connectionData!.bytes.count)b")", category: "YaxiService")
            await sessionStore.update(scope: .balances,
                                      session: outcome.session?.bytes,
                                      connectionData: outcome.connectionData?.bytes,
                                      slotId: slotSnapshot)

            guard case .balances(let result) = outcome.payload else {
                await traceBeiAusgang(client: client, ticket: ticket,
                                      label: "diag-fetchBalances-falscher-antworttyp",
                                      alwaysTrace: alwaysTrace)
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
                    await traceBeiAusgang(client: client, ticket: ticket,
                                          label: "diag-fetchBalances-konto-nicht-in-zustimmung",
                                          alwaysTrace: alwaysTrace)
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
        callSource: ErrorReportStore.CallSource = .normal,
        ausloeser: Freigabeausloeser = .hintergrund
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
                callSource: callSource,
                ausloeser: ausloeser
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
        callSource: ErrorReportStore.CallSource,
        ausloeser: Freigabeausloeser
    ) async throws -> TransactionsResponse {
        let connIdKey = connectionIdKey(for: slotSnapshot)
        let ibanKeySnap = ibanKey(for: slotSnapshot)
        let model = loadCredentialsModel(slotId: slotSnapshot)
        let d = UserDefaults.standard
        guard let connectionId = d.string(forKey: connIdKey), !connectionId.isEmpty else {
            ohneTraceWeil("fetchTransactions", "keine connectionId — der Slot war nie eingerichtet",
                          alwaysTrace: alwaysTrace)
            return TransactionsResponse(ok: false, transactions: nil, session: nil,
                                       connectionData: nil, error: "no connectionId yet",
                                       userMessage: nil, scaRequired: nil)
        }
        let iban = d.string(forKey: ibanKeySnap) ?? ""
        guard !iban.isEmpty else {
            ohneTraceWeil("fetchTransactions", "keine IBAN gespeichert", alwaysTrace: alwaysTrace)
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

        // Erst der nicht-interaktive Weg — siehe `schnellSalden`, dort steht auch, warum
        // die Diagnose ihn überspringt.
        if !alwaysTrace,
           let cd = storedCD,
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

            let freigabe = await handleSCA(
                initial: toSCACommon(resp) { .transactions($0) }, client: client, ticket: scaTicket, slotId: slotSnapshot,
                confirm: confirm, respond: respond, ausloeser: ausloeser
            )
            guard case .erfolg(let outcome) = freigabe else {
                var meldung: String? = nil
                var freigabeNoetig = false
                if case .freigabeLaeuftBereits = freigabe { meldung = Self.freigabeLaeuftText }
                if case .freigabeNoetig = freigabe {
                    meldung = Self.freigabeNoetigText
                    freigabeNoetig = true
                }
                await traceBeiAusgang(client: client, ticket: ticket,
                                      label: "diag-fetchTransactions-sca-\(freigabe.kurzname)",
                                      alwaysTrace: alwaysTrace)
                return TransactionsResponse(ok: false, transactions: nil, session: nil,
                                           connectionData: nil, error: nil,
                                           userMessage: meldung, scaRequired: true,
                                           freigabeNoetig: freigabeNoetig)
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
                await traceBeiAusgang(client: client, ticket: ticket,
                                      label: "diag-fetchTransactions-falscher-antworttyp",
                                      alwaysTrace: alwaysTrace)
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

    /// Kann eine Überweisung trotz dieses Fehlers ausgeführt worden sein?
    ///
    /// Die Frage ist nicht „war es ein Fehler", sondern „hat der Auftrag die Bank
    /// erreicht". Nur wenn das sicher zu verneinen ist, darf die Oberfläche
    /// „fehlgeschlagen" sagen und zum erneuten Senden einladen. Alles andere ist
    /// „unklar" — ein zweiter Versand wäre sonst eine Doppelzahlung.
    ///
    /// - `RoutexError`: fachliche Antworten der Bank. `paymentFailed`, ungültige
    ///   Zugangsdaten, gesperrter Dienst, Validierung (`unexpectedValue`), Ticket,
    ///   Abbruch durch den Nutzer — die Bank hat abgelehnt oder nie angefangen.
    ///   `unexpectedError`/`providerError` können laut YAXI-Doku trotzdem ausgeführt
    ///   sein; `unrecognizedResponse`/`notFound`/`interruptError` sind Infrastruktur-
    ///   antworten, bei denen die Bank den Auftrag schon haben kann.
    /// - `RoutexClientError`: `sealingFailed` passiert vor dem Senden. Unsealing
    ///   oder ein unlesbares Format heißt dagegen: Es kam eine Antwort, wir konnten
    ///   sie nur nicht lesen.
    /// - `HTTPError` (Verbindungsabbruch, Timeout), `CancellationError`, Unbekanntes:
    ///   der Auftrag kann längst angekommen sein.
    static func transferMayHaveBeenExecuted(_ error: Error) -> Bool {
        switch error {
        case let routex as RoutexError:
            switch routex {
            case .paymentFailed, .invalidCredentials, .serviceBlocked, .unauthorized,
                 .accessExceeded, .periodOutOfBounds, .unsupportedProduct,
                 .unexpectedValue, .ticketError, .canceled:
                return false
            case .unexpectedError, .providerError, .unrecognizedResponse, .notFound,
                 .interruptError:
                return true
            }
        case let client as RoutexClientError:
            if case .sealingFailed = client { return false }
            return true
        default:
            return true
        }
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

    // MARK: - Daueraufträge

    /// Was ein Dauerauftrags-Abruf zurückgibt. Spiegelt die Rolle von
    /// `TransactionsResponse`: die Daten, ein technischer Fehler fürs Protokoll und
    /// getrennt davon der Satz, den der Nutzer lesen soll.
    struct DauerauftragsAbruf: Sendable {
        var auftraege: [Dauerauftrag] = []
        var fehler: String? = nil
        var nutzermeldung: String? = nil
        var freigabeNoetig: Bool = false
    }

    /// Die Daueraufträge des aktiven Kontos.
    ///
    /// **Warum hier kein Wiederanlauf-Gestrüpp steht.** `fetchBalances` und
    /// `fetchTransactions` tragen eine lange Leiter aus Wiederholungen, weil sie
    /// unbeaufsichtigt an einem Zeitgeber hängen und sich selbst heilen müssen. Dieser
    /// Abruf wird von Hand ausgelöst; scheitert er, ist die ehrliche Antwort eine
    /// Meldung und kein stiller zweiter Versuch mit weniger Zustimmung.
    ///
    /// Daraus folgt beiläufig, dass die Regel aus CLAUDE.md hier nicht verletzt werden
    /// *kann*: Es gibt keinen Zweig, der die `connectionData` beiseitelegt. Bei einer
    /// Weiterleitungsbank bleibt die Zustimmung unangetastet, auch wenn dieser Dienst
    /// sie ablehnt.
    ///
    /// **Session aus dem Salden-Bereich, mit Absicht.** YAXI zum Umstand, dass
    /// `standingOrders` keinen Aufruf ohne Zugangsdaten hat: „Genau dafür ist die
    /// Session gut." Die Freigabe des vorangegangenen Salden-Abrufs trägt also, und der
    /// Nutzer bestätigt einmal statt zweimal. Ein eigener vierter `Scope` wäre das
    /// Gegenteil: Ihn befüllt niemand, also käme der erste Abruf immer mit
    /// `session: nil` und kostete seine eigene Freigabe.
    ///
    /// Die `connectionData` wandert ebenfalls in den Salden-Bereich zurück — sie gilt
    /// laut YAXI über Dienstgrenzen und nützt dort dem nächsten Abruf.
    static func fetchStandingOrders(
        userId: String,
        password: String,
        ausloeser: Freigabeausloeser = .nutzerhandlung
    ) async throws -> DauerauftragsAbruf {
        // Demo-Modus: kein Bank-Aufruf, zwei Beispielaufträge. Gleiches Muster wie in
        // `sendTransfer` — und die einzige Möglichkeit, die Anzeige zu prüfen, ohne
        // eine echte Freigabe an einer echten Bank zu verbrauchen.
        if UserDefaults.standard.bool(forKey: "demoMode") {
            try? await Task.sleep(nanoseconds: 700_000_000)
            return DauerauftragsAbruf(auftraege: Dauerauftrag.beispiele())
        }

        let slotSnapshot = activeSlotId
        // HBCI-Mutex: Jede neue Bank-Aufrufstelle geht über die Warteschlange, sonst
        // antwortet eine Volksbank mit „Fehlender Dialogkontext" (CLAUDE.md).
        let ergebnis: DauerauftragsAbruf? = try await BankRequestQueue.shared.withSlot(slotSnapshot) {
            try await fetchStandingOrdersLocked(
                slotSnapshot: slotSnapshot, userId: userId, password: password, ausloeser: ausloeser
            )
        }
        guard let ergebnis else {
            AppLogger.log("fetchStandingOrders: slot busy, skip slot=\(slotSnapshot.prefix(8))",
                          category: "YaxiService", level: "WARN")
            return DauerauftragsAbruf(fehler: "bank busy", nutzermeldung: Self.freigabeLaeuftText)
        }
        return ergebnis
    }

    /// Eigentlicher Bank-Call. Voraussetzung: Caller hält den Slot. Nie direkt rufen.
    private static func fetchStandingOrdersLocked(
        slotSnapshot: String,
        userId: String,
        password: String,
        ausloeser: Freigabeausloeser
    ) async throws -> DauerauftragsAbruf {
        let d = UserDefaults.standard
        let model = loadCredentialsModel(slotId: slotSnapshot)
        guard let connectionId = d.string(forKey: connectionIdKey(for: slotSnapshot)),
              !connectionId.isEmpty else {
            return DauerauftragsAbruf(fehler: "no connectionId yet")
        }
        let iban = d.string(forKey: ibanKey(for: slotSnapshot)) ?? ""
        guard !iban.isEmpty else { return DauerauftragsAbruf(fehler: "missing iban") }

        let storedCD = await sessionStore.connectionData(slotId: slotSnapshot)
        let cdAlter = await sessionStore.connectionDataAge(slotId: slotSnapshot)
        let storedSession = await sessionStore.session(for: .balances, slotId: slotSnapshot)
        AppLogger.log("fetchStandingOrders: slot=\(slotSnapshot.prefix(8)) storedCD=\(storedCD == nil ? "nil" : "\(storedCD!.count)b") alter=\(cdAlter.map { String(format: "%.1fh", $0 / 3600) } ?? "?") session=\(storedSession == nil ? "nil" : "present") model.none=\(model.none)",
                      category: "YaxiService")

        // Die gespeicherte Zustimmung reist **im** `Credentials`-Umschlag mit
        // (`Credentials.connectionData`). Dass der Dienst keinen eigenen
        // `connectionData:`-Aufruf hat, heißt also nicht, dass eine Anmeldung nötig ist:
        // „Pass back to skip authentication and authorization steps", sagt das SDK.
        // Manche Banken verlangen für Daueraufträge dennoch eine frische Freigabe —
        // genau deshalb gibt es die Abkürzung nicht, denn sie könnte keine anbieten.
        let creds = try buildCredentials(
            connectionId: connectionId, model: model,
            connectionData: storedCD, userId: userId, password: password
        )

        let client = YaxiTransport.client()
        var ticket = try YaxiTicketMaker.standingOrdersTicket(iban: iban)

        do {
            var resp: Response<StandingOrdersResult>
            do {
                resp = try await client.standingOrders(
                    ticket: ticket, credentials: creds,
                    session: storedSession.map(Session.init), recurringConsents: true
                )
            } catch {
                // Der einzige Wiederanlauf, und er ist der wahrscheinlichste: Die
                // Session kommt aus dem Salden-Abruf, also über eine Dienstgrenze. Ist
                // sie verbraucht, hilft ein Versuch ohne sie — er kostet höchstens eine
                // Freigabe. Die gespeicherte Session wird dabei **nicht** gelöscht; sie
                // gehört dem Salden-Abruf, und der soll sie behalten.
                guard storedSession != nil else { throw error }
                AppLogger.log("fetchStandingOrders: Fehler mit Session, einmal ohne: \(error)",
                              category: "YaxiService", level: "WARN")
                ticket = try YaxiTicketMaker.standingOrdersTicket(iban: iban)
                resp = try await client.standingOrders(
                    ticket: ticket, credentials: creds, session: nil, recurringConsents: true
                )
            }

            let scaTicket = ticket
            let confirm: @Sendable (ConfirmationContext) async throws -> SCACommon = { ctx in
                try await toSCACommon(client.confirmStandingOrders(ticket: scaTicket, context: ctx)) { .standingOrders($0) }
            }
            let respond: @Sendable (InputContext, String) async throws -> SCACommon = { ctx, r in
                try await toSCACommon(client.respondStandingOrders(ticket: scaTicket, context: ctx, response: r)) { .standingOrders($0) }
            }

            let freigabe = await handleSCA(
                initial: toSCACommon(resp) { .standingOrders($0) },
                client: client, ticket: scaTicket, slotId: slotSnapshot,
                confirm: confirm, respond: respond, ausloeser: ausloeser
            )
            guard case .erfolg(let outcome) = freigabe else {
                var meldung: String? = nil
                var freigabeNoetig = false
                if case .freigabeLaeuftBereits = freigabe { meldung = Self.freigabeLaeuftText }
                if case .freigabeNoetig = freigabe {
                    meldung = Self.freigabeNoetigText
                    freigabeNoetig = true
                }
                return DauerauftragsAbruf(nutzermeldung: meldung, freigabeNoetig: freigabeNoetig)
            }

            AppLogger.log("fetchStandingOrders: outcome.connectionData=\(outcome.connectionData == nil ? "nil" : "\(outcome.connectionData!.bytes.count)b")",
                          category: "YaxiService")
            await sessionStore.update(scope: .balances,
                                      session: outcome.session?.bytes,
                                      connectionData: outcome.connectionData?.bytes,
                                      slotId: slotSnapshot)

            guard case .standingOrders(let result) = outcome.payload else {
                return DauerauftragsAbruf(fehler: "unexpected result type")
            }
            // `Authenticated<T>` ist der JWT, nicht das Ergebnis. Signatur prüfen könnte
            // nur ein Backend mit dem HMAC-Schlüssel; für die Anzeige genügt laut SDK
            // das unverifizierte Auslesen.
            let auftraege = try result.decodeUnverified().data.map { Dauerauftrag.aus($0) }
            AppLogger.log("fetchStandingOrders: \(auftraege.count) Aufträge slot=\(slotSnapshot.prefix(8))",
                          category: "YaxiService")
            return DauerauftragsAbruf(auftraege: auftraege)

        } catch {
            let traceId = await client.traceID
            await captureUnexpectedErrorIfNeeded(
                error: error, client: client, ticket: ticket,
                slotSnapshot: slotSnapshot, callName: "fetchStandingOrders",
                callSource: .normal, traceId: traceId
            )
            AppLogger.log("fetchStandingOrders failed: \(error.localizedDescription)",
                          category: "YaxiService", level: "ERROR")
            return DauerauftragsAbruf(
                fehler: error.localizedDescription,
                nutzermeldung: RoutexErrorMapper.userMessage(for: error).detail
                    ?? RoutexErrorMapper.userMessage(for: error).title
            )
        }
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
    /// `requestedExecutionDate` ist optional und steuert **nur den Termin**, nicht die
    /// Geschwindigkeit. Hier stand bis zum 21.10.2026 „nil = sofort (SEPA Instant)" — das
    /// war schlicht falsch und hat die Fehlersuche in die Irre geführt. Routex/YAXI nimmt
    /// einen `Date` und überträgt ihn als ISO-Date an die Bank; Wochenende und Feiertage
    /// werden serverseitig geprüft.
    ///
    /// Über die Geschwindigkeit entscheidet `produkt`, und das ist Pflicht. Die
    /// Voreinstellung `.defaultSEPACreditTransfer` versucht laut SDK zuerst Echtzeit und
    /// fällt auf die normale Überweisung zurück, wenn die Bank sie nicht kann — ohne
    /// Fehler. Vorher stand hier fest `.sepaCreditTransfer`, also **immer** die langsame
    /// Variante, auch bei Banken wie der ING, die Echtzeit standardmäßig beherrschen.
    /// Gemeldet am 20.10.2026 als „Überweisungen brauchen ein bis zwei Tage".
    ///
    /// `.sepaInstantCreditTransfer` erzwingt Echtzeit und liefert `UnsupportedProduct`,
    /// wenn die Bank nicht kann — für Fälle, in denen die Gewissheit wichtiger ist als
    /// das Durchkommen.
    static func sendTransfer(
        request: TransferRequest,
        userId: String,
        password: String,
        requestedExecutionDate: Date? = nil,
        produkt: PaymentProduct = .defaultSEPACreditTransfer
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
                requestedExecutionDate: requestedExecutionDate,
                produkt: produkt
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
        requestedExecutionDate: Date?,
        produkt: PaymentProduct
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
                product: produkt,
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
                product: produkt,
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
                product: produkt,
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
                confirm: confirm, respond: respond,
                // Eine Überweisung gibt es nur, weil jemand sie ausgelöst und
                // bestätigt hat — hier darf die Bankseite aufgehen.
                ausloeser: .nutzerhandlung
            )
            let outcome: SCAOutcome
            switch freigabe {
            case .erfolg(let o):
                outcome = o
            case .abgebrochen:
                return TransferOutcome(ok: false, scaRequired: true, error: nil,
                                       userMessage: nil, mayHaveBeenExecuted: false)
            case .freigabeNoetig:
                // Kann hier eigentlich nicht auftreten — eine Überweisung stößt immer
                // der Nutzer an. Der Fall steht trotzdem ausdrücklich da, damit niemand
                // ihn später stillschweigend unter `default` verschwinden lässt.
                return TransferOutcome(ok: false, scaRequired: true, error: nil,
                                       userMessage: Self.freigabeNoetigText,
                                       mayHaveBeenExecuted: false)
            case .freigabeLaeuftBereits:
                // Wie `abgebrochen` in der Sache — nichts ging an die Bank —, aber der
                // Nutzer bekommt den wahren Grund statt eines Bankfehlers.
                return TransferOutcome(ok: false, scaRequired: true, error: nil,
                                       userMessage: Self.freigabeLaeuftText,
                                       mayHaveBeenExecuted: false)
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
            // Caller-UI muss ehrlich kommunizieren: „Status unklar, prüfe Banking-App",
            // sobald der Auftrag die Bank erreicht haben kann. Klassifikation nach
            // Fehlertyp, siehe `transferMayHaveBeenExecuted` — bis 2.0.3 stand hier
            // ein Textvergleich auf „unexpected"/„provider", der Verbindungsabbrüche
            // nach dem Senden als sicher fehlgeschlagen ausgab.
            return TransferOutcome(
                ok: false, scaRequired: false,
                error: error.localizedDescription,
                userMessage: nil,
                mayHaveBeenExecuted: Self.transferMayHaveBeenExecuted(error)
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

        // Die Auswahl steckt in `Saldoauswahl` — dort steht auch, warum die frühere
        // Rangfolge „Booked vor Available" falsch war. Kurz: Die Postbank liefert als
        // `Booked` den Tagesabschluss des Vortags und daneben ein aktuelleres
        // `Available`; die Reihenfolge der Einträge ist nicht zugesichert.
        //
        // Was die Bank geliefert hat, steht im Protokoll — **immer**, nicht nur im
        // Fehlerfall. „ING zeigt einen anderen Kontostand" (06.11.2026) war ohne diese
        // Zeile nicht zu entscheiden: Welche Arten mit welchem Datum ankamen, wusste
        // niemand.
        let angeboten = allBalances.map { b in
            "\(balanceTypeName(b.balanceType))=\(b.amount)\(b.creditLimitIncluded == true ? "+dispo" : "")@\(b.dateTime.map { ISO8601DateFormatter().string(from: $0) } ?? "ohne Datum")"
        }
        AppLogger.log("Salden der Bank: \(angeboten.isEmpty ? "keine" : angeboten.joined(separator: ", "))",
                      category: "YaxiService")

        // **Kein `?? allBalances.first`.** Das war die Hintertür: Läuft der Filter leer,
        // entschied wieder die Reihenfolge des Feldes — und dann konnte ein `Expected`
        // (das wartende Eingänge einrechnet und deshalb höher steht als jede Banking-App)
        // oder ein zukunftsdatierter Saldo auf dem Schirm landen. Genau die
        // Reihenfolge-Abhängigkeit, die `Saldoauswahl` abschaffen sollte.
        //
        // Liefert die Bank nichts Brauchbares, ist das kein Saldo, sondern ein Befund.
        // Lieber „— €" mit einer Zeile im Protokoll als eine Zahl, die vielleicht etwas
        // anderes bedeutet als der Nutzer annimmt.
        guard let booked = Saldoauswahl.waehle(aus: allBalances) else {
            AppLogger.log("Kein verwendbarer Saldo: \(allBalances.isEmpty ? "die Bank hat keinen geliefert" : "nur unpassende Arten oder alle in der Zukunft")",
                          category: "YaxiService", level: "WARN")
            return BalancesResponse(
                ok: false, booked: nil, expected: nil,
                session: session?.base64EncodedString(),
                connectionData: connectionData?.base64EncodedString(),
                error: nil,
                userMessage: Self.keinSaldoText,
                scaRequired: nil)
        }
        // Ein Saldo, der in der Zukunft liegt, wird genommen (siehe `Saldoauswahl`) —
        // aber er wird benannt. Die ING stempelt mit Ortszeit und kennzeichnet als UTC;
        // der Vorsprung ist dann genau die Zonenverschiebung. Steht die Zahl hier, ist
        // die Rückfrage an YAXI belegt statt geraten.
        if let stand = booked.dateTime, stand > Date() {
            let vorsprung = stand.timeIntervalSinceNow
            AppLogger.log(String(format: "Saldo liegt %.0f min in der Zukunft — Bank stempelt vermutlich Ortszeit als UTC", vorsprung / 60),
                          category: "YaxiService", level: "WARN")
        }

        let expected = allBalances.first(where: { $0.balanceType == .expected })

        return BalancesResponse(
            ok: true,
            booked: makeBalanceModel(booked),
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
            creditLimitIncluded: b.creditLimitIncluded,
            // Bis 21.10.2026 hier weggeworfen. Genau deshalb konnte ein Saldo vom Vortag
            // unbemerkt stehen bleiben: Es gab keine Stelle, an der sein Alter überhaupt
            // noch ablesbar gewesen wäre.
            dateTime: b.dateTime
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
                bankTransactionCode: compactBankTransactionCode(tx.bankTransactionCodes),
                accountServicerReference: tx.accountServicerReference,
                entryReference: tx.entryReference,
                transactionId: tx.transactionID
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
        case standingOrders(Authenticated<StandingOrdersResult>)
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
    /// Der Satz, den der Nutzer sieht, wenn die eigene Wache eine zweite Freigabe
    /// verhindert hat. Er sagt, was los ist, und rät **nicht** zum sofortigen Wiederholen.
    /// Der Satz, wenn ein Hintergrundabruf eine Freigabe bräuchte und deshalb stehen
    /// geblieben ist. Er sagt, was zu tun ist, und drängt nicht.
    static let freigabeNoetigText = L10n.t(
        "Dieses Konto braucht eine neue Freigabe deiner Bank. simplebanking öffnet die Bankseite nicht von selbst — tippe auf \u{201E}Neu verbinden\u{201C}, wenn du sie jetzt erteilen willst.",
        "This account needs a fresh approval from your bank. simplebanking does not open the bank page on its own — choose \u{201C}Reconnect\u{201D} when you want to grant it.")

    static let freigabeLaeuftText = L10n.t(
        "Für dieses Konto läuft gerade schon eine Freigabe. Schließe sie in der Banking-App oder im Browser ab — oder warte einen Moment, dann geht es wieder.",
        "An approval is already running for this account. Finish it in your banking app or browser — or wait a moment and try again.")

    /// Der Satz, wenn die Bank keinen Saldo geliefert hat, den man anzeigen darf.
    ///
    /// Vorher wurde in diesem Fall der erstbeste genommen — auch ein `Expected`, das
    /// wartende Eingänge einrechnet. Eine Zahl, die etwas anderes bedeutet als der Nutzer
    /// annimmt, ist schlimmer als keine; deshalb sagt es hier jemand.
    static let keinSaldoText = L10n.t(
        "Die Bank hat keinen verwertbaren Kontostand geliefert. Die Umsätze unten sind davon nicht betroffen.",
        "The bank did not return a usable balance. The transactions below are unaffected.")

    /// Übersetzt ein nicht erfolgreiches Freigabe-Ergebnis in die Meldung eines Datenabrufs.
    ///
    /// `schritt` nennt den Namen, `von`/`bis` die Stelle in der Einrichtung — beides steht
    /// so schon in den bisherigen Texten und bleibt unverändert. Neu ist nur, dass die
    /// eigene Sperre nicht mehr wie ein Bankfehler klingt.
    private static func scaFehler(_ ergebnis: SCAErgebnis, schritt: String,
                                  von: Int, bis: Int) -> NSError {
        let text: String
        if case .freigabeNoetig = ergebnis {
            text = "\(schritt): \(freigabeNoetigText)"
        } else if case .freigabeLaeuftBereits = ergebnis {
            text = "\(schritt): \(freigabeLaeuftText)"
        } else {
            text = L10n.t("\(schritt): Freigabe konnte nicht abgeschlossen werden (Schritt \(von) von \(bis)). Bitte erneut verbinden.",
                          "\(schritt): approval could not be completed (step \(von) of \(bis)). Please reconnect.")
        }
        return NSError(domain: "YaxiService", code: -2,
                       userInfo: [NSLocalizedDescriptionKey: text])
    }

    /// Wer diesen Bankabruf angestoßen hat.
    ///
    /// Entscheidet, ob eine Freigabe-Seite der Bank aufgehen darf. Gemeldet am
    /// 01.10.2026: Ein Kunde mit abgelaufener ING-Zustimmung bekam mehrmals täglich
    /// ungefragt die Anmeldeseite seiner Bank vorgesetzt — vom Zeitgeber, vom
    /// Programmstart, vom Entsperren. Er hielt es für Phishing, und das war keine
    /// übertriebene Sorge: Ein Browser, der von selbst auf eine Bank-Anmeldung springt,
    /// sieht genau so aus.
    ///
    /// Die Vorgabe ist `.hintergrund`. Wer sie zu setzen vergisst, bekommt das
    /// zurückhaltende Verhalten — nicht das aufdringliche.
    enum Freigabeausloeser: Sendable, Equatable {
        /// Der Nutzer hat unmittelbar davor etwas angeklickt: ↻, Herunterziehen,
        /// „Neu verbinden", der Einrichtungsassistent. Eine Freigabe-Seite darf aufgehen.
        case nutzerhandlung
        /// Zeitgeber, Programmstart, Entsperren, Kontowechsel, CLI, Importeure. Hier
        /// sitzt niemand davor, also öffnet sich nichts.
        case hintergrund
    }

    private enum SCAErgebnis {
        case erfolg(SCAOutcome)
        /// Nichts wurde an die Bank geschickt, oder der Nutzer hat abgebrochen.
        case abgebrochen
        /// Die Bank verlangt eine Freigabe, und der Abruf lief im Hintergrund — es wurde
        /// nichts geöffnet und nichts angefangen. Der Aufrufer merkt sich das Konto und
        /// hört auf, es von selbst zu versuchen.
        case freigabeNoetig
        /// Für dieses Konto läuft bereits eine Freigabe — die `Freigabewache` hat eine
        /// zweite Seite verhindert.
        ///
        /// Eigener Fall, weil es kein Fehler der Bank ist, sondern eine Entscheidung der
        /// App. Unter `abgebrochen` gebündelt kam beim Nutzer „Freigabe konnte nicht
        /// abgeschlossen werden. Bitte erneut verbinden" an — ein Rat, der genau das
        /// empfiehlt, was für die nächsten Minuten wieder scheitert.
        case freigabeLaeuftBereits
        /// Der Ablauf brach ab, **nachdem** etwas an die Bank ging. Bei Zahlungen darf
        /// daraus weder ein „fehlgeschlagen" noch ein neuer Versuch werden.
        case unklar

        /// Für den Namen der Trace-Datei — der Grund ist die Diagnose, nicht die
        /// Uhrzeit. Siehe `traceBeiAusgang`.
        var kurzname: String {
            switch self {
            case .erfolg: return "erfolg"
            case .abgebrochen: return "abgebrochen"
            case .freigabeNoetig: return "freigabe-noetig"
            case .freigabeLaeuftBereits: return "freigabe-laeuft"
            case .unklar: return "unklar"
            }
        }
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
        depth: Int = 0,
        ausloeser: Freigabeausloeser = .hintergrund,
        verfahren: String? = nil
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
                let angebote = options.map {
                    Tanverfahren.Angebot(schluessel: $0.key, beschriftung: $0.label, erklaerung: $0.explanation)
                }
                // Zuerst merken, was die Bank anbietet. Vorher kennt die App die
                // Verfahren dieser Bank nicht — ohne diese Liste hätte die Einstellung
                // unter „Konten" nichts, woraus sich wählen ließe.
                var slotEinstellungen = BankSlotSettingsStore.load(slotId: slotId)
                let angeboteJetzt = Dictionary(angebote.map { ($0.schluessel, $0.beschriftung) },
                                               uniquingKeysWith: { erstes, _ in erstes })
                if slotEinstellungen.tanVerfahrenAngebote != angeboteJetzt {
                    slotEinstellungen.tanVerfahrenAngebote = angeboteJetzt
                    BankSlotSettingsStore.save(slotEinstellungen, slotId: slotId)
                }
                let preferred = Tanverfahren.wahl(
                    aus: angebote,
                    gespeicherterSchluessel: slotEinstellungen.tanVerfahrenSchluessel,
                    gespeicherterName: slotEinstellungen.tanVerfahrenName)
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
                let herkunft = slotEinstellungen.tanVerfahrenSchluessel == nil ? "Vorgabe" : "Einstellung"
                AppLogger.log("SCA Selection: picking '\(preferred.schluessel)' (\(herkunft), \(angebote.count) angeboten)",
                              category: "YaxiService")
                // Der Name, den die Bank dem Verfahren gibt („s-pushTAN"), wanderte
                // bisher nur ins Protokoll. Der Nutzer stand vor „Banking-App öffnen"
                // und musste raten, welche App gemeint ist.
                let gewaehltesVerfahren = Verfahrensname.lesbar(aus: preferred.beschriftung) ?? verfahren
                do {
                    let next = try await respond(context, preferred.schluessel)
                    return await handleSCA(initial: next, client: client, ticket: ticket, slotId: slotId,
                                           confirm: confirm, respond: respond, depth: depth + 1, ausloeser: ausloeser,
                                           verfahren: gewaehltesVerfahren)
                } catch {
                    AppLogger.log("SCA respond error: \(error.localizedDescription)", category: "YaxiService", level: "ERROR")
                    return .unklar
                }

            case .confirmation(let context, let pollingDelaySecs):
                // Push/Decoupled-Freigabe → Setup-UI auf „Banking-App öffnen…" stellen.
                scaMethodReporter?(.decoupledApproval(bankhinweis: dialogMsg, verfahren: verfahren))
                if let delay = pollingDelaySecs {
                    // YAXI: pollingDelay set → poll until confirmed
                    AppLogger.log("SCA Confirmation: polling delay=\(delay)s", category: "YaxiService")
                    return await pollConfirmation(
                        context: context,
                        delay: TimeInterval(delay),
                        client: client, ticket: ticket, slotId: slotId,
                        confirm: confirm, respond: respond, depth: depth, ausloeser: ausloeser,
                        verfahren: verfahren
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
                                               confirm: confirm, respond: respond, depth: depth + 1, ausloeser: ausloeser,
                                           verfahren: verfahren)
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
                                           confirm: confirm, respond: respond, depth: depth + 1, ausloeser: ausloeser,
                                           verfahren: verfahren)
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
            // **Die Absperrung.** Im Hintergrund geht hier gar nichts auf.
            //
            // Gemeldet am 01.10.2026: Ein Kunde mit abgelaufener ING-Zustimmung bekam
            // mehrmals täglich ungefragt die Anmeldeseite seiner Bank vorgesetzt — vom
            // Zeitgeber alle vier Stunden, dazu bei jedem Programmstart, jedem Entsperren
            // und jedem Kontowechsel. Er hielt es für Phishing. Zu Recht: Ein Browser,
            // der von selbst auf eine Bank-Anmeldung springt, sieht genau so aus, und die
            // Mitteilung dazu kam erst hinterher und nannte nicht einmal die Bank.
            //
            // Hier wird abgebrochen, nicht nur das Öffnen unterdrückt: Sonst liefe
            // `pollRedirect` bis zu zehn Minuten auf eine Freigabe zu warten, die niemand
            // erteilen kann, und hielte solange die `Freigabewache`.
            guard ausloeser == .nutzerhandlung else {
                AppLogger.log("SCA: Freigabe nötig, aber Abruf lief im Hintergrund — nichts geöffnet (slot=\(slotId.prefix(8)))",
                              category: "YaxiService")
                await meldeFreigabeNoetig(slotId: slotId)
                return .freigabeNoetig
            }
            // Läuft für dieses Konto schon eine Freigabe, wird **keine zweite Seite**
            // geöffnet. Siehe `Freigabewache`: Der Nutzer bestätigt gerade im Browser;
            // eine weitere Seite macht die begonnene nur wertlos.
            guard await Freigabewache.shared.beginnen(slotId) else {
                AppLogger.log("SCA Redirect: Freigabe für diesen Slot läuft bereits — keine zweite Seite",
                              category: "YaxiService", level: "WARN")
                return .freigabeLaeuftBereits
            }
            AppLogger.log("SCA Redirect: opening browser", category: "YaxiService")
            // Rückleitung hat hier YAXI vorgegeben, nicht wir — das eigene Fenster kann
            // sie nicht erkennen und endet erst mit dem Polling.
            let fenster = await openRedirectURL(url, vorgang: redirectVorgang(slotId: slotId, ticket: ticket),
                                                erwartetRueckleitung: false)
            let ergebnis = await pollRedirect(context: context, client: client, ticket: ticket, slotId: slotId,
                                              confirm: confirm, respond: respond,
                                              callbackSignal: fenster?.fertig, ausloeser: ausloeser, verfahren: verfahren)
            await fenster?.schliessen()
            // Freigabe **abwarten**, nicht in ein loses `Task` schieben. Hier stand
            // `defer { Task { … } }`: Der Vorgang endete, die Wache hielt das Konto noch,
            // und ein sofortiger zweiter Anlauf prallte an der eigenen Sperre ab.
            await Freigabewache.shared.beenden(slotId)
            return ergebnis

        case .redirectHandle(let handle, let context):
            // **Die Absperrung.** Im Hintergrund geht hier gar nichts auf.
            //
            // Gemeldet am 01.10.2026: Ein Kunde mit abgelaufener ING-Zustimmung bekam
            // mehrmals täglich ungefragt die Anmeldeseite seiner Bank vorgesetzt — vom
            // Zeitgeber alle vier Stunden, dazu bei jedem Programmstart, jedem Entsperren
            // und jedem Kontowechsel. Er hielt es für Phishing. Zu Recht: Ein Browser,
            // der von selbst auf eine Bank-Anmeldung springt, sieht genau so aus, und die
            // Mitteilung dazu kam erst hinterher und nannte nicht einmal die Bank.
            //
            // Hier wird abgebrochen, nicht nur das Öffnen unterdrückt: Sonst liefe
            // `pollRedirect` bis zu zehn Minuten auf eine Freigabe zu warten, die niemand
            // erteilen kann, und hielte solange die `Freigabewache`.
            guard ausloeser == .nutzerhandlung else {
                AppLogger.log("SCA: Freigabe nötig, aber Abruf lief im Hintergrund — nichts geöffnet (slot=\(slotId.prefix(8)))",
                              category: "YaxiService")
                await meldeFreigabeNoetig(slotId: slotId)
                return .freigabeNoetig
            }
            guard await Freigabewache.shared.beginnen(slotId) else {
                AppLogger.log("SCA RedirectHandle: Freigabe für diesen Slot läuft bereits — keine zweite Seite",
                              category: "YaxiService", level: "WARN")
                return .freigabeLaeuftBereits
            }
            AppLogger.log("SCA RedirectHandle: registering redirect URI", category: "YaxiService")
            // Zwei Wege zur Rückleitung. Eigenes Fenster (Standard seit 2.0.5): Die Bank
            // leitet auf `simplebanking://auth-callback`, die Sitzung erkennt das Schema
            // und endet. Safari (Schalter in den Einstellungen): lokaler HTTP-Server auf
            // 127.0.0.1 wie bis 2.0.3.
            // `onMainRunLoop`, nicht `MainActor.run` — und das ist hier keine Stilfrage.
            //
            // Der Einrichtungsassistent läuft unter `NSApp.runModal`. Ein gewöhnlicher
            // Hop auf den Hauptthread reiht sich in die Main-Dispatch-Queue ein und kommt
            // dort nicht rechtzeitig an; er wartet, bis die modale Sitzung endet. Gemeldet
            // am 25.09.2026: Die Ersteinrichtung der ING blieb genau hier stehen, ohne dass
            // ein Browser aufging — die Bank-URL wird erst darunter geholt. Im Protokoll
            // endete alles nach „SCA RedirectHandle: registering redirect URI".
            //
            // Betroffen war jede Bank mit Freigabe über einen Handle (ING, bunq, N26,
            // Revolut) und ausschließlich als **erstes** Konto, denn nur die
            // Ersteinrichtung läuft modal. Die Zeile kam mit 2.0.5 herein, zusammen mit
            // dem Schalter, den sie abfragt.
            let eigenesFenster = await onMainRunLoop { Freigabefenster.aktiv }
            var callbackServer: YaxiOAuthCallback? = nil
            let redirectURI: String
            if eigenesFenster {
                redirectURI = Freigabefenster.callbackURI
            } else {
                let server = YaxiOAuthCallback()
                guard let port = try? await server.start(), port > 0 else {
                    AppLogger.log("SCA: failed to start callback server", category: "YaxiService", level: "ERROR")
                    await Freigabewache.shared.beenden(slotId)
                    return .abgebrochen
                }
                callbackServer = server
                redirectURI = "http://localhost:\(port)/simplebanking-auth-callback"
            }
            let bankURL: URL
            do {
                bankURL = try await client.registerRedirectURI(
                    ticket: ticket,
                    handle: handle,
                    redirectURI: redirectURI
                )
            } catch {
                callbackServer?.stop()
                AppLogger.log("SCA registerRedirectURI failed: \(error.localizedDescription)", category: "YaxiService", level: "ERROR")
                await Freigabewache.shared.beenden(slotId)
                return .abgebrochen
            }
            AppLogger.log("SCA RedirectHandle: opening bank URL in browser", category: "YaxiService")
            let fenster = await openRedirectURL(bankURL, vorgang: redirectVorgang(slotId: slotId, ticket: ticket),
                                                erwartetRueckleitung: true)
            // Signal: feuert, sobald die Rückleitung ankommt — im Fenster oder am lokalen Server.
            let callbackSignal: AsyncStream<Void>?
            if let fenster {
                callbackSignal = fenster.fertig
            } else if let server = callbackServer {
                callbackSignal = AsyncStream<Void> { continuation in
                    server.onCallbackReceived = { continuation.yield(); continuation.finish() }
                }
            } else {
                callbackSignal = nil
            }
            let result = await pollRedirect(context: context, client: client, ticket: ticket, slotId: slotId,
                                             confirm: confirm, respond: respond,
                                             callbackSignal: callbackSignal, ausloeser: ausloeser, verfahren: verfahren)
            callbackServer?.stop()
            await fenster?.schliessen()
            // Siehe `.redirect`: abwarten statt in ein loses `Task` schieben. Die Wache
            // wird an **jedem** Ausgang dieses Zweiges freigegeben — bewusst von Hand an
            // drei Stellen statt über `defer`, denn `defer` kann nicht `await`.
            await Freigabewache.shared.beenden(slotId)
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

    /// Hat der Nutzer das Warten beendet? Fragt die Marke ab und verbraucht sie.
    ///
    /// Beide Warteschleifen rufen das je Runde — also höchstens fünf Sekunden nach dem
    /// Klick. Erst wenn sie zurückkehren, geben die `defer` der Aufrufer
    /// `hbciSlotsInFlight` und die Warteschlange frei; genau darauf wartet der neue
    /// Anlauf. Die Vorgänge des Kontos werden gleich mitvergessen, damit die Drossel im
    /// `RedirectCoordinator` die neue Seite nicht schluckt.
    private static func freigabeAbgebrochen(slotId: String, wo: String) async -> Bool {
        guard await Freigabewache.shared.nimmAbbruch(slotId) else { return false }
        await RedirectCoordinator.shared.vergessen(slotId: slotId)
        AppLogger.log("\(wo): vom Nutzer beendet — Warten abgebrochen (slot=\(slotId.prefix(8)))",
                      category: "YaxiService")
        return true
    }

    private static func pollConfirmation(
        context: ConfirmationContext,
        delay: TimeInterval,
        client: RoutexClient,
        ticket: some RoutexTicket,
        slotId: String,
        confirm: @escaping @Sendable (ConfirmationContext) async throws -> SCACommon,
        respond: @escaping @Sendable (InputContext, String) async throws -> SCACommon,
        depth: Int,
        ausloeser: Freigabeausloeser,
        verfahren: String? = nil
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
            if await freigabeAbgebrochen(slotId: slotId, wo: "SCA Confirmation") { return .abgebrochen }
            do {
                let next = try await confirm(ctx)
                consecutiveErrors = 0
                errorBackoff = 0  // reset nach erfolgreicher Antwort
                switch next {
                case .result:
                    return await handleSCA(initial: next, client: client, ticket: ticket, slotId: slotId,
                                           confirm: confirm, respond: respond, depth: depth + 1, ausloeser: ausloeser,
                                           verfahren: verfahren)
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
                                           confirm: confirm, respond: respond, depth: depth + 1, ausloeser: ausloeser,
                                           verfahren: verfahren)
                default:
                    return await handleSCA(initial: next, client: client, ticket: ticket, slotId: slotId,
                                           confirm: confirm, respond: respond, depth: depth + 1, ausloeser: ausloeser,
                                           verfahren: verfahren)
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
        callbackSignal: AsyncStream<Void>? = nil,
        ausloeser: Freigabeausloeser,
        verfahren: String? = nil
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
            if await freigabeAbgebrochen(slotId: slotId, wo: "SCA Redirect") { return .abgebrochen }
            do {
                let next = try await confirm(ctx)
                switch next {
                case .result:
                    return await handleSCA(initial: next, client: client, ticket: ticket, slotId: slotId,
                                           confirm: confirm, respond: respond, ausloeser: ausloeser, verfahren: verfahren)
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
                                           confirm: confirm, respond: respond, ausloeser: ausloeser, verfahren: verfahren)
                case .redirect, .redirectHandle:
                    // Ein zweiter Browserschritt. Bisher wurde nur der Kontext
                    // übernommen und weitergepollt — die neue Seite hat nie jemand
                    // geöffnet, also konnte die Freigabe nicht fertig werden.
                    return await handleSCA(initial: next, client: client, ticket: ticket, slotId: slotId,
                                           confirm: confirm, respond: respond, ausloeser: ausloeser, verfahren: verfahren)
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
    //
    // Gemeldet am 06.11.2026: „Die Diagnose erstellt kein Trace." Sie tat es tatsächlich
    // nicht, und zwar genau in den Fällen, für die man sie fährt. Der Trace hing am Ende
    // des Erfolgszweigs, und die aufschlussreichen Ausgänge — Freigabe nötig, Konto nicht
    // in der Zustimmung, unerwarteter Antworttyp — **kehren normal zurück statt zu
    // werfen**. Damit lief auch der unbedingte Trace im `catch` nicht. Ergebnis: rote
    // Zeile in der Diagnose, null Dateien.
    //
    // Seither gilt: Jeder Ausgang, der etwas zu sagen hat, schreibt einen Trace
    // (`traceBeiAusgang`), und wo keiner möglich ist, steht der Grund im Protokoll
    // (`ohneTraceWeil`).

    /// Sagt im Protokoll, **warum** es hier keinen Trace geben kann.
    ///
    /// Vor dem ersten Bankaufruf gibt es keinen Client, und der Schnellabruf läuft über
    /// `RoutexRefreshClient`, der gar keine Trace-Schnittstelle hat. Eine leere
    /// Trace-Ablage sieht für den Nutzer gleich aus wie ein Fehler — also steht der Grund
    /// dort, wo er nachsieht.
    static func ohneTraceWeil(_ aufruf: String, _ grund: String, alwaysTrace: Bool) {
        guard alwaysTrace else { return }
        AppLogger.log("\(aufruf): kein Trace möglich — \(grund)", category: "YaxiService", level: "WARN")
    }

    /// Trace für einen Ausgang, der weder geglückt ist noch geworfen hat.
    ///
    /// Der Grund steht im Namen der Datei, denn genau der ist die Diagnose. Die Kennung
    /// wird **zuerst** gelesen: `client.trace(…)` ist selbst eine Anfrage und überschreibt
    /// sie sonst mit seiner eigenen — dieselbe Falle wie im `catch`-Zweig.
    static func traceBeiAusgang(client: RoutexClient, ticket: some RoutexTicket,
                                label: String, alwaysTrace: Bool) async {
        guard alwaysTrace else { return }
        let traceId = await client.traceID
        await writeTrace(client: client, label: label, ticket: ticket, error: nil, traceId: traceId)
    }

    /// Holt den Trace zum letzten Aufruf des Clients und legt ihn unter
    /// `~/Library/Logs/simplebanking/trace/yaxi-trace-<zeit>-<label>.txt` ab.
    ///
    /// Legt **immer** eine Datei an — auch ohne Kennung —, damit die Aufrufstelle und der
    /// auslösende Fehler belegt sind.
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
            // Durch die gleiche Säuberung wie das Hauptprotokoll. Der YAXI-Trace darunter
            // ist AGE-verschlüsselt und enthält keinen Klartext; die Fehlerbeschreibung
            // hier **kann** einen enthalten — sie kommt aus dem SDK und trägt gelegentlich
            // IBAN oder Token im Text. Die Datei geht per Mail an uns.
            content += "=== Triggering error ===\n\(LogSanitizer.redact("\(error)"))\n\n"
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

        // 3. Hop auf den Hauptthread für Bank-Name + Store-Register.
        //
        // Auch hier `onMainRunLoop`: Diese Funktion läuft aus den Fehlerzweigen von
        // `fetchAccounts` und `fetchBalances` heraus, und die laufen während der
        // Ersteinrichtung — also unter `NSApp.runModal`. Ein gewöhnlicher Hop bliebe
        // liegen, und der Fehler, der gemeldet werden soll, käme nie beim Nutzer an.
        await onMainRunLoop {
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
    /// Liefert das eigene Freigabefenster, wenn eines geöffnet wurde — der Aufrufer
    /// schließt es nach dem Polling. `nil`: Safari übernimmt (Schalter aus, Sitzung
    /// nicht startbar, oder die Seite war für diesen Vorgang schon offen).
    @discardableResult
    private static func openRedirectURL(_ url: URL, vorgang: String, erwartetRueckleitung: Bool) async -> Freigabefenster? {
        guard await RedirectCoordinator.shared.darfOeffnen(vorgang: vorgang) else {
            AppLogger.log("SCA: Freigabe-Seite für diesen Vorgang bereits geöffnet — kein zweites Fenster",
                          category: "YaxiService")
            return nil
        }
        // Länge und Parameterzahl mitloggen, nicht die URL: Sie enthält Freigabe-Token.
        // Hintergrund (09/2026, ING): Safari zeigte „400 Request Header Or Cookie Too
        // Large" — nginx meldet das ab ~8 KB Request-Zeile plus Header. Ob die URL selbst
        // gewachsen ist oder der Cookie-Bestand des Nutzers, lässt sich damit im
        // Diagnosebericht unterscheiden.
        let queryParams = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.count ?? 0
        setupPhaseReporter?("sca_redirect_open", ["host": url.host ?? "?", "urlLength": "\(url.absoluteString.count)"])
        AppLogger.log("SCA: öffne Freigabe-Seite (host=\(url.host ?? "?"), länge=\(url.absoluteString.count), parameter=\(queryParams))", category: "YaxiService")
        // Ebenfalls `onMainRunLoop`: Diese Stelle liegt im selben Weg und würde denselben
        // Stillstand erzeugen, nur ein paar Zeilen später.
        let fenster: Freigabefenster? = await onMainRunLoop {
            guard Freigabefenster.aktiv else { return nil }
            let f = Freigabefenster()
            return f.oeffnen(url, erwartetRueckleitung: erwartetRueckleitung) ? f : nil
        }
        if fenster == nil {
            NSWorkspace.shared.open(url)
        }
        sendSCANotification()
        return fenster
    }

    /// Sagt Bescheid, **statt** eine Seite zu öffnen — und nennt die Bank beim Namen.
    ///
    /// Die alte Mitteilung kam erst **nach** dem Öffnen und lautete nur „Bitte im Browser
    /// bestätigen". Wer nicht wusste, dass simplebanking gerade einen Abruf gemacht
    /// hatte, sah einen Browser, der von selbst auf eine Bank-Anmeldung springt, und
    /// danach einen Hinweis, der die Bank nicht einmal benennt. Genau diese Reihenfolge
    /// hat ein Kunde am 01.10.2026 zu Recht als phishing-verdächtig gemeldet.
    private static func meldeFreigabeNoetig(slotId: String) async {
        let bank = await onMainRunLoop {
            MultibankingStore.shared.slots.first(where: { $0.id == slotId })?.displayName
        }
        let name = bank?.nilIfEmpty ?? L10n.t("Deine Bank", "Your bank")
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = L10n.t("\(name): neue Freigabe nötig", "\(name): new approval needed")
            content.body = L10n.t(
                "simplebanking ruft dieses Konto vorerst nicht mehr ab und hat nichts geöffnet. Öffne simplebanking und wähle \u{201E}Neu verbinden\u{201C}, wenn du die Freigabe erteilen willst.",
                "simplebanking has stopped fetching this account for now and opened nothing. Open simplebanking and choose \u{201C}Reconnect\u{201D} when you want to grant the approval.")
            content.sound = .default
            center.add(UNNotificationRequest(identifier: "freigabe-\(slotId)", content: content, trigger: nil))
        }
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
/// `BankRequestQueue` und `hbciSlotsInFlight` die meisten Bank-Aufrufe, aber nicht alle
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

    /// Vergisst alle Vorgänge dieses Kontos. Nötig nach einem Abbruch durch den Nutzer:
    /// Sonst schluckt die Frist von 290 Sekunden das Öffnen der neuen Seite, falls der
    /// nächste Anlauf auf dieselbe Fahrkarte trifft — der Nutzer klickt „Freigabe neu
    /// anstoßen" und bekommt wieder keinen Browser.
    func vergessen(slotId: String) {
        geoeffnet = geoeffnet.filter { !$0.key.hasPrefix("\(slotId)|") }
    }

    /// Alte Einträge verwerfen, damit die Tabelle nicht mit jedem Vorgang wächst.
    private func aufraeumen(jetzt: Date) {
        geoeffnet = geoeffnet.filter { jetzt.timeIntervalSince($0.value) < Self.frist }
    }

    #if DEBUG
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
