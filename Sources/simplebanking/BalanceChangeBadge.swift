import SwiftUI

/// „▲ 4,2 %" neben dem Kontostand. Lab-Funktion, Standard aus.
///
/// **Neutral gefärbt, nicht grün/rot.** Ein sinkender Kontostand nach der Miete ist
/// nichts, wovor gewarnt werden müsste; die Richtung trägt der Pfeil. Die Farbe ist
/// dieselbe wie beim Untertitel darunter, damit das Abzeichen als Beiwerk der großen
/// Zahl gelesen wird und nicht mit ihr konkurriert.
///
/// **Pfeil als Text, nicht als SF-Symbol.** So sitzt er auf derselben Grundlinie und in
/// derselben Schrift wie die Zahl — auch im Lo-Fi-Theme, wo grafische Symbole
/// grundsätzlich durch Zeichen ersetzt werden.
struct BalanceChangeBadge: View {

    /// Derselbe Schlüssel wie in den Einstellungen; ohne Notification, weil `@AppStorage`
    /// die View von sich aus neu zeichnet.
    static let einstellungsSchluessel = "balanceChangeBadgeEnabled"

    let anzeige: BalanceChange.Anzeige
    /// Eurobetrag für den Tooltip — die angezeigte Zahl kann ja ein Prozentwert sein.
    let bewegungEuro: Double
    /// Farbe des Untertitels an dieser Stelle. `nil` → Sekundärgrau.
    var detailColor: Color? = nil

    @AppStorage(BalanceChangeBadge.einstellungsSchluessel) private var aktiviert: Bool = false

    private var themed: Bool { !ThemeManager.shared.currentTheme.isDefault }
    private var lofi: Bool { ThemeChrome.lofi }

    var body: some View {
        if aktiviert, let text = BalanceChange.text(anzeige) {
            Text(text)
                // Exakt die Größen des Untertitels (BalanceSubtitleSwitch).
                .font(lofi ? ThemeFonts.flyoutBody(size: 16)
                     : themed ? ThemeFonts.flyoutBody(size: 13)
                              : .system(size: 13, weight: .regular))
                .foregroundColor(themed ? Color.themedInk.opacity(0.7)
                                        : (detailColor ?? Color(NSColor.secondaryLabelColor)))
                .lineLimit(1)
                .fixedSize()
                .help(BalanceChange.erklaerung(anzeige, bewegungEuro: bewegungEuro) ?? "")
                .accessibilityLabel(Text(BalanceChange.erklaerung(anzeige, bewegungEuro: bewegungEuro) ?? text))
        }
    }
}
