import Foundation

// MARK: - TransferClipboardParser
//
// Erkennt Überweisungsdaten (Name, IBAN, Betrag, Verwendungszweck) in einem beliebig
// kopierten Textblock — Rechnung, Mail, Zahlungsaufforderung. Reine Funktion, testbar
// ohne Pasteboard/UI.
//
// Wird von ZWEI Wegen genutzt: der Zwischenablage-Erkennung im TransferSheet und dem
// PDF/Bild-Import (OCR-Text landet im selben Parser).
//
// Kein Logging — der Inhalt kann sensibel sein (wie beim IbanClipboardScanner).

enum TransferClipboardParser {

    struct Parsed: Equatable {
        var name: String?
        var iban: String?
        /// Deutsches Eingabeformat, z.B. "1234,56" (die Felder/Validierung akzeptieren
        /// Komma wie Punkt).
        var amount: String?
        var purpose: String?

        var isEmpty: Bool { name == nil && iban == nil && amount == nil && purpose == nil }
        /// Genug erkannt, um dem Nutzer ein Übernehmen anzubieten.
        var isUseful: Bool { iban != nil || (name != nil && amount != nil) }
    }

    // Label-Varianten (klein geschrieben, Teilstring-Match).
    private static let nameLabels = [
        "empfänger", "empfaenger", "zahlungsempfänger", "zahlungsempfaenger",
        "kontoinhaber", "begünstigter", "beguenstigter", "beneficiary",
        "payee", "recipient", "name"
    ]
    private static let amountLabels = [
        "rechnungsbetrag", "gesamtbetrag", "zahlbetrag", "betrag", "summe",
        "zu zahlen", "total", "amount"
    ]
    private static let purposeLabels = [
        "verwendungszweck", "betreff", "referenz", "reference", "zweck",
        "subject", "rechnungsnummer", "rechnung nr", "invoice"
    ]
    /// „Gesamtbetrag"-Marker — stehen auf Rechnungen oft OHNE Doppelpunkt am
    /// Zeilenanfang („Rechnungsbetrag 1.612"). Schlagen jede andere Betragszeile.
    private static let totalMarkers = [
        "rechnungsbetrag", "gesamtbetrag", "zahlbetrag", "endbetrag",
        "gesamtsumme", "zu zahlen", "total", "summe"
    ]
    /// Zeilen, die trotz „viel Text" kein Name sind (Grußformeln, Bank-/Meta-Zeilen).
    private static let nameStopwords = [
        "grüß", "gruss", "dank", "rechnung", "betrag", "konto", "bank", "iban", "bic",
        "datum", "seite", "steuernummer", "ust", "e-mail", "email", "telefon", "tel.",
        "sparkasse", "volksbank", "überweisung", "ueberweisung", "zahlung", "auftrag"
    ]

    // MARK: - Entry point

    static func parse(_ text: String) -> Parsed {
        var out = Parsed()
        out.iban = IbanClipboardScanner.extractIban(from: text)

        let lines = text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        var unlabelled: [String] = []
        for line in lines {
            guard let (label, value) = splitLabel(line), !value.isEmpty else {
                unlabelled.append(line)
                continue
            }
            if out.name == nil, matches(label, nameLabels) {
                out.name = cleanName(trimAtBankMarkers(value)); continue
            }
            if out.amount == nil, matches(label, amountLabels), let a = amount(in: value) {
                out.amount = a; continue
            }
            if out.purpose == nil, matches(label, purposeLabels) {
                out.purpose = value; continue
            }
            // Gelabelt, aber für uns irrelevant (z.B. "Datum: …") → nicht als Name raten.
        }

        // Betrag ohne Label. Reihenfolge ist entscheidend: bei Rechnungen gewinnt sonst
        // eine Positionszeile („280 km x 0,40 EUR") oder eine Nummer (PLZ, Kundennr.).
        if out.amount == nil {
            out.amount = totalAmount(in: lines) ?? largestMoneyAmount(in: lines)
        }

        // Name: Zahlungsempfänger ist, wem die IBAN gehört. Deshalb ZUERST um die IBAN
        // herum suchen (Signatur/Kontoinhaber). Erst danach der Briefkopf (Aussteller) —
        // der Adressblock darunter wäre der ZAHLER und darf nie gewinnen.
        if out.name == nil, let iban = out.iban,
           let ibanIdx = lines.firstIndex(where: { IbanClipboardScanner.extractIban(from: $0) == iban }) {
            out.name = nearestName(around: ibanIdx, in: lines, iban: iban).map(cleanName)
        }
        if out.name == nil {
            out.name = lines.prefix(6).first { isLikelyName($0, iban: out.iban) }.map(cleanName)
        }
        if out.name == nil {
            out.name = unlabelled.first { isLikelyName($0, iban: out.iban) }.map(cleanName)
        }

        return out
    }

