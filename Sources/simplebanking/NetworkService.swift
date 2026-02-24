import Foundation

enum NetworkService {
    private static let backendPortKey = "simplebanking.backendPort.\(ProcessInfo.processInfo.processIdentifier)"
    private static let legacyBackendPortKey = "simplebanking.backendPort"
    private static let sessionStore = SessionStore()
    // Process-local cache set during app startup by BackendManager.
    // Safe in this app because value is monotonic-write during bootstrap.
    private static nonisolated(unsafe) var runtimeBackendPort: Int?
    
    private enum SessionScope: String {
        case balances
        case transactions
    }
    
    private struct SessionDebugSnapshot {
        let sessionLength: Int
        let connectionDataLength: Int
    }

    private actor SessionStore {
        private let defaults = UserDefaults.standard
        private let legacySessionKey = "simplebanking.yaxi.session"
        private let balancesSessionKey = "simplebanking.yaxi.session.balances"
        private let transactionsSessionKey = "simplebanking.yaxi.session.transactions"
        private let connectionDataKey = "simplebanking.yaxi.connectionData"

        private var balancesSession: String?
        private var transactionsSession: String?
        private var connectionData: String?

        init() {
            let legacySession = defaults.string(forKey: legacySessionKey)
            balancesSession = defaults.string(forKey: balancesSessionKey) ?? legacySession
            transactionsSession = defaults.string(forKey: transactionsSessionKey) ?? legacySession
            connectionData = defaults.string(forKey: connectionDataKey)

            if let balancesSession, defaults.string(forKey: balancesSessionKey) == nil {
                defaults.set(balancesSession, forKey: balancesSessionKey)
            }
            if let transactionsSession, defaults.string(forKey: transactionsSessionKey) == nil {
                defaults.set(transactionsSession, forKey: transactionsSessionKey)
            }
            defaults.removeObject(forKey: legacySessionKey)
        }

        func requestBody(userId: String, password: String, from: String?, scope: SessionScope) -> [String: String] {
            var body: [String: String] = [
                "userId": userId,
                "password": password,
            ]
            if let from {
                body["from"] = from
            }
            if let session = session(for: scope), !session.isEmpty {
                body["session"] = session
            }
            if let connectionData, !connectionData.isEmpty {
                body["connectionData"] = connectionData
            }
            return body
        }

        func update(scope: SessionScope, session: String?, connectionData: String?) {
            if let session, !session.isEmpty {
                setSession(session, for: scope)
            }
            if let connectionData, !connectionData.isEmpty {
                self.connectionData = connectionData
                defaults.set(connectionData, forKey: connectionDataKey)
            }
        }

        func clearAllSessionsKeepingConnectionData() {
            balancesSession = nil
            transactionsSession = nil
            defaults.removeObject(forKey: legacySessionKey)
            defaults.removeObject(forKey: balancesSessionKey)
            defaults.removeObject(forKey: transactionsSessionKey)
        }

        func clearAll() {
            balancesSession = nil
            transactionsSession = nil
            connectionData = nil
            defaults.removeObject(forKey: legacySessionKey)
            defaults.removeObject(forKey: balancesSessionKey)
            defaults.removeObject(forKey: transactionsSessionKey)
            defaults.removeObject(forKey: connectionDataKey)
        }
        
        func debugSnapshot(for scope: SessionScope) -> SessionDebugSnapshot {
            let scopedSession = session(for: scope) ?? ""
            let scopedConnectionData = connectionData ?? ""
            return SessionDebugSnapshot(
                sessionLength: scopedSession.count,
                connectionDataLength: scopedConnectionData.count
            )
        }

        private func session(for scope: SessionScope) -> String? {
            switch scope {
            case .balances:
                return balancesSession ?? transactionsSession
            case .transactions:
                return transactionsSession ?? balancesSession
            }
        }

        private func setSession(_ value: String?, for scope: SessionScope) {
            switch scope {
            case .balances:
                balancesSession = value
                if let value {
                    defaults.set(value, forKey: balancesSessionKey)
                } else {
                    defaults.removeObject(forKey: balancesSessionKey)
                }
            case .transactions:
                transactionsSession = value
                if let value {
                    defaults.set(value, forKey: transactionsSessionKey)
                } else {
                    defaults.removeObject(forKey: transactionsSessionKey)
                }
            }
        }
    }

