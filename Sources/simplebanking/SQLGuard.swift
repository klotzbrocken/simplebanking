import Foundation

enum SQLGuardError: LocalizedError {
    case empty
    case notSelect
    case multipleStatements
    case forbiddenKeyword(String)
    case forbiddenIdentifier(String)
    case tableNotAllowed
    case tooLong(Int)

    var errorDescription: String? {
        switch self {
        case .empty:
            return "Leere SQL-Abfrage."
        case .tooLong(let count):
            return "SQL-Abfrage zu lang (\(count) Zeichen)."
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

    /// Obergrenze für die Zeilenzahl — auch dann, wenn das SQL selbst ein `LIMIT`
    /// mitbringt.
    static let maxRowLimit = 1000

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

        let normalizedLimit = min(max(defaultLimit, 1), maxRowLimit)
        if containsWord("limit", in: lower) {
            // Ein vorhandenes LIMIT wurde bisher ungeprüft übernommen — `LIMIT 999999999`
            // passierte also, und der Deckel galt nur für Abfragen ganz ohne LIMIT.
            // Zu große Werte werden gekappt statt abgelehnt: der Nutzer bekommt lieber
            // eine (gedeckelte) Antwort als einen Fehler.
            candidate = cappingTrailingLimit(candidate, to: maxRowLimit)
        } else {
            candidate += " LIMIT \(normalizedLimit)"
        }

        return candidate
    }

    /// Ersetzt die Zahl eines abschließenden `LIMIT n` bzw. `LIMIT off, n` durch
    /// `min(n, cap)`. Greift nur am Ende des Statements — dort steht das effektive
    /// LIMIT eines SELECTs. Ein `LIMIT` in einer Unterabfrage bleibt unangetastet; es
    /// begrenzt ohnehin nur deren Zwischenergebnis, und das äußere LIMIT gilt weiterhin.
    private static func cappingTrailingLimit(_ sql: String, to cap: Int) -> String {
        let pattern = #"(?i)\blimit\s+(\d+)\s*(,\s*(\d+)\s*)?$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: sql, range: NSRange(sql.startIndex..., in: sql))
        else { return sql }

        // `LIMIT off, count` — die zweite Zahl ist die Zeilenzahl.
        let countGroup = match.range(at: 3).location != NSNotFound ? 3 : 1
        guard let countRange = Range(match.range(at: countGroup), in: sql),
              let value = Int(sql[countRange]), value > cap
        else { return sql }

        AppLogger.log("SQLGuard: LIMIT \(value) auf \(cap) gekappt", category: "LLM", level: "WARN")
        return sql.replacingCharacters(in: countRange, with: String(cap))
    }

    // MARK: - LLM-Query-Härtung (ERSTE von drei Schichten)
    //
    // Für LLM-**generiertes** SQL, dessen Ergebnis an einen externen KI-Anbieter geht.
    // Der System-Prompt ist keine Sicherheitsgrenze — diese Funktion aber auch nicht
    // allein: sie arbeitet auf Textmustern und kann nur prüfen, dass `llm_tx`
    // *vorkommt*, nicht dass es die *einzige* Quelle ist. Ein `JOIN`, eine CTE oder
    // eine Unterabfrage auf eine Fremdtabelle passiert hier.
    //
    // Die eigentliche Grenze ist deshalb die Ausführungsumgebung:
    //   1. HIER — Read-only-Form (kein `;`, Prefix `select`/`with`, keine
    //      schreibenden Keywords), LIMIT-Cap, verbotene Bezeichner.
    //   2. `TransactionsDatabase.executeLLMQuery` führt das SQL in einer isolierten
    //      In-Memory-DB aus, die AUSSCHLIESSLICH `llm_tx` enthält — Fremdtabellen
    //      existieren dort nicht, jeder Zugriff scheitert an „no such table".
    //   3. Redaktion der Ergebniszeilen (`llmRedactColumns`) vor dem Versand.
    //
    // Wer diese Prüfung erweitert, darf sich also nicht auf sie allein verlassen —
    // und wer die Sandbox anfasst, muss wissen, dass sie die tragende Schicht ist.
    static let llmAllowedTable = "llm_tx"
    static let llmForbiddenIdentifiers = ["transactions", "raw_json", "iban", "absender"]

    /// Längster akzeptierter SQL-Text aus dem Modell. Fängt entartete Antworten ab,
    /// bevor SQLite sie überhaupt parst.
    ///
    /// Bewusst NUR auf diesem Pfad und nicht in `validatedReadOnlySQL`: die
    /// regelbasierten Pläne der App gehen dort ebenfalls durch, und die kommen mit
    /// ihren langen Stichwortlisten auf über 10 000 Zeichen. Sie sind handgeschrieben,
    /// die Grenze gehört dorthin, wo die Eingabe fremd ist.
    static let maxSQLLength = 4000

    static func validatedLLMQuery(_ sql: String, defaultLimit: Int = 200) throws -> String {
        guard sql.count <= maxSQLLength else {
            throw SQLGuardError.tooLong(sql.count)
        }
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
