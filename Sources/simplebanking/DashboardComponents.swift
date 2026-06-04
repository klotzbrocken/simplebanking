import SwiftUI

// MARK: - Tokens (Ergänzung zu ThemeSupport)

extension Color {
    /// Eingabe-Tint für Textfelder im Assistenten (#F4F6F9 hell / #26292E dunkel).
    static var sbInputTint: Color {
        Color(nsColor: NSColor(name: nil) { ap in
            let dark = ap.bestMatch(from: [.darkAqua, .vibrantDark]) != nil
            return dark ? NSColor(srgbRed: 0.149, green: 0.161, blue: 0.180, alpha: 1)
                        : NSColor(srgbRed: 0.957, green: 0.965, blue: 0.976, alpha: 1)
        })
    }
}

// MARK: - Einheitlicher Tab-Kopf

/// Gemeinsamer Kopf aller Dashboard-Tabs: Titel + Untertitel links, kontextuelle Steuerung rechts.
/// Danach folgt im jeweiligen View ein `Divider()`.
struct TabHeader<Trailing: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder var trailing: Trailing

    init(_ title: String, subtitle: String, @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.subtitle = subtitle
        self.trailing = trailing()
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 20, weight: .bold))
                Text(subtitle).font(.system(size: 12.5)).foregroundColor(.secondary)
            }
            Spacer(minLength: 12)
            trailing
        }
        .padding(.horizontal, 20)
        .padding(.top, 14)
        .padding(.bottom, 13)
        .frame(minHeight: 60)
    }
}

extension TabHeader where Trailing == EmptyView {
    init(_ title: String, subtitle: String) {
        self.init(title, subtitle: subtitle) { EmptyView() }
    }
}

// MARK: - Einheitliche Karte

extension View {
    /// Karte mit 3 px farbiger Akzentleiste links (Sektions-/Typ-Farbe). Inhalt bereits gepaddet.
    func accentCard(_ accent: Color, radius: CGFloat = 10) -> some View {
        self
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: radius, style: .continuous).fill(Color.cardBackground)
                    Rectangle().fill(accent).frame(width: 3)
                }
                .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(Color.sbBorder, lineWidth: 1))
                .shadow(color: .black.opacity(0.05), radius: 2, x: 0, y: 1)
            )
    }

    /// Weiße Karte: 1pt `sbBorder`, Radius 10, Hairline-Schatten.
    func dashboardCard(radius: CGFloat = 10, padding: CGFloat? = nil) -> some View {
        self
            .padding(padding ?? 0)
            .background(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(Color.cardBackground)
                    .overlay(
                        RoundedRectangle(cornerRadius: radius, style: .continuous)
                            .strokeBorder(Color.sbBorder, lineWidth: 1)
                    )
                    .shadow(color: .black.opacity(0.05), radius: 2, x: 0, y: 1)
            )
    }
}

// MARK: - Menu-Trigger-Label

/// Einheitliches Trigger-Label für native `Menu`s: Text + `chevron.down`, gerahmt.
struct MenuTriggerLabel: View {
    let text: String
    var systemImage: String? = nil
    var body: some View {
        HStack(spacing: 6) {
            if let systemImage { Image(systemName: systemImage).font(.system(size: 11)) }
            Text(text).font(.system(size: 13)).lineLimit(1)
            Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold)).foregroundColor(.secondary)
        }
        .padding(.horizontal, 10).padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.cardBackground)
                .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Color.sbBorder, lineWidth: 1))
        )
    }
}

/// Menü-Eintrag mit Häkchen beim aktiven Wert (vermeidet den leeren ersten Eintrag von Picker-im-Menu).
@ViewBuilder
func menuCheckItem(_ title: String, selected: Bool) -> some View {
    if selected { Label(title, systemImage: "checkmark") } else { Text(title) }
}