    private enum SessionResetAction {
        case none
        case sessionOnly
        case full
        
        var debugLabel: String {
            switch self {
            case .none:
                return "none"
            case .sessionOnly:
                return "session_only"
            case .full:
                return "full"
            }
        }
    }

    private static var backendPort: Int {
        if let runtimeBackendPort, runtimeBackendPort > 0 {
            return runtimeBackendPort
        }
        let value = UserDefaults.standard.integer(forKey: backendPortKey)
        if value > 0 {
            return value
        }
        let legacyValue = UserDefaults.standard.integer(forKey: legacyBackendPortKey)
        return legacyValue > 0 ? legacyValue : 8787
    }

    private static var baseURL: URL {
        URL(string: "http://127.0.0.1:\(backendPort)")!
    }

    static func setBackendPort(_ port: Int) {
        guard port > 0 else { return }
        runtimeBackendPort = port
        UserDefaults.standard.set(port, forKey: backendPortKey)
        // Keep legacy key for cross-build compatibility/fallback.
        UserDefaults.standard.set(port, forKey: legacyBackendPortKey)
    }

    static func clearSessionState() async {
        await sessionStore.clearAll()
        await debugLog(scope: .balances, phase: "clear_all")
        await debugLog(scope: .transactions, phase: "clear_all")
        AppLogger.log("Cleared YAXI session state", category: "Network")
    }

    /// Löscht nur Session-Tokens, behält connectionData.
    /// Für Setup-Retries: connectionData enthält die Gerätebindung,
    /// ohne die die Bank keinen Push-TAN schickt.
    static func clearSessionsKeepingConnectionData() async {
        await sessionStore.clearAllSessionsKeepingConnectionData()
        await debugLog(scope: .balances, phase: "clear_sessions_keep_connectiondata")
        await debugLog(scope: .transactions, phase: "clear_sessions_keep_connectiondata")
        AppLogger.log("Cleared YAXI sessions (connectionData preserved)", category: "Network")
    }

    static func debugBackendURLString() -> String {
        baseURL.absoluteString
    }

