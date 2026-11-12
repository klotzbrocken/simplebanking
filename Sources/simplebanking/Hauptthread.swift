import Foundation

/// Der Weg auf den Haupt-Thread, der auch während `NSApp.runModal` ankommt.
///
/// **Warum es diesen Umweg gibt.** Der Einrichtungsassistent läuft modal, und
/// `NSApp.runModal` dreht die Schleife in `NSModalPanelRunLoopMode`. Weder
/// `DispatchQueue.main.async` noch `CFRunLoopPerformBlock(commonModes)` feuern in
/// diesem Modus — beide hängen an den gemeinsamen Modi. Der Haupt-Actor von Swift
/// plant über genau diese Warteschlange. Das heißt:
///
/// * `Task { … }` aus dem Assistenten heraus erbt den Haupt-Actor und **läuft nie an**,
/// * `await MainActor.run { … }` kehrt **nie zurück**.
///
/// Beides ohne Warnung, ohne Fehler, ohne Absturz — die Oberfläche steht einfach. Am
/// 11.11.2026 kostete das einen halben Tag Fehlersuche am MoneyMoney-Import: Das Rad
/// drehte sich, „Datenbank wird gelesen …" stand da, und im Sample des Prozesses war
/// kein einziger laufender Rahmen. Die Aufgabe war nie gestartet.
///
/// `RunLoop.perform(inModes:block:)` feuert einmal im ersten passenden Modus. Mit
/// `.modalPanel` in der Liste kommt der Block auch während der modalen Sitzung an.
///
/// Regel: Wer aus dem Assistenten heraus Arbeit startet, nimmt `Task.detached` und
/// kommt über diese Datei zurück — nicht über `Task { }` und nicht über `MainActor.run`.
enum Hauptthread {

    /// Einen Block auf dem Haupt-Thread ausführen, ohne auf ihn zu warten.
    nonisolated static func sprung(_ block: @escaping @Sendable () -> Void) {
        RunLoop.main.perform(inModes: [.default, .modalPanel], block: block)
    }

    /// Der Ersatz für `await MainActor.run { … }`.
    nonisolated static func lauf<T: Sendable>(
        _ arbeit: @escaping @MainActor () -> T
    ) async -> T {
        await withCheckedContinuation { fortsetzung in
            sprung {
                // Der Block läuft auf dem Haupt-Thread — das ist die Zusage von
                // `RunLoop.main.perform`, und `assumeIsolated` nimmt sie beim Wort,
                // statt einen zweiten Sprung über dieselbe tote Warteschlange zu
                // machen.
                fortsetzung.resume(returning: MainActor.assumeIsolated { arbeit() })
            }
        }
    }
}
