import Foundation
import AppIntents

// MARK: - App Intents: Spotlight, Kurzbefehle, Raycast
//
// ⚠️ **Diese Intents sind derzeit NICHT registriert und tauchen nirgends auf.**
//
// macOS findet Intents über ein `Metadata.appintents`-Bundle in `Contents/Resources`.
// Erzeugt wird es von `appintentsmetadataprocessor`, der Const-Value-Metadaten des
// Compilers braucht. Ein reiner SwiftPM-Build liefert die nicht: `-emit-const-values`
// erreicht den Compiler zwar, erzeugt aber ohne den begleitenden Ausgabepfad je
// Quelldatei keine Datei — und den setzt nur Xcodes Build-System.
//
// Der Code bleibt trotzdem hier: Er baut, ist getestet, kostet zur Laufzeit nichts und
// ist der halbe Weg, falls das App-Target je ein Xcode-Projekt bekommt. Ohne diesen
// Hinweis würde in einem halben Jahr jemand suchen, warum in Kurzbefehlen nichts
// erscheint — die Antwort steht nicht im Code, sondern im Bauweg.
//
// Erreichbar sind dieselben Daten heute über das CLI (`sb --json`) und die
// Raycast-Erweiterung in `raycast/`.
//
// Die reinste Form der Menüleisten-Idee: Die App muss gar nicht mehr geöffnet werden.
// Verfügbar ab macOS 13, das Programm setzt 14 voraus — es muss also nichts angehoben
// werden. Der Spotlight-Aktionen-Reiter aus macOS 26 ist eine Zugabe; Kurzbefehle und
// Raycast erreichen dieselben Intents auf jeder unterstützten Fassung.
//
// Alle lesenden Intents kommen ohne Bankaufruf aus — siehe `IntentDaten`. Der einzige,
// der die App nach vorn holt, ist die Überweisung; alle anderen laufen im Hintergrund,
// wie es sich für eine Automatisierung gehört.

// MARK: Saldo

struct SaldoIntent: AppIntent {
    static let title: LocalizedStringResource = "Kontostand abfragen"
    static let description = IntentDescription(
        "Zeigt den aktuellen Kontostand aus dem lokalen Bestand — ohne Bankabruf und ohne TAN."
    )
    /// Kein `openAppWhenRun`: Der Sinn ist ja gerade, die App nicht zu brauchen.
    static let openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<Double> {
        let staende = IntentDaten.kontostaende()
        guard let summe = IntentDaten.gesamtsaldo() else {
            return .result(value: 0, dialog: IntentDialog(stringLiteral:
                IntentDaten.satz(fuer: nil, konten: 0)))
        }
        return .result(value: summe,
                       dialog: IntentDialog(stringLiteral:
                        IntentDaten.satz(fuer: summe, konten: staende.count)))
    }
}

// MARK: Konten

struct KontenIntent: AppIntent {
    static let title: LocalizedStringResource = "Konten auflisten"
    static let description = IntentDescription(
        "Listet alle verbundenen Konten mit ihrem zuletzt abgerufenen Stand."
    )
    static let openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<[String]> {
        let zeilen = IntentDaten.kontostaende().map { konto in
            "\(konto.name): \(IntentDaten.waehrung.string(from: NSNumber(value: konto.saldo)) ?? "")"
        }
        let text = zeilen.isEmpty
            ? L10n.t("Keine Konten verbunden.", "No accounts connected.")
            : zeilen.joined(separator: "\n")
        return .result(value: zeilen, dialog: IntentDialog(stringLiteral: text))
    }
}

// MARK: Ausgaben

struct AusgabenIntent: AppIntent {
    static let title: LocalizedStringResource = "Ausgaben abfragen"
    static let description = IntentDescription(
        "Summe der Ausgaben der letzten Tage, vorgemerkte Buchungen eingeschlossen."
    )
    static let openAppWhenRun = false

    @Parameter(title: "Zeitraum in Tagen", default: 30)
    var tage: Int

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<Double> {
        let summe = IntentDaten.ausgaben(tage: tage, slots: nil)
        let betrag = IntentDaten.waehrung.string(from: NSNumber(value: summe)) ?? "\(summe)"
        return .result(value: summe, dialog: IntentDialog(stringLiteral:
            L10n.t("\(betrag) in den letzten \(tage) Tagen",
                   "\(betrag) over the last \(tage) days")))
    }
}

