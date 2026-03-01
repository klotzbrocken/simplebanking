import AppKit
import Foundation
import Routex

// MARK: - YaxiService
// Replaces NetworkService + BackendManager. Calls the YAXI API directly via
// routex-client-swift (Rust FFI). No Node.js process required.

enum YaxiService {

    // MARK: - UserDefaults keys

    static let ibanKey = "simplebanking.iban"
    private static let connectionIdKey = "simplebanking.yaxi.connectionId"
    private static let credModelFullKey = "simplebanking.yaxi.credModel.full"
    private static let credModelUserIdKey = "simplebanking.yaxi.credModel.userId"
    private static let credModelNoneKey = "simplebanking.yaxi.credModel.none"

    // MARK: - Session Store (same UserDefaults keys as the old NetworkService)

    static let sessionStore = SessionStore()

    actor SessionStore {
        private let defaults = UserDefaults.standard
        private let legacyKey = "simplebanking.yaxi.session"
        private let balancesKey = "simplebanking.yaxi.session.balances"
        private let transactionsKey = "simplebanking.yaxi.session.transactions"
        private let connectionDataKey = "simplebanking.yaxi.connectionData"

        private var balancesSession: Data?
        private var transactionsSession: Data?
        private var storedConnectionData: Data?

        init() {
            let legB64 = defaults.string(forKey: legacyKey)
            balancesSession = (defaults.string(forKey: balancesKey) ?? legB64)
                .flatMap { Data(base64Encoded: $0) }
            transactionsSession = (defaults.string(forKey: transactionsKey) ?? legB64)
                .flatMap { Data(base64Encoded: $0) }
            storedConnectionData = defaults.string(forKey: connectionDataKey)
                .flatMap { Data(base64Encoded: $0) }
        }

        func session(for scope: Scope) -> Data? {
            switch scope {
            case .balances:     return balancesSession ?? transactionsSession
            case .transactions: return transactionsSession ?? balancesSession
            }
        }

        func connectionData() -> Data? { storedConnectionData }

        func update(scope: Scope, session: Data?, connectionData: Data?) {
            if let s = session {
                switch scope {
                case .balances:
                    balancesSession = s
                    defaults.set(s.base64EncodedString(), forKey: balancesKey)
                case .transactions:
                    transactionsSession = s
                    defaults.set(s.base64EncodedString(), forKey: transactionsKey)
                }
            }
            if let cd = connectionData {
                storedConnectionData = cd
                defaults.set(cd.base64EncodedString(), forKey: connectionDataKey)
            }
        }

        func clearAll() {
            balancesSession = nil; transactionsSession = nil; storedConnectionData = nil
            defaults.removeObject(forKey: legacyKey)
            defaults.removeObject(forKey: balancesKey)
            defaults.removeObject(forKey: transactionsKey)
            defaults.removeObject(forKey: connectionDataKey)
        }

        func clearSessionsOnly() {
            balancesSession = nil; transactionsSession = nil
            defaults.removeObject(forKey: legacyKey)
            defaults.removeObject(forKey: balancesKey)
            defaults.removeObject(forKey: transactionsKey)
        }

        enum Scope { case balances, transactions }
    }

    // Throttle re-opening the bank redirect URL (< 290 s cooldown).
    private static nonisolated(unsafe) var lastRedirectOpenedAt: Date? = nil

    // MARK: - Public API

    /// Stores the IBAN and resets connection state (mirrors POST /config).
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

