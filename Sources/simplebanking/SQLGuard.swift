import Foundation

enum SQLGuardError: LocalizedError {
    case empty
    case notSelect
    case multipleStatements
    case forbiddenKeyword(String)
    case forbiddenIdentifier(String)
    case tableNotAllowed

    var errorDescription: String? {
        switch self {
        case .empty:
            return "Leere SQL-Abfrage."
        case .notSelect:
            return "Nur SELECT-Abfragen sind erlaubt."
        case .multipleStatements:
            return "Nur ein einzelnes SQL-Statement ist erlaubt."
        case .forbiddenKeyword(let keyword):
            return "Nicht erlaubtes SQL-Schlüsselwort: \(keyword)."
        case .forbiddenIdentifier(let ident):
            return "Nicht erlaubte Spalte/Tabelle: \(ident)."
        case .tableNotAllowed:
            return "Nur Abfragen auf die Sicht `llm_tx` sind erlaubt."
        }
    }
}

enum SQLGuard {
    private static let forbiddenKeywords: [String] = [
        "insert", "update", "delete", "drop", "alter", "create", "attach",
        "detach", "pragma", "vacuum", "replace", "reindex", "truncate",
        "grant", "revoke",
    ]

    static func validatedReadOnlySQL(_ sql: String, defaultLimit: Int = 200) throws -> String {
        var candidate = stripMarkdownCodeFence(sql)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !candidate.isEmpty else {
            throw SQLGuardError.empty
        }

        if candidate.hasSuffix(";") {
            candidate.removeLast()
            candidate = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        guard !candidate.contains(";") else {
            throw SQLGuardError.multipleStatements
        }

        let lower = candidate.lowercased()
        guard lower.hasPrefix("select") || lower.hasPrefix("with") else {
            throw SQLGuardError.notSelect
        }

        for keyword in forbiddenKeywords {
            if containsWord(keyword, in: lower) {
                throw SQLGuardError.forbiddenKeyword(keyword.uppercased())
            }
        }

        let normalizedLimit = min(max(defaultLimit, 1), 1000)
        if !containsWord("limit", in: lower) {
            candidate += " LIMIT \(normalizedLimit)"
        }

        return candidate
    }

    // MARK: - LLM-Query-Härtung
    //
    // Für LLM-**generiertes** SQL, dessen Ergebnis an einen externen KI-Anbieter
    // geht: zusätzlich zur Read-Only-Prüfung eine harte Tabellen-/Spalten-Grenze.
    // Der System-Prompt ist KEINE Sicherheitsgrenze — hier wird erzwungen, dass nur
    // die minimierte, slot-gefilterte Sicht `llm_tx` abgefragt werden kann und
    // sensible Bezeichner (IBAN, Rohdaten, Absender, Basistabelle) nie vorkommen.
    static let llmAllowedTable = "llm_tx"
    static let llmForbiddenIdentifiers = ["transactions", "raw_json", "iban", "absender"]

    static func validatedLLMQuery(_ sql: String, defaultLimit: Int = 200) throws -> String {
        let base = try validatedReadOnlySQL(sql, defaultLimit: defaultLimit)
        let lower = base.lowercased()
        for ident in llmForbiddenIdentifiers where containsWord(ident, in: lower) {
            throw SQLGuardError.forbiddenIdentifier(ident.uppercased())
        }
        guard containsWord(llmAllowedTable, in: lower) else {
            throw SQLGuardError.tableNotAllowed
        }
        return base
    }

    private static func containsWord(_ word: String, in text: String) -> Bool {
        let pattern = "\\b" + NSRegularExpression.escapedPattern(for: word) + "\\b"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return false
        }
        let range = NSRange(location: 0, length: text.utf16.count)
        return regex.firstMatch(in: text, options: [], range: range) != nil
    }

    private static func stripMarkdownCodeFence(_ input: String) -> String {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("```"), trimmed.hasSuffix("```") else {
            return input
        }

        var lines = trimmed.split(separator: "\n", omittingEmptySubsequences: false)
        if !lines.isEmpty {
            lines.removeFirst()
        }
        if !lines.isEmpty {
            lines.removeLast()
        }
        return lines.joined(separator: "\n")
    }
}
