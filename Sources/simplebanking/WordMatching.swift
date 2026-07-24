import Foundation

/// Wortgrenzen-bewusstes Suchen in Freitext.
///
/// Blankes `contains` ist bei kurzen Tokens unbrauchbar: „obi" steckt in
/// „M-obi-lity", „pin" in „map-pin-g", „ust" in „M-ust-ermann". Diese Fehlerklasse
/// ist in dieser Codebasis mehrfach aufgetreten (Kategorisierung, Händler-Aliase,
/// Rechnungs-Parser) — deshalb liegt die Prüfung hier zentral.
enum WordMatch {

    /// Treffer nur als ganzes Wort. Für Markennamen, Abkürzungen und alles,
    /// was im Text als eigenständiges Token steht.
    static func asWord(_ haystack: String, _ needle: String) -> Bool {
        matches(haystack, needle, requireEnd: true)
    }

    /// Treffer nur am Wortanfang, Wortende offen. Für deutsche Wortstämme,
    /// die in Komposita weiterlaufen („versicherung" → „Versicherungsbeitrag").
    static func atWordStart(_ haystack: String, _ needle: String) -> Bool {
        matches(haystack, needle, requireEnd: false)
    }

    /// Trifft eines der Wörter?
    static func containsAnyWord(_ haystack: String, _ needles: [String]) -> Bool {
        needles.contains { asWord(haystack, $0) }
    }

    /// Die Grenze wird nur dort geprüft, wo das Keyword selbst auf einem Buchstaben
    /// beginnt bzw. endet — sonst würden Tokens mit Satzzeichen am Rand („rtl+",
    /// „h&m", „e.on") nie matchen.
    private static func matches(_ haystack: String, _ needle: String, requireEnd: Bool) -> Bool {
        guard let first = needle.first, let last = needle.last else { return false }
        var searchStart = haystack.startIndex
        while let range = haystack.range(of: needle, range: searchStart..<haystack.endIndex) {
            let startOK = !first.isLetter
                || range.lowerBound == haystack.startIndex
                || !haystack[haystack.index(before: range.lowerBound)].isLetter
            let endOK = !requireEnd
                || !last.isLetter
                || range.upperBound == haystack.endIndex
                || !haystack[range.upperBound].isLetter
            if startOK && endOK { return true }
            searchStart = haystack.index(after: range.lowerBound)
        }
        return false
    }
}