    static func isBackendUp() async -> Bool {
        var req = URLRequest(url: baseURL.appending(path: "health"))
        req.timeoutInterval = 2
        do {
            let (_, response) = try await URLSession.shared.data(for: req)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }

    static func waitUntilBackendUp(maxWaitSeconds: TimeInterval = 12, pollIntervalMillis: UInt64 = 300) async -> Bool {
        let start = Date()
        while Date().timeIntervalSince(start) < maxWaitSeconds {
            if await isBackendUp() {
                return true
            }
            try? await Task.sleep(nanoseconds: pollIntervalMillis * 1_000_000)
        }
        return false
    }

    static func fetchBalances(userId: String, password: String) async throws -> BalancesResponse {
        try await fetchBalances(userId: userId, password: password, allowRetry: true)
    }

    static func fetchTransactions(userId: String, password: String, from: String) async throws -> TransactionsResponse {
        try await fetchTransactions(userId: userId, password: password, from: from, allowRetry: true)
    }

    static func configureBackend(iban: String) async -> Bool {
        var req = URLRequest(url: baseURL.appending(path: "config"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 15
        req.httpBody = try? JSONSerialization.data(withJSONObject: [
            "iban": iban,
            "currency": "EUR",
        ])

        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            AppLogger.log(
                "POST /config status=\(status) body=\(responsePreview(data))",
                category: "Network"
            )
            let ok = status == 200
            if ok {
                await sessionStore.clearAll()
            } else {
                AppLogger.log("POST /config failed status=\(status)", category: "Network", level: "WARN")
            }
            return ok
        } catch {
            AppLogger.log("POST /config failed: \(error.localizedDescription)", category: "Network", level: "ERROR")
            return false
        }
    }

    static func discoverBank() async -> DiscoveredBank? {
        var req = URLRequest(url: baseURL.appending(path: "discover"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 30
        req.httpBody = try? JSONSerialization.data(withJSONObject: [:])

        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            AppLogger.log(
                "POST /discover status=\(status) body=\(responsePreview(data))",
                category: "Network"
            )

            guard status == 200 else {
                AppLogger.log("POST /discover failed status=\(status)", category: "Network", level: "WARN")
                return nil
            }
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let picked = json["picked"] as? [String: Any],
                  let name = picked["displayName"] as? String else {
                AppLogger.log("POST /discover parse failed: missing picked/displayName", category: "Network", level: "WARN")
                if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let error = json["error"] as? String {
                    AppLogger.log("POST /discover backend error: \(error)", category: "Network", level: "WARN")
                }
                return nil
            }
            let credentialsModel: DiscoveredBankCredentials? = {
                guard let credentials = picked["credentials"] as? [String: Any] else { return nil }
                func boolValue(_ keys: [String]) -> Bool {
                    for key in keys {
                        if let value = credentials[key] as? Bool {
                            return value
                        }
                    }
                    return false
                }
                return DiscoveredBankCredentials(
                    full: boolValue(["full", "Full"]),
                    userId: boolValue(["userId", "userID", "UserId"]),
                    none: boolValue(["none", "None"])
                )
            }()
            let userIdLabel = (picked["userId"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let advice = (picked["advice"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            return DiscoveredBank(
                id: picked["id"] as? String,
                displayName: name,
                logoId: picked["logoId"] as? String,
                credentials: credentialsModel,
                userIdLabel: (userIdLabel?.isEmpty == false) ? userIdLabel : nil,
                advice: (advice?.isEmpty == false) ? advice : nil
            )
        } catch {
            AppLogger.log("POST /discover failed: \(error.localizedDescription)", category: "Network", level: "ERROR")
            return nil
        }
    }

    private static func responsePreview(_ data: Data, limit: Int = 500) -> String {
        guard !data.isEmpty else { return "<empty>" }
        guard let text = String(data: data, encoding: .utf8) else {
            return "<\(data.count) bytes binary>"
        }
        if text.count <= limit {
            return text
        }
        let idx = text.index(text.startIndex, offsetBy: limit)
        return text[text.startIndex..<idx] + "…"
    }

    private static func fetchBalances(userId: String, password: String, allowRetry: Bool) async throws -> BalancesResponse {
        let body = await sessionStore.requestBody(userId: userId, password: password, from: nil, scope: .balances)
        AppLogger.log("POST /balances (retry=\(!allowRetry), hasSession=\(body["session"] != nil), hasConnectionData=\(body["connectionData"] != nil))", category: "Network")
        await debugLog(
            scope: .balances,
            phase: allowRetry ? "request" : "request_retry",
            includeSessionInRequest: body["session"] != nil,
            includeConnectionDataInRequest: body["connectionData"] != nil
        )
        let data = try await postJSON(path: "balances", timeout: 120, body: body)
        let response = try JSONDecoder().decode(BalancesResponse.self, from: data)
        AppLogger.log("Response /balances ok=\(response.ok) error=\(response.error ?? "-")", category: "Network")
        await sessionStore.update(scope: .balances, session: response.session, connectionData: response.connectionData)
        await debugLog(
            scope: .balances,
            phase: allowRetry ? "response" : "response_retry",
            ok: response.ok,
            error: response.error
        )

        let resetAction = sessionResetAction(for: response.error)
        if allowRetry, resetAction != .none {
            await debugLog(scope: .balances, phase: "reset_\(resetAction.debugLabel)")
            await apply(resetAction: resetAction, scope: .balances)
            return try await fetchBalances(userId: userId, password: password, allowRetry: false)
        }
        return response
    }

    private static func fetchTransactions(userId: String, password: String, from: String, allowRetry: Bool) async throws -> TransactionsResponse {
        let body = await sessionStore.requestBody(userId: userId, password: password, from: from, scope: .transactions)
        AppLogger.log("POST /transactions from=\(from) (retry=\(!allowRetry), hasSession=\(body["session"] != nil), hasConnectionData=\(body["connectionData"] != nil))", category: "Network")
        await debugLog(
            scope: .transactions,
            phase: allowRetry ? "request" : "request_retry",
            includeSessionInRequest: body["session"] != nil,
            includeConnectionDataInRequest: body["connectionData"] != nil
        )
        let data = try await postJSON(path: "transactions", timeout: 90, body: body)
        let response = try JSONDecoder().decode(TransactionsResponse.self, from: data)
        AppLogger.log("Response /transactions ok=\(response.ok ?? false) error=\(response.error ?? "-") count=\(response.transactions?.count ?? 0)", category: "Network")
        await sessionStore.update(scope: .transactions, session: response.session, connectionData: response.connectionData)
        await debugLog(
            scope: .transactions,
            phase: allowRetry ? "response" : "response_retry",
            ok: response.ok ?? false,
            error: response.error
        )

        let resetAction = sessionResetAction(for: response.error)
        if allowRetry, resetAction != .none {
            await debugLog(scope: .transactions, phase: "reset_\(resetAction.debugLabel)")
            await apply(resetAction: resetAction, scope: .transactions)
            return try await fetchTransactions(userId: userId, password: password, from: from, allowRetry: false)
        }
        return response
    }

    private static func postJSON(path: String, timeout: TimeInterval, body: [String: String]) async throws -> Data {
        var req = URLRequest(url: baseURL.appending(path: path))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = timeout
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, _) = try await URLSession.shared.data(for: req)
        return data
    }

    private static func sessionResetAction(for errorText: String?) -> SessionResetAction {
        let normalized = (errorText ?? "").lowercased()
        guard !normalized.isEmpty else { return .none }

        // YAXI Unauthorized = "Invalid consent." Only happens when stale connectionData is
        // passed with recurringConsents. Fix: clear all (incl. connectionData) and retry.
        if normalized.hasPrefix("unauthorized") {
            return .full
        }

        // Präzise YAXI-spezifische Session-Fehler → nur Session zurücksetzen
        if normalized.contains("dialog-id ist nicht") ||
            normalized.contains("dialog-id is not") ||
            normalized.contains("dialog abgebrochen") ||
            normalized.contains("session expired") ||
            normalized.contains("session abgelaufen") ||
            normalized.contains("ungültige session") ||
            normalized.contains("invalid session") {
            return .sessionOnly
        }

        // Verbindungsdaten ungültig oder Session-Format unbekannt → vollständiger Reset nötig
        if normalized.contains("connectiondata") ||
            normalized.contains("connection data") ||
            normalized.contains("consent") ||
            normalized.contains("unsupported session") {
            return .full
        }

        return .none
    }

    private static func apply(resetAction: SessionResetAction, scope _: SessionScope) async {
        switch resetAction {
        case .none:
            return
        case .sessionOnly:
            // Clear both scoped sessions so retry does not fall back to stale session from the other scope.
            await sessionStore.clearAllSessionsKeepingConnectionData()
            await debugLog(scope: .balances, phase: "cleared_all_sessions_keep_connectiondata")
            await debugLog(scope: .transactions, phase: "cleared_all_sessions_keep_connectiondata")
        case .full:
            await sessionStore.clearAll()
            await debugLog(scope: .balances, phase: "cleared_all")
            await debugLog(scope: .transactions, phase: "cleared_all")
        }
    }

    #if DEBUG
    private static func debugLog(
        scope: SessionScope,
        phase: String,
        includeSessionInRequest: Bool? = nil,
        includeConnectionDataInRequest: Bool? = nil,
        ok: Bool? = nil,
        error: String? = nil
    ) async {
        let snapshot = await sessionStore.debugSnapshot(for: scope)
        var parts: [String] = [
            "[YAXI][Session]",
            "scope=\(scope.rawValue)",
            "phase=\(phase)",
            "storedSessionLen=\(snapshot.sessionLength)",
            "storedConnectionDataLen=\(snapshot.connectionDataLength)",
        ]
        if let includeSessionInRequest {
            parts.append("reqSession=\(includeSessionInRequest)")
        }
        if let includeConnectionDataInRequest {
            parts.append("reqConnectionData=\(includeConnectionDataInRequest)")
        }
        if let ok {
            parts.append("ok=\(ok)")
        }
        if let error, !error.isEmpty {
            parts.append("error=\(error)")
        }
        print(parts.joined(separator: " "))
    }
    #else
    private static func debugLog(
        scope _: SessionScope,
        phase _: String,
        includeSessionInRequest _: Bool? = nil,
        includeConnectionDataInRequest _: Bool? = nil,
        ok _: Bool? = nil,
        error _: String? = nil
    ) async {
    }
    #endif
}