    /// Betrag an einem Gesamtbetrag-Marker. PDF-Tabellen trennen Label und Wert oft auf
    /// verschiedene Zeilen („Rechnungsbetrag:" / später „1.234,56"), daher wird bei
    /// leerem Marker-Text in den nächsten Zeilen weitergesucht.
    private static func totalAmount(in lines: [String]) -> String? {
        var candidates: [String] = []
        for (idx, line) in lines.enumerated() {
            let l = line.lowercased()
            guard totalMarkers.contains(where: { l.contains($0) }) else { continue }
            if let a = amount(in: line) { candidates.append(a); continue }
            for look in 1...3 where lines.indices.contains(idx + look) {
                let next = lines[idx + look]
                guard !looksLikeMetaLine(next),
                      IbanClipboardScanner.extractIban(from: next) == nil else { continue }
                if let a = amount(in: next), isMoneyLike(a, line: next) { candidates.append(a); break }
            }
        }
        // „Betrag"/„Restbetrag"/„Gesamtbetrag" kommen mehrfach vor (Positionen,
        // Zwischensummen). Der Gesamtbetrag ist der größte davon.
        return candidates.max { numericValue($0) < numericValue($1) }
    }

    /// Größter „geldartiger" Betrag. Ohne die Geld-Prüfung würden Kundennummern,
    /// Rechnungsnummern oder PLZ (57072!) als Betrag gewinnen.
    private static func largestMoneyAmount(in lines: [String]) -> String? {
        lines
            .filter { !looksLikeMetaLine($0) }
            // IBAN-Zeilen liefern nur Ziffernblöcke („DE89 3704 …" → 89370).
            .filter { IbanClipboardScanner.extractIban(from: $0) == nil }
            .compactMap { line -> String? in
                guard let a = amount(in: line), isMoneyLike(a, line: line) else { return nil }
                return a
            }
            .max { numericValue($0) < numericValue($1) }
    }

    /// Geld erkennt man an Nachkommastellen ODER an einer Währungsangabe in der Zeile.
    /// Blanke Ganzzahlen sind auf Rechnungen meist Nummern, keine Beträge.
    private static func isMoneyLike(_ normalized: String, line: String) -> Bool {
        if normalized.contains(",") { return true }
        let l = line.lowercased()
        return l.contains("€") || l.contains("eur")
    }

    /// Sucht die nächstgelegene namensartige Zeile um `index` (erst danach, dann davor) —
    /// bei Rechnungen steht der Kontoinhaber direkt bei den Bankdaten bzw. in der Signatur.
    private static func nearestName(around index: Int, in lines: [String], iban: String) -> String? {
        let window = 4
        for distance in 1...window {
            for candidate in [index + distance, index - distance] where lines.indices.contains(candidate) {
                if isLikelyName(lines[candidate], iban: iban) { return lines[candidate] }
            }
        }
        return nil
    }