    static func fetchBalances(userId: String, password: String) async throws -> BalancesResponse {
        let d = UserDefaults.standard
        guard let connectionId = d.string(forKey: connectionIdKey), !connectionId.isEmpty else {
            return BalancesResponse(ok: false, booked: nil, expected: nil, session: nil,
                                   connectionData: nil, error: "no connectionId yet",
                                   userMessage: nil, scaRequired: nil)
        }
        let iban = d.string(forKey: ibanKey) ?? ""
        guard !iban.isEmpty else {
            return BalancesResponse(ok: false, booked: nil, expected: nil, session: nil,
                                   connectionData: nil, error: "missing iban",
                                   userMessage: nil, scaRequired: nil)
        }

        let model = loadCredentialsModel()
        let storedCD = await sessionStore.connectionData()
        let storedSession = await sessionStore.session(for: .balances)
        let creds = buildCredentials(
            connectionId: connectionId, model: model,
            connectionData: storedCD, userId: userId, password: password
        )

        let client = RoutexClient()
        let ticket = YaxiTicketMaker.issueTicket(service: "Balances")

        AppLogger.log("fetchBalances", category: "YaxiService")

        do {
            var resp: Routex.BalancesResponse
            do {
                resp = try await client.balances(
                    credentials: creds,
                    session: storedSession,
                    recurringConsents: true,
                    ticket: ticket,
                    accounts: [AccountReference(id: .iban(iban), currency: "EUR")]
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
                        accounts: [AccountReference(id: .iban(iban), currency: "EUR")]
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

            await sessionStore.update(scope: .balances,
                                      session: outcome.session,
                                      connectionData: outcome.connectionData)

            guard case .balances(let result) = outcome.payload else {
                return BalancesResponse(ok: false, booked: nil, expected: nil, session: nil,
                                       connectionData: nil, error: "unexpected result type",
                                       userMessage: nil, scaRequired: nil)
            }
            return makeBalancesResponse(result, session: outcome.session, connectionData: outcome.connectionData)

        } catch {
            await writeTrace(client: client, label: "fetchBalances", ticket: ticket, error: error)
            AppLogger.log("fetchBalances error: \(error.localizedDescription)", category: "YaxiService", level: "ERROR")
            if isConnectionResetError(error) {
                AppLogger.log("fetchBalances: clearing state after connection reset", category: "YaxiService")
                await sessionStore.clearAll()
            } else if isObsoleteSessionError(error) {
                AppLogger.log("fetchBalances: clearing sessions after obsolete session error", category: "YaxiService")
                await sessionStore.clearSessionsOnly()
            }
            throw error
        }
    }

    static func fetchTransactions(userId: String, password: String, from: String) async throws -> TransactionsResponse {
        let d = UserDefaults.standard
        guard let connectionId = d.string(forKey: connectionIdKey), !connectionId.isEmpty else {
            return TransactionsResponse(ok: false, transactions: nil, session: nil,
                                       connectionData: nil, error: "no connectionId yet",
                                       userMessage: nil, scaRequired: nil)
        }
        let iban = d.string(forKey: ibanKey) ?? ""
        guard !iban.isEmpty else {
            return TransactionsResponse(ok: false, transactions: nil, session: nil,
                                       connectionData: nil, error: "missing iban",
                                       userMessage: nil, scaRequired: nil)
        }

        let model = loadCredentialsModel()
        let storedCD = await sessionStore.connectionData()
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
                                      connectionData: outcome.connectionData)

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
                AppLogger.log("fetchTransactions: clearing state after connection reset", category: "YaxiService")
                await sessionStore.clearAll()
            } else if isObsoleteSessionError(error) {
                AppLogger.log("fetchTransactions: clearing sessions after obsolete session error", category: "YaxiService")
                await sessionStore.clearSessionsOnly()
            }
            throw error
        }
    }

    static func clearSessionState() async {
        await sessionStore.clearAll()
        AppLogger.log("Cleared YAXI session state", category: "YaxiService")
    }

    static func clearSessionsKeepingConnectionData() async {
        await sessionStore.clearSessionsOnly()
        AppLogger.log("Cleared YAXI sessions (connectionData preserved)", category: "YaxiService")
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

    private static func loadCredentialsModel() -> CredentialsModel {
        let d = UserDefaults.standard
        guard d.object(forKey: credModelFullKey) != nil else {
            return CredentialsModel(full: true, userId: true, none: false)
        }
        return CredentialsModel(
            full: d.bool(forKey: credModelFullKey),
            userId: d.bool(forKey: credModelUserIdKey),
            none: d.bool(forKey: credModelNoneKey)
        )
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
        let hasConnectionData = connectionData != nil

        var creds = Credentials(connectionId: connectionId, connectionData: connectionData)

        if let u, let p, (!model.none || hasConnectionData) {
            // Direct credential flow: send userId + password to YAXI.
            // For redirect-banks (none:true): only use direct credentials once we have connectionData
            // from a previous successful redirect — on first setup they must authenticate via browser.
            creds.userId = u
            creds.password = p
        } else if model.none {
            // Redirect bank, no connectionData yet — bank handles auth in browser, no credentials sent.
        } else if model.userId {
            creds.userId = u
            // Some banks (N26, DKB) report userId-only but still need the password for SCA.
            creds.password = p
        } else {
            creds.userId = u
            creds.password = p
        }

        return creds
    }

    // MARK: - Error classification (mirrors isConnectionResetError / isObsoleteSessionError)

    private static func isConnectionResetError(_ error: Error) -> Bool {
        guard let re = error as? RoutexClientError else { return false }
        switch re {
        case .Unauthorized, .ConsentExpired, .UnexpectedError: return true
        default: return false
        }
    }

    private static func isObsoleteSessionError(_ error: Error) -> Bool {
        let msg = error.localizedDescription.lowercased()
        return msg.contains("dialog-id ist nicht g") ||
            msg.contains("dialog abgebrochen") ||
            msg.contains("dialog-id is not valid") ||
            msg.contains("dialog cancelled")
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
        f.timeZone = TimeZone(identifier: "UTC") ?? .gmt
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
                AppLogger.log("SCA Confirmation: polling delay=\(pollingDelaySecs ?? 2)s", category: "YaxiService")
                return await pollConfirmation(
                    context: context,
                    delay: TimeInterval(pollingDelaySecs ?? 2),
                    client: client, ticket: ticket,
                    confirm: confirm, respond: respond, depth: depth
                )

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
            let result = await pollRedirect(context: context, client: client, ticket: ticket,
                                             confirm: confirm, respond: respond)
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
        var ctx = context
        var currentDelay = delay
        for i in 0..<60 {
            try? await Task.sleep(nanoseconds: UInt64(max(currentDelay, 1.0) * 1_000_000_000))
            do {
                let next = try await confirm(ctx)
                switch next {
                case .result:
                    return await handleSCA(initial: next, client: client, ticket: ticket,
                                           confirm: confirm, respond: respond, depth: depth + 1)
                case .dialog(let input):
                    if case .confirmation(let newCtx, let newDelay) = input {
                        ctx = newCtx
                        currentDelay = newDelay.map { TimeInterval($0) } ?? currentDelay
                        continue
                    }
                    return await handleSCA(initial: next, client: client, ticket: ticket,
                                           confirm: confirm, respond: respond, depth: depth + 1)
                default:
                    return await handleSCA(initial: next, client: client, ticket: ticket,
                                           confirm: confirm, respond: respond, depth: depth + 1)
                }
            } catch {
                AppLogger.log("SCA Confirmation poll \(i) failed: \(error.localizedDescription)", category: "YaxiService", level: "WARN")
                return nil
            }
        }
        AppLogger.log("SCA Confirmation: timeout (60 attempts)", category: "YaxiService", level: "WARN")
        return nil
    }

    private static func pollRedirect(
        context: ConfirmationContext,
        client: RoutexClient,
        ticket: Ticket,
        confirm: @escaping @Sendable (ConfirmationContext) async throws -> SCACommon,
        respond: @escaping @Sendable (InputContext, String) async throws -> SCACommon
    ) async -> SCAOutcome? {
        var ctx = context
        for _ in 0..<120 {
            try? await Task.sleep(nanoseconds: 5_000_000_000) // 5 s
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
                AppLogger.log("SCA Redirect poll failed: \(error.localizedDescription)", category: "YaxiService", level: "WARN")
                return nil
            }
        }
        AppLogger.log("SCA Redirect: timeout (120 × 5 s)", category: "YaxiService", level: "WARN")
        return nil
    }

    // MARK: - Trace

    /// Fetches the trace for the last client operation and writes it to
    /// ~/Library/Logs/simplebanking/yaxi-trace-<timestamp>-<label>.txt
    /// Always creates a file — even when no traceId is available — so that
    /// the call site can be confirmed and the triggering error is recorded.
    static func writeTrace(client: RoutexClient, label: String, ticket: Ticket, error: Error? = nil) async {
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
        let script = """
        display notification "Bitte im Browser bestätigen und danach zurückkehren." with title "Banking-Freigabe erforderlich" sound name "Ping"
        """
        let task = Process()
        task.launchPath = "/usr/bin/osascript"
        task.arguments = ["-e", script]
        try? task.run()
    }
}
