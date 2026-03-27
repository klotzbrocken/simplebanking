import Foundation

// MARK: - AIProvider

enum AIProvider: String, CaseIterable {
    case anthropic = "anthropic"
    case mistral   = "mistral"
    case openai    = "openai"

    static let storageKey = "selectedAIProvider"

    static var active: AIProvider {
        let raw = UserDefaults.standard.string(forKey: storageKey) ?? ""
        return AIProvider(rawValue: raw) ?? .anthropic
    }

    var displayName: String {
        switch self {
        case .anthropic: return "Anthropic"
        case .mistral:   return "Mistral"
        case .openai:    return "OpenAI"
        }
    }

    var keyPlaceholder: String {
        switch self {
        case .anthropic: return "sk-ant-..."
        case .mistral:   return "..."
        case .openai:    return "sk-..."
        }
    }
}

// MARK: - AIProviderService

enum AIProviderService {

    static let CATEGORIZATION_SYSTEM_PROMPT = """
    You are a transaction categorizer for a German banking app.
    You receive a JSON array of transactions. Each has: id, recipient, purpose, amount.
    Assign each transaction exactly one category key from this list: gastronomie, sparen, freizeit, gehalt, gesundheit, umbuchung, einkaufen, transport, versicherung, sonstiges.
    Rules:
    - gehalt: ONLY if amount is positive AND purpose/recipient matches income signals
    - umbuchung: ONLY if recipient name matches the account owner or looks like a self-transfer
    - sonstiges: use when no other category fits — never leave unassigned
    Return ONLY a valid JSON array: [{"id": "...", "category": "..."}]
    No explanation. No markdown. No extra keys.
    """

    static let QUERY_SYSTEM_PROMPT = """
    You are a personal finance assistant inside a German banking app called simplebanking.
    The user asks questions about their own transactions.
    You receive a JSON array of relevant transactions (recipient, purpose, amount, date, category) as context.
    Rules:
    - Answer only based on the provided transaction data — never invent figures
    - If the data does not contain enough information to answer, say so clearly
    - Respond always in German, informal (du)
    - Keep answers concise — max 4 sentences unless the user explicitly asks for detail
    - NEVER mention, repeat, or reference any IBAN, account number, BIC, or full legal name
    - Do not speculate about future transactions or balances
    """

    static func complete(
        provider: AIProvider,
        apiKey: String,
        systemPrompt: String,
        userMessage: String,
        maxTokens: Int = 500,
        temperature: Double = 0.2
    ) async throws -> String {
        switch provider {
        case .anthropic:
            return try await anthropicComplete(
                apiKey: apiKey, systemPrompt: systemPrompt, userMessage: userMessage,
                maxTokens: maxTokens, temperature: temperature)
        case .mistral:
            return try await openAICompatibleComplete(
                url: URL(string: "https://api.mistral.ai/v1/chat/completions")!,
                model: "mistral-small-latest",
                apiKey: apiKey, systemPrompt: systemPrompt, userMessage: userMessage,
                maxTokens: maxTokens, temperature: temperature)
        case .openai:
            return try await openAICompatibleComplete(
                url: URL(string: "https://api.openai.com/v1/chat/completions")!,
                model: "gpt-4o-mini",
                apiKey: apiKey, systemPrompt: systemPrompt, userMessage: userMessage,
                maxTokens: maxTokens, temperature: temperature)
        }
    }

    // MARK: - Anthropic

    private static func anthropicComplete(
        apiKey: String, systemPrompt: String, userMessage: String,
        maxTokens: Int, temperature: Double
    ) async throws -> String {
        let url = URL(string: "https://api.anthropic.com/v1/messages")!
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 45
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")

        struct Msg: Encodable { let role: String; let content: String }
        struct Payload: Encodable {
            let model: String; let max_tokens: Int; let temperature: Double
            let system: String; let messages: [Msg]
        }
        req.httpBody = try JSONEncoder().encode(Payload(
            model: "claude-3-5-haiku-latest", max_tokens: maxTokens,
            temperature: temperature, system: systemPrompt,
            messages: [Msg(role: "user", content: userMessage)]))

        let (data, response) = try await URLSession.shared.data(for: req)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            let body = String(data: data, encoding: .utf8) ?? "unknown"
            throw NSError(domain: "simplebanking.ai", code: http.statusCode,
                          userInfo: [NSLocalizedDescriptionKey: "Anthropic API Fehler (\(http.statusCode)): \(body)"])
        }
        struct Content: Decodable { let type: String; let text: String? }
        struct Resp: Decodable { let content: [Content] }
        let decoded = try JSONDecoder().decode(Resp.self, from: data)
        let text = decoded.content.filter { $0.type == "text" }.compactMap(\.text)
            .joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw LLMServiceError.emptyModelResponse }
        return text
    }

    // MARK: - OpenAI-compatible (Mistral + OpenAI share same format)

    private static func openAICompatibleComplete(
        url: URL, model: String, apiKey: String,
        systemPrompt: String, userMessage: String,
        maxTokens: Int, temperature: Double
    ) async throws -> String {
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 45
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        struct Msg: Encodable { let role: String; let content: String }
        struct Payload: Encodable {
            let model: String; let max_tokens: Int; let temperature: Double
            let messages: [Msg]
        }
        req.httpBody = try JSONEncoder().encode(Payload(
            model: model, max_tokens: maxTokens, temperature: temperature,
            messages: [Msg(role: "system", content: systemPrompt),
                       Msg(role: "user", content: userMessage)]))

        let (data, response) = try await URLSession.shared.data(for: req)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            let body = String(data: data, encoding: .utf8) ?? "unknown"
            throw NSError(domain: "simplebanking.ai", code: http.statusCode,
                          userInfo: [NSLocalizedDescriptionKey: "AI API Fehler (\(http.statusCode)): \(body)"])
        }
        struct Msg2: Decodable { let content: String? }
        struct Choice: Decodable { let message: Msg2 }
        struct Resp: Decodable { let choices: [Choice] }
        let decoded = try JSONDecoder().decode(Resp.self, from: data)
        let text = decoded.choices.first?.message.content?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !text.isEmpty else { throw LLMServiceError.emptyModelResponse }
        return text
    }
}