    /// Adress-/Nummern-/Datumszeilen, aus denen kein Betrag stammen darf
    /// (PLZ „70565 Stuttgart", „Steuernummer 342/5158/2760", Daten).
    private static func looksLikeMetaLine(_ line: String) -> Bool {
        let l = line.lowercased()
        if l.contains("steuernummer") || l.contains("ust-id") || l.contains("telefon") { return true }
        if line.contains("/") && line.filter(\.isNumber).count >= 6 { return true }   // Steuernr./Datum
        // PLZ + Ort: 5 Ziffern gefolgt von Buchstaben, sonst kaum Zahlen.
        if let re = try? NSRegularExpression(pattern: #"^\d{5}\s+\p{L}"#),
           re.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil { return true }
        return false
    }

    /// Numerischer Wert eines normalisierten Betrags ("1234,56" → 1234.56) zum Vergleichen.
    private static func numericValue(_ normalized: String) -> Double {
        Double(normalized.replacingOccurrences(of: ",", with: ".")) ?? 0
    }

    // MARK: - Helpers

    private static func matches(_ label: String, _ candidates: [String]) -> Bool {
        candidates.contains { label.contains($0) }
    }

    /// Stoppwort-Treffer nur am WORTANFANG. Plain `contains` wäre fatal: „ust"
    /// (für USt-ID) steckt in „M-ust-ermann", „bank" in „Musterbank" — echte Namen
    /// würden verworfen. Prefix-Match an der Wortgrenze trifft weiterhin
    /// „USt-ID", „Grüßen", „IBAN …".
    private static func containsStopword(_ line: String) -> Bool {
        let lower = line.lowercased()
        for word in nameStopwords {
            let pattern = #"\b"# + NSRegularExpression.escapedPattern(for: word)
            guard let re = try? NSRegularExpression(pattern: pattern) else { continue }
            if re.firstMatch(in: lower, range: NSRange(lower.startIndex..., in: lower)) != nil {
                return true
            }
        }
        return false
    }

    /// Zerlegt "Label: Wert" (auch mit mehreren Doppelpunkten im Wert).
    private static func splitLabel(_ line: String) -> (label: String, value: String)? {
        guard let idx = line.firstIndex(of: ":") else { return nil }
        let label = line[..<idx].trimmingCharacters(in: .whitespaces).lowercased()
        let value = line[line.index(after: idx)...].trimmingCharacters(in: .whitespaces)
        guard !label.isEmpty, label.count <= 40 else { return nil }
        return (label, value)
    }

    private static func cleanName(_ raw: String) -> String {
        raw.trimmingCharacters(in: CharacterSet(charactersIn: " \t-–—•*.:,;"))
    }

    /// Schneidet einen Label-Wert vor den Bankdaten ab. Rechnungen packen hinter
    /// „Kontoinhaber:" gern die ganze Bankzeile
    /// („… GmbH - Commerzbank AG Hagen . BIC: … IBAN: …") — davon ist nur der
    /// Kontoinhaber der Name.
    private static func trimAtBankMarkers(_ value: String) -> String {
        var result = value
        for marker in [" - ", " – ", "BIC", "IBAN", "SWIFT", "Kto", "Konto-Nr"] {
            if let r = result.range(of: marker, options: .caseInsensitive) {
                result = String(result[..<r.lowerBound])
            }
        }
        return result
    }

    /// Sieht die Zeile nach einem Personen-/Firmennamen aus?
    private static func isLikelyName(_ line: String, iban: String?) -> Bool {
        let compact = line.replacingOccurrences(of: " ", with: "").uppercased()
        if let iban, compact.contains(iban) { return false }
        if IbanClipboardScanner.extractIban(from: line) != nil { return false }
        // Grußformeln, Bank- und Meta-Zeilen sind keine Namen.
        if containsStopword(line) { return false }
        let lower = line.lowercased()
        // Bank-Bezeichner auch INNERHALB eines Wortes ("Südwestbank") — in Rechnungen
        // steht neben der IBAN fast immer das Institut, nie der Zahlungsempfänger.
        if ["bank", "sparkasse", "iban", "bic", "swift"].contains(where: { lower.contains($0) }) { return false }
        // Betrags-/Summenzeilen ("Gesamtbetrag 479,52") sind keine Namen.
        if totalMarkers.contains(where: { lower.contains($0) }) { return false }
        // Formular-/Tabellenzeilen: Doppelpunkt, Klammern oder viele Ziffern.
        if line.contains(":") || line.contains("(") || line.contains(")") { return false }
        if line.filter(\.isNumber).count >= 4 { return false }
        // Reine Währungs-/Einheitenzeilen aus Tabellenköpfen sind keine Namen.
        let bare = line.trimmingCharacters(in: CharacterSet(charactersIn: " .,:-")).lowercased()
        if ["eur", "usd", "chf", "€", "summe", "betrag", "netto", "brutto"].contains(bare) { return false }
        let letters = line.filter { $0.isLetter }.count
        guard letters >= 3, letterRatio(line) > 0.5 else { return false }
        // Sehr lange Fließtext-Zeilen sind eher Beschreibung als Name.
        return line.split(separator: " ").count <= 6 && line.count <= 60
    }

    private static func letterRatio(_ s: String) -> Double {
        let significant = s.filter { !$0.isWhitespace }
        guard !significant.isEmpty else { return 0 }
        return Double(significant.filter { $0.isLetter }.count) / Double(significant.count)
    }

    /// Findet einen Geldbetrag in einer Zeile und normalisiert ihn auf "1234,56".
    static func amount(in line: String) -> String? {
        // Tausendertrenner darf Punkt, Komma oder Leerzeichen sein (DE „1.234,56",
        // EN „1,234.50"); der HINTERE Separator gilt als Dezimaltrenner (normalizeAmount).
        let pattern = #"\d{1,3}(?:[.,\s]\d{3})+(?:[.,]\d{1,2})?|\d+(?:[.,]\d{1,2})?"#
        guard let re = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = NSRange(line.startIndex..., in: line)
        let matches = re.matches(in: line, range: ns).compactMap { Range($0.range, in: line).map { String(line[$0]) } }
        guard !matches.isEmpty else { return nil }
        // Bevorzugt einen Token mit Dezimalstellen (echte Beträge), sonst den ersten.
        let token = matches.first { $0.contains(",") || $0.contains(".") } ?? matches[0]
        return normalizeAmount(token)
    }

    /// "1.234,56" / "1,234.56" / "1234.5" → "1234,56". Nil bei 0 oder Unsinn.
    static func normalizeAmount(_ token: String) -> String? {
        var s = token.replacingOccurrences(of: " ", with: "")
        let lastComma = s.lastIndex(of: ",")
        let lastDot = s.lastIndex(of: ".")
        var decimals = ""

        // Der HINTERE Separator ist der Dezimaltrenner — sofern ihm 1–2 Ziffern folgen.
        func split(at idx: String.Index) -> Bool {
            let after = s[s.index(after: idx)...]
            return after.count <= 2 && after.allSatisfy(\.isNumber) && !after.isEmpty
        }
        if let c = lastComma, let d = lastDot {
            let sepIdx = c > d ? c : d
            if split(at: sepIdx) { decimals = String(s[s.index(after: sepIdx)...]); s = String(s[..<sepIdx]) }
        } else if let only = lastComma ?? lastDot, split(at: only) {
            decimals = String(s[s.index(after: only)...]); s = String(s[..<only])
        }

        let integer = s.filter(\.isNumber)
        guard !integer.isEmpty else { return nil }
        let cents = decimals.isEmpty ? "" : (decimals.count == 1 ? decimals + "0" : decimals)
        guard Int(integer) ?? 0 > 0 || (Int(cents) ?? 0) > 0 else { return nil }
        return cents.isEmpty ? integer : "\(integer),\(cents)"
    }
}