// MARK: Letzte Umsätze

struct UmsaetzeIntent: AppIntent {
    static let title: LocalizedStringResource = "Letzte Umsätze"
    static let description = IntentDescription("Die zuletzt gebuchten Umsätze.")
    static let openAppWhenRun = false

    @Parameter(title: "Anzahl", default: 5)
    var anzahl: Int

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<[String]> {
        let buchungen = IntentDaten.letzteBuchungen(anzahl: anzahl, tage: 90, slots: nil)
        let zeilen = buchungen.map { tx -> String in
            let betrag = IntentDaten.waehrung.string(from: NSNumber(value: tx.parsedAmount)) ?? ""
            let wer = tx.creditor?.name ?? tx.debtor?.name ?? "—"
            return "\(wer): \(betrag)"
        }
        let text = zeilen.isEmpty
            ? L10n.t("Keine Umsätze vorhanden.", "No transactions available.")
            : zeilen.joined(separator: "\n")
        return .result(value: zeilen, dialog: IntentDialog(stringLiteral: text))
    }
}

// MARK: Aktualisieren — der einzige, der die Bank anfragt

struct AktualisierenIntent: AppIntent {
    static let title: LocalizedStringResource = "Konten aktualisieren"
    static let description = IntentDescription(
        "Ruft die Banken ab. Kann je nach Bank eine Freigabe verlangen — deshalb nicht für unbeaufsichtigte Automatisierungen geeignet."
    )
    /// Holt die App bewusst nach vorn: Verlangt die Bank eine TAN oder eine Freigabe im
    /// Browser, muss jemand davorsitzen. Ein stiller Hintergrundabruf, der auf eine
    /// Eingabe wartet, sieht aus wie ein Hänger.
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        NotificationCenter.default.post(name: Notification.Name("simplebanking.refreshRequested"),
                                        object: nil)
        return .result()
    }
}

// MARK: Überweisung

struct UeberweisungIntent: AppIntent {
    static let title: LocalizedStringResource = "Überweisung starten"
    static let description = IntentDescription(
        "Öffnet das Überweisungsfenster. Ausgelöst wird nichts ohne deine Bestätigung."
    )
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        // Bewusst dieselbe Nachricht wie das MCP-Werkzeug und der Menüeintrag: Ein
        // zweiter Name für denselben Vorgang wäre eine zweite Stelle, die man beim
        // nächsten Umbau übersieht.
        NotificationCenter.default.post(name: Notification.Name("simplebanking.openTransferSheet"),
                                        object: nil)
        return .result()
    }
}

// MARK: - Auslösephrasen

/// Ohne Provider taucht nichts von selbst in Spotlight auf — der Nutzer müsste die
/// Kurzbefehle-App öffnen und selbst etwas bauen. Das widerspräche dem Zero-Config-Test.
struct SimplebankingShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: SaldoIntent(),
                    phrases: ["Kontostand in \(.applicationName)",
                              "Wie viel Geld habe ich in \(.applicationName)",
                              "Balance in \(.applicationName)"],
                    shortTitle: "Kontostand",
                    systemImageName: "eurosign.circle")
        AppShortcut(intent: AusgabenIntent(),
                    phrases: ["Ausgaben in \(.applicationName)",
                              "Spending in \(.applicationName)"],
                    shortTitle: "Ausgaben",
                    systemImageName: "chart.bar")
        AppShortcut(intent: UmsaetzeIntent(),
                    phrases: ["Letzte Umsätze in \(.applicationName)",
                              "Recent transactions in \(.applicationName)"],
                    shortTitle: "Umsätze",
                    systemImageName: "list.bullet")
        AppShortcut(intent: AktualisierenIntent(),
                    phrases: ["Konten aktualisieren in \(.applicationName)",
                              "Refresh \(.applicationName)"],
                    shortTitle: "Aktualisieren",
                    systemImageName: "arrow.clockwise")
    }
}
