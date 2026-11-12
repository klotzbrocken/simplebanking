import AppKit

// MARK: - Was hat das Status-Item gerade ausgelöst?
//
// Gemeldet am 07.11.2026 von einem blinden Nutzer, zum zweiten Mal — die erste Meldung
// kam direkt nach der Veröffentlichung: Das Menüleisten-Symbol ist mit VoiceOver
// erreichbar, aber **nicht bedienbar**. VO+Leertaste, VO+Umschalt+M und
// VO+Umschalt+Leertaste bewirken nichts, es öffnet sich weder Menü noch Fenster.
//
// Die Ursache war eine Zeile. `statusItemClicked` begann mit
//
//     guard let ev = NSApp.currentEvent else { return }
//
// und jeder Zweig darunter prüfte `ev.type == .leftMouseUp` / `.rightMouseUp`. Ein Druck
// über die Bedienungshilfen ruft die Action des Buttons **direkt** auf und trägt kein
// Mausereignis — der Fall fiel durch alles durch. Dass die Action dabei überhaupt
// ankommt, ist nicht geraten: Electron hat denselben Fehler behoben, mit derselben
// Diagnose („VoiceOver doesn't know where to send the select action", „VoiceOver won't
// trigger mouseUp").
//
// Warum es nicht anders geht: `statusItem.button` ist `readonly` und wird von AppKit
// erzeugt, eine eigene Klasse lässt sich dort nicht einhängen. `accessibilityPerformPress`
// und `accessibilityPerformShowMenu` sind Protokollmethoden ohne Setter, also nicht
// beeinflussbar — VO+Umschalt+M bleibt ohne Wirkung, VO+Leertaste ist der Weg.
// `statusItem.menu` zuzuweisen wäre der native Ausweg, nimmt aber den Klick vorweg
// (siehe den Kommentar beim Menüaufbau in `BalanceBar`): Einfach- und Doppelklick,
// `swapClickBehavior` und das Einblenden des Saldos wären weg. Und das an
// `NSWorkspace.isVoiceOverEnabled` zu hängen wäre ein Modus, der mitten in der Sitzung
// umschaltet und nur VoiceOver hilft — Schaltersteuerung und AppleScript blieben kaputt.
//
// Die Regel steht hier als reine Funktion, weil `NSApp.currentEvent` im Test nicht zu
// stellen ist, die Entscheidung darüber aber schon.

enum Statusklick {

    /// Trägt das aktuelle Ereignis einen echten Mausklick auf das Status-Item?
    ///
    /// `false` heißt: Es gibt keine Klickunterscheidung, auf die sich
    /// `statusItemClicked` stützen könnte — also Statusmenü, der einzige Weg, der alles
    /// erreicht und den VoiceOver von Haus aus vorliest.
    ///
    /// **Bewusst ohne Frischeprüfung.** `NSApp.currentEvent` könnte theoretisch ein altes
    /// `.leftMouseUp` halten; ein Vergleich von `timestamp` gegen
    /// `ProcessInfo.systemUptime` würde das abfangen. Laufen die beiden Uhren je
    /// auseinander, öffnet aber **jeder** echte Klick das Menü statt des Flyouts — ein
    /// sichtbarer Rückschritt für alle, um einen Fall abzusichern, dessen schlimmste
    /// Folge „einmal geht das Flyout auf statt des Menüs" ist.
    static func istMausklick(_ typ: NSEvent.EventType?) -> Bool {
        typ == .leftMouseUp || typ == .rightMouseUp
    }
}
