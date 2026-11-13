import SwiftUI

/// Subtitle unter dem großen Kontostand mit Toggle zwischen drei Modi:
/// • `0` = Classic: „Fixkosten offen: X €" / „Alle Fixkosten gebucht"
/// • `1` = Sub-Metrics: „€ 847 bis zum 1. verfügbar"
/// • `2` = Day-only: „€ 34/Tag verfügbar"
/// • `3` = Bankgebühren: „Bankgebühren 10,99 €" — **nur vorhanden, wenn welche erkannt
///   wurden.** Ohne Gebühren wird die Position übersprungen; „Bankgebühren 0,00 €" wäre
///   keine Auskunft, sondern eine Behauptung.
///
/// Der Toggle-Style wird außen via `@Binding` gehalten, damit Caller
/// (Flyout vs. Umsatzpanel) eigene `@AppStorage`-Keys nutzen können und
/// die beiden Views unabhängig gewechselt werden.
struct BalanceSubtitleSwitch: View {
    let balance: Double?
    let leftToPayAmount: Double?
    let salaryDay: Int
    let salaryToleranceBefore: Int
    let salaryToleranceAfter: Int
    /// Optionales Zyklusende (nächster Gehaltseingang) aus derselben Berechnung wie
    /// `leftToPayAmount`. Wenn gesetzt, treibt es das „bis zum …"-Datum statt der
    /// toleranzbasierten Eigenberechnung — sonst springt die Anzeige im Vorfenster
    /// des Gehalts einen Monat zu weit.
    var cycleEndOverride: Date? = nil
    @Binding var style: Int
    /// Wenn `true`, wird zwingend der Classic-Mode angezeigt und der Toggle-Button
    /// ausgeblendet. Nutzung: im Unified-Mode, wo Sub-Metrics mit aggregiertem
    /// `leftToPayAmount` gegen einen einzelnen Slot-Gehaltstag rechnen würden
    /// und damit fachlich inkonsistent wären.
    var forceClassic: Bool = false
    /// `true` reicht das Compact-Flag an `BalanceSubMetricsLabel` weiter, damit der schmale
    /// Flyout-Container kein Truncation-Wording zeigt. Default: false (breite Container).
    var compact: Bool = false
    /// Temperaturabhängige Detailfarbe (Prototyp §4: #5f8974 / #8a7d5f / #9a6060) für die
    /// „Fixkosten offen"-Zeile + Toggle-Icon auf der Money-Heat. Nil → Standard-Sekundärgrau.
    var detailColor: Color? = nil
    /// Wiederkehrende Bankgebühr, falls erkannt. `nil` blendet die Position aus.
    var bankgebuehr: Double? = nil
    /// Gebuchter Saldo abzüglich vorgemerkter Lastschriften. `nil` blendet die Position
    /// aus — ohne offene Vormerkung wäre sie dieselbe Zahl wie oben.
    ///
    /// Anlass (13.11.2026, YAXI): Die ING-Schnittstelle liefert **nur** `interimBooked`,
    /// also den gebuchten Saldo. Die ING-App zeigt dagegen den Stand abzüglich bereits
    /// vorgemerkter Abbuchungen — 489,71 statt 505,21 bei 15,50 vorgemerkt. YAXI kann die
    /// 489,71 nicht liefern; wer sie sehen will, muss rechnen. Das tut
    /// `AvailableBalance`, und hier wird das Ergebnis endlich gezeigt.
    var verfuegbar: Double? = nil

