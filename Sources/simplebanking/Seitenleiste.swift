import SwiftUI

// MARK: - Die Seitenleiste des Umsatzfensters
//
// Drei Abschnitte: Konten, Kategorien, Auswertungen. Sie löst die Bank-Kreise über der
// Liste ab, solange sie offen ist, und ist der zweite Ort, an dem eine Auswertung
// aufgehen kann (siehe `Seitenleiste.auswertungsPlatz`).
//
// **Sie ruft nichts bei der Bank ab.** Jeder Klick löst einen Ablauf aus, den es schon
// gibt: Kontowechsel über `AccountNavModel`, Filter über das Ansichtsmodell.
//
// **Sie scrollt und ihre Abschnitte klappen zu.** 14 eingebaute Kategorien plus
// Eigenkategorien, dazu Konten und Auswertungen, sind in einem 620 pt hohen Fenster
// nicht am Stück zu zeigen.
struct Seitenleistenansicht: View {

    @ObservedObject var vm: TransactionsViewModel
    @ObservedObject var store: MultibankingStore
    let accountNav: AccountNavModel
    @Binding var ansicht: Hauptansicht
    @Binding var kontenZu: Bool
    @Binding var kategorienZu: Bool
    @Binding var auswertungenZu: Bool
    @Binding var sendenZu: Bool
    /// Kann von diesem Konto überwiesen werden? Belegslots und PayPal können es nicht,
    /// und ohne freigeschaltetes Modul gibt es den Abschnitt nicht (gleiche Regel wie
    /// beim Papierflieger in der Fußzeile).
    var sendenMoeglich: Bool = false

    @ObservedObject private var logoStore = BankLogoStore.shared
    @Environment(\.colorScheme) private var farbschema