    private static let classicFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.locale = Locale(identifier: "de_DE")
        f.currencyCode = "EUR"
        f.maximumFractionDigits = 0
        return f
    }()

    private func classicLabel(_ amount: Double) -> String {
        let formatted = Self.classicFormatter.string(from: NSNumber(value: amount)) ?? "\(Int(amount)) €"
        // „Noch offen" hat ein Kunde als „noch nicht abgebucht" gelesen und sich über
        // 1.229 € gewundert — gemeint sind die erwarteten wiederkehrenden Zahlungen bis
        // zum nächsten Gehalt. Die Zahl war richtig, das Wort war es nicht.
        return L10n.t("Fixkosten offen: \(formatted)", "Recurring due: \(formatted)")
    }

    private func toggle() {
        // Classic (0) → Sub-Metrics (1) → Day-only (2) → Bankgebühren (3) →
        // Verfügbar (4) → Classic. Positionen ohne Inhalt werden übersprungen, sonst
        // landete man auf einer leeren Zeile.
        var naechster = style
        repeat {
            naechster = (naechster + 1) % 5
        } while !hatInhalt(naechster) && naechster != style
        style = naechster
    }

    /// Hat diese Position gerade etwas zu sagen? 0-2 immer, 3 und 4 nur mit Wert.
    private func hatInhalt(_ stil: Int) -> Bool {
        switch stil {
        case 3: return bankgebuehr != nil
        case 4: return verfuegbar != nil
        default: return true
        }
    }

    /// Auf eine Position, die es gerade nicht gibt, darf die Anzeige nicht stehenbleiben:
    /// Beim Kontowechsel kann die Gebühr oder die Vormerkung verschwinden, der
    /// gespeicherte Modus bleibt.
    private var wirksamerStil: Int {
        hatInhalt(style) ? style : 0
    }

    private var currentModeLabel: String {
        switch style {
        case 1: return L10n.t("Sub-Metrics", "Sub-metrics")
        case 2: return L10n.t("Tagesbudget", "Daily budget")
        case 3: return L10n.t("Bankgebühren", "Bank fees")
        case 4: return L10n.t("Verfügbar", "Available")
        default: return L10n.t("Klassisch", "Classic")
        }
    }

    private var nextModeLabel: String {
        switch (style + 1) % 5 {
        case 1: return L10n.t("Sub-Metrics", "Sub-metrics")
        case 2: return L10n.t("Tagesbudget", "Daily budget")
        case 3: return L10n.t("Bankgebühren", "Bank fees")
        case 4: return L10n.t("Verfügbar", "Available")
        default: return L10n.t("Klassisch", "Classic")
        }
    }

    private var currentModeIcon: String {
        switch style {
        case 1: return "chart.bar.fill"
        case 2: return "sun.max.fill"
        case 3: return "building.columns.fill"
        case 4: return "hourglass"
        default: return "text.alignleft"
        }
    }

    private var themed: Bool { !ThemeManager.shared.currentTheme.isDefault }
    private var lofi: Bool { themed && ThemeChrome.lofi }

    var body: some View {
        HStack(spacing: 6) {
            if !forceClassic {
                // Als kleine Pille darstellen, damit klar ist: das ist ein Umschalter.
                Button(action: toggle) {
                    if lofi {
                        // BTX: kleiner Block statt SF-Symbol (README: „grüner Mosaik-Punkt").
                        Rectangle()
                            .fill(Color.themedIncome)
                            .frame(width: 8, height: 8)
                            .frame(width: 16, height: 16)
                            .contentShape(Rectangle())
                    } else {
                        // Prototyp: transparenter Umschalter (nur Icon, kein Kasten/Rahmen).
                        Image(systemName: currentModeIcon)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(detailColor ?? .secondary)
                            .frame(width: 18, height: 16)
                            .contentShape(Rectangle())
                    }
                }
                .buttonStyle(.plain)
                .help(L10n.t(
                    "Aktuell: \(currentModeLabel)\nKlick → \(nextModeLabel)",
                    "Current: \(currentModeLabel)\nClick → \(nextModeLabel)"
                ))
            }
            subtitleContent
        }
    }

    @ViewBuilder
    private var subtitleContent: some View {
        if forceClassic {
            classicContent
        } else {
            switch wirksamerStil {
            case 1:
                subMetricsWithFallback(dayOnly: false)
            case 2:
                subMetricsWithFallback(dayOnly: true)
            case 3:
                gebuehrenContent
            case 4:
                verfuegbarContent
            default:
                classicContent
            }
        }
    }

    /// Bewusst ohne Zeitraum im Text: Die meisten Banken buchen monatlich, manche aber
    /// zum Quartalsabschluss. „im Monat" wäre dann falsch, und die Zahl allein stimmt.
    @ViewBuilder
    private var gebuehrenContent: some View {
        if let betrag = bankgebuehr {
            Text(L10n.t("Bankgebühren \(Self.classicFormatter.string(from: NSNumber(value: betrag)) ?? "")",
                        "Bank fees \(Self.classicFormatter.string(from: NSNumber(value: betrag)) ?? "")"))
                .font(ThemeFonts.flyoutBody(size: 12))
                .foregroundColor(detailColor ?? .secondary)
                .lineLimit(1)
        }
    }

    /// Mit Nachkommastellen, anders als die übrigen Positionen: Der Sinn dieser Zeile
    /// ist der Vergleich mit der Banking-App, und die zeigt Cents.
    @ViewBuilder
    private var verfuegbarContent: some View {
        if let betrag = verfuegbar {
            Text(L10n.t("Verfügbar \(Self.centFormatter.string(from: NSNumber(value: betrag)) ?? "")",
                        "Available \(Self.centFormatter.string(from: NSNumber(value: betrag)) ?? "")"))
                .font(ThemeFonts.flyoutBody(size: 12))
                .foregroundColor(detailColor ?? .secondary)
                .lineLimit(1)
        }
    }

    private static let centFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.locale = Locale(identifier: "de_DE")
        f.currencyCode = "EUR"
        f.maximumFractionDigits = 2
        f.minimumFractionDigits = 2
        return f
    }()

    // MARK: - Sub-Metrics Mode (mit Classic-Fallback bei .unknown)

    @ViewBuilder
    private func subMetricsWithFallback(dayOnly: Bool) -> some View {
        let metrics = BalanceSubMetrics.compute(
            balance: balance,
            leftToPay: leftToPayAmount,
            salaryDay: salaryDay,
            toleranceBefore: salaryToleranceBefore,
            toleranceAfter: salaryToleranceAfter,
            cycleEndOverride: cycleEndOverride
        )
        switch metrics.state {
        case .normal, .overdrawn:
            BalanceSubMetricsLabel(metrics: metrics, dayOnly: dayOnly, compact: compact)
        case .unknown:
            classicContent
        }
    }

    // MARK: - Classic Mode

    @ViewBuilder
    private var classicContent: some View {
        if let amount = leftToPayAmount {
            let text = amount > 0.5
                ? classicLabel(amount)
                : L10n.t("Alle Fixkosten gebucht", "All recurring paid")
            Text(text)
                .font(lofi ? ThemeFonts.flyoutBody(size: 16)
                     : themed ? ThemeFonts.flyoutBody(size: 13)
                              : .system(size: 13, weight: .regular))
                .textCase(ThemeChrome.textCase)
                .foregroundColor(themed ? .themedIncome : (detailColor ?? Color(NSColor.secondaryLabelColor)))
                .lineLimit(1)
        } else {
            // Placeholder reserves vertical space while value is computing
            Text(" ")
                .font(.system(size: 13, weight: .regular))
                .hidden()
        }
    }
}