    private var themed: Bool { !ThemeManager.shared.currentTheme.isDefault }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 1) {
                abschnitt(L10n.t("Konten", "Accounts"), zu: $kontenZu) { konten }
                abschnitt(L10n.t("Kategorien", "Categories"), zu: $kategorienZu) { kategorien }
                abschnitt(L10n.t("Auswertungen", "Reports"), zu: $auswertungenZu) { auswertungen }
                if sendenMoeglich {
                    abschnitt(L10n.t("Geld senden", "Send money"), zu: $sendenZu) { senden }
                }
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 10)
            // Oben bleibt der Streifen frei, in dem Ampel und Knopf sitzen.
            .padding(.top, 36)
        }
        .scrollIndicators(.automatic)
        .frame(width: Seitenleiste.breite)
        .background(flaeche.ignoresSafeArea(.all, edges: .top))
    }

    /// Eigene Fläche statt `NSVisualEffectView`: Die App hat nirgends eines, und die
    /// Toolbar flog aus genau diesem Fenster, weil ihr Material den Verlauf überdeckte.
    private var flaeche: some View {
        ZStack {
            Color.themedSurfaceOrClear
            (farbschema == .dark ? Color.white : Color.black).opacity(0.05)
        }
    }

    // MARK: - Abschnitt

    @ViewBuilder
    private func abschnitt<Inhalt: View>(_ titel: String, zu: Binding<Bool>,
                                         @ViewBuilder inhalt: () -> Inhalt) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.15)) { zu.wrappedValue.toggle() }
        } label: {
            HStack(spacing: 4) {
                Text(titel)
                    .font(ThemeFonts.flyoutBody(size: 11, weight: .semibold))
                    .textCase(ThemeChrome.textCase)
                    .foregroundColor(.secondary)
                Image(systemName: zu.wrappedValue ? "chevron.right" : "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundColor(.secondary.opacity(0.7))
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.top, 12)
            .padding(.bottom, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(titel))
        .accessibilityValue(Text(zu.wrappedValue ? L10n.t("zugeklappt", "collapsed")
                                                 : L10n.t("aufgeklappt", "expanded")))
        if !zu.wrappedValue { inhalt() }
    }

    // MARK: - Konten

    @ViewBuilder
    private var konten: some View {
        if let stand = standText {
            Text(stand)
                .font(ThemeFonts.flyoutBody(size: 10))
                .foregroundColor(.secondary)
                .padding(.horizontal, 8)
                .padding(.bottom, 3)
        }
        if store.realSlotCount > 1 {
            zeile(aktiv: vm.unifiedModeEnabled,
                  beschriftung: L10n.t("Alle Konten", "All accounts"),
                  betrag: gesamtsaldo) {
                Image(systemName: "square.stack.3d.up.fill")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .frame(width: 18, height: 18)
            } aktion: {
                vm.unifiedModeEnabled = true
                ansicht = .umsaetze
            }
        }
        ForEach(Array(store.slots.enumerated()), id: \.offset) { idx, slot in
            zeile(aktiv: !vm.unifiedModeEnabled && idx == store.activeIndex,
                  beschriftung: slot.nickname?.nilIfEmpty ?? slot.displayName,
                  betrag: saldo(slot)) {
                kachel(slot)
            } aktion: {
                if vm.unifiedModeEnabled { vm.unifiedModeEnabled = false }
                accountNav.onSwitchToIndex?(idx)
                ansicht = .umsaetze
            }
        }
    }

    @ViewBuilder
    private func kachel(_ slot: BankSlot) -> some View {
        let marke = BankLogoAssets.resolve(displayName: slot.displayName,
                                           logoID: slot.logoId,
                                           iban: slot.isReceiptSlot ? nil : slot.iban)
        if let bild = slot.brandLogoImage ?? logoStore.image(for: marke) {
            BankMark(image: bild, brandId: marke?.id, size: 18, cornerRadius: 5,
                     dark: farbschema == .dark)
        } else {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(Color.secondary.opacity(0.25))
                .frame(width: 18, height: 18)
                .overlay(
                    Text(String((slot.nickname?.nilIfEmpty ?? slot.displayName).prefix(1)).uppercased())
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.white)
                )
        }
    }

    /// Der gespeicherte Saldo dieses Kontos. `nil`, wenn nie einer geholt wurde.
    private func saldo(_ slot: BankSlot) -> Double? {
        let schluessel = "simplebanking.cachedBalance.\(slot.id)"
        guard UserDefaults.standard.object(forKey: schluessel) != nil else { return nil }
        return UserDefaults.standard.double(forKey: schluessel)
    }

    /// Summe über alle Konten, aber **nur**, wenn von jedem ein Zeitpunkt bekannt ist.
    ///
    /// Eine Summe aus Zahlen verschiedenen Alters sieht genauer aus, als sie ist. Fehlt
    /// zu einem Konto der Zeitpunkt, bleibt die Zeile ohne Zahl.
    private var gesamtsaldo: Double? {
        let echte = store.slots.filter { !$0.isReceiptSlot }
        guard !echte.isEmpty,
              echte.allSatisfy({ Saldoalter.zeitpunkt(slotId: $0.id) != nil }) else { return nil }
        let werte = echte.compactMap { saldo($0) }
        guard werte.count == echte.count else { return nil }
        return werte.reduce(0, +)
    }

    /// Eine Zeile für alle: Wie alt die Zahlen sind, zählt der älteste Abruf.
    private var standText: String? {
        let zeiten = store.slots.filter { !$0.isReceiptSlot }
            .compactMap { Saldoalter.zeitpunkt(slotId: $0.id) }
        guard let aeltester = zeiten.min() else { return nil }
        return L10n.t("Stand: \(Saldoalter.beschriftung(aeltester))",
                      "As of: \(Saldoalter.beschriftung(aeltester))")
    }

    // MARK: - Kategorien

    @ViewBuilder
    private var kategorien: some View {
        zeile(aktiv: vm.kategorieFilter == nil,
              beschriftung: L10n.t("Alle Umsätze", "All transactions"),
              betrag: nil) {
            Circle().fill(Color.secondary.opacity(0.5)).frame(width: 8, height: 8)
                .frame(width: 18, height: 18)
        } aktion: {
            vm.kategorieFilter = nil
            ansicht = .umsaetze
        }
        ForEach(TransactionCategory.allCases, id: \.self) { kategorie in
            zeile(aktiv: vm.kategorieFilter == kategorie,
                  beschriftung: kategorie.displayName,
                  betrag: nil) {
                Circle().fill(Kategoriefarbe.ton(fuer: kategorie).grundfarbe)
                    .frame(width: 8, height: 8)
                    .frame(width: 18, height: 18)
            } aktion: {
                vm.kategorieFilter = kategorie
                ansicht = .umsaetze
            }
        }
    }

    // MARK: - Auswertungen

    @ViewBuilder
    private var auswertungen: some View {
        ForEach(DashboardTab.allCases) { reiter in
            zeile(aktiv: ansicht == .auswertung(reiter),
                  beschriftung: reiter.label,
                  betrag: nil) {
                Image(systemName: reiter.icon)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .frame(width: 18, height: 18)
            } aktion: {
                ansicht = .auswertung(reiter)
            }
        }
    }

    // MARK: - Geld senden

    @ViewBuilder
    private var senden: some View {
        ForEach(Sendeart.allCases) { art in
            zeile(aktiv: ansicht == .senden(art),
                  beschriftung: art.label,
                  betrag: nil) {
                Image(systemName: art.icon)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .frame(width: 18, height: 18)
            } aktion: {
                ansicht = .senden(art)
            }
        }
    }

    // MARK: - Zeile

    @ViewBuilder
    private func zeile<Symbol: View>(aktiv: Bool,
                                     beschriftung: String,
                                     betrag: Double?,
                                     @ViewBuilder symbol: () -> Symbol,
                                     aktion: @escaping () -> Void) -> some View {
        Button(action: aktion) {
            HStack(spacing: 6) {
                symbol()
                Text(beschriftung)
                    .font(ThemeFonts.flyoutBody(size: 12, weight: aktiv ? .semibold : .regular))
                    .foregroundColor(themed ? Color.themedInk : .primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 4)
                if let betrag {
                    Text(Seitenleistenansicht.euro(betrag))
                        .font(ThemeFonts.flyoutBody(size: 11))
                        .monospacedDigit()
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(aktiv ? (farbschema == .dark ? Color.white.opacity(0.11)
                                                       : Color.black.opacity(0.075))
                                : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(aktiv ? [.isSelected] : [])
    }

    private static let waehrung: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.currencyCode = "EUR"
        f.maximumFractionDigits = 2
        return f
    }()

    private static func euro(_ wert: Double) -> String {
        waehrung.string(from: NSNumber(value: wert)) ?? "\(wert)"
    }
}
