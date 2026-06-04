import SwiftUI

// MARK: - Satz-Darstellung (farbcodierter AttributedString)

private enum RuleSentence {
    static func make(conditions: [RuleCondition], setCategory: TransactionCategory?,
                     recurring: RecurringAction?, full: Bool) -> AttributedString {
        var s = AttributedString()
        func add(_ t: String, _ color: Color, bold: Bool = false) {
            var a = AttributedString(t)
            a.foregroundColor = color
            a.font = .system(size: 13, weight: bold ? .semibold : .regular)
            s += a
        }
        let tert = Color(NSColor.tertiaryLabelColor)
        let q1 = "\u{201E}", q2 = "\u{201C}"  // „ "

        add("Wenn ", .sbBlueStrong, bold: true)
        if conditions.isEmpty {
            add(full ? "…eine Buchung deine Bedingung erfüllt" : "…", tert)
        } else {
            for (i, c) in conditions.enumerated() {
                if i > 0 { add(c.joiner == .all ? " und " : " oder ", tert) }
                add(c.field.label + " ", .sbBlueStrong)
                add(c.op.label, tert)
                if !c.value.isEmpty { add(" \(q1)\(c.value)\(q2)", .primary, bold: true) }
            }
        }

        var actions: [(label: String, color: Color)] = []
        if let cat = setCategory { actions.append((cat.displayName, .incomeGreen)) }
        if let r = recurring { actions.append((r.label, r == .exclude ? .expenseRed : .sbBlueStrong)) }

        if full {
            add(", dann ", .sbGreenStrong, bold: true)
            if actions.isEmpty {
                add("wähle unten eine Aktion", tert)
            } else {
                for (i, a) in actions.enumerated() {
                    if i > 0 { add(" und ", tert) }
                    if i == 0, setCategory != nil { add("setze die Kategorie auf ", tert) }
                    else if recurring != nil { add("markiere als ", tert) }
                    add(a.label, a.color, bold: true)
                }
            }
            add(".", tert)
        } else {
            add(" → ", tert)
            if actions.isEmpty { add("—", tert) }
            else {
                for (i, a) in actions.enumerated() {
                    if i > 0 { add(" + ", tert) }
                    add(a.label, a.color, bold: true)
                }
            }
        }
        return s
    }
}

// MARK: - Regeln & Zuordnungen

struct RulesManagerView: View {
    var embedded: Bool = false
    var transactions: [TransactionsResponse.Transaction] = []

    @Environment(\.dismiss) private var dismiss

    @State private var rules: [AssignmentRule] = []
    @State private var merchantRules: [MerchantUserRule] = []
    @State private var assignments: RecurringAssignments = .init()
    @State private var showAssistant = false
    @State private var applyStatus: String = ""
    @State private var expandRules = true
    @State private var expandMerchant = false
    @State private var expandMarks = false

    private func reload() {
        rules = AssignmentRules.all()
        merchantRules = MerchantResolver.userRules()
        assignments = RecurringAssignments.current()
    }

    private func scopeLabel(_ scope: MerchantUserRule.MatchScope) -> String {
        switch scope {
        case .searchText:       return "Volltext"
        case .empfaenger:       return "Empfänger"
        case .verwendungszweck: return "Zweck"
        case .endToEndId:       return "E2E-ID"
        }
    }

    var body: some View {
        Group {
            if showAssistant {
                RuleAssistantView(
                    transactions: transactions,
                    onBack: { withAnimation(.easeOut(duration: 0.22)) { showAssistant = false } },
                    onSave: { rule, scope in
                        if let rule {
                            AssignmentRules.add(rule)
                            if let scope { apply(rule, scope: scope) }
                        }
                        reload()
                        withAnimation(.easeOut(duration: 0.22)) { showAssistant = false }
                    }
                )
                .transition(.move(edge: .trailing).combined(with: .opacity))
            } else {
                listBody
            }
        }
        .frame(width: embedded ? nil : 560, height: embedded ? nil : 660)
        .frame(maxWidth: embedded ? .infinity : nil, maxHeight: embedded ? .infinity : nil)
        .background(Color.panelBackground)
        .onAppear { reload() }
    }

    private var listBody: some View {
        VStack(spacing: 0) {
            TabHeader("Regeln & Zuordnungen",
                      subtitle: "Lege fest, wie Buchungen automatisch einsortiert werden.") {
                Button { withAnimation(.easeOut(duration: 0.22)) { showAssistant = true } } label: {
                    Label("Neue Regel", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
            }
            Divider()

            if !applyStatus.isEmpty {
                Text(applyStatus).font(.system(size: 12)).foregroundColor(.sbGreenStrong)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 20).padding(.top, 8)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    rulesSection
                    merchantSection
                    markSection
                }
                .padding(20)
            }
        }
    }

    // MARK: Section 1 — Zuordnungs-Regeln

    private var rulesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            collapsibleHeader("Zuordnungs-Regeln", systemImage: "slider.horizontal.3", count: rules.count, isOpen: $expandRules,
                              hint: "Automatische Kategorie- und Markierungs-Regeln. Werden von oben nach unten geprüft.",
                              color: .sbBlueStrong)
            if expandRules {
                if rules.isEmpty {
                    emptyHint("Noch keine Regeln. Über Neue Regel eine anlegen.")
                } else {
                    ForEach(rules) { rule in ruleCard(rule) }
                }
            }
        }
    }

    private func ruleCard(_ rule: AssignmentRule) -> some View {
        let affected = matchCount(rule)
        return HStack(alignment: .top, spacing: 12) {
            Toggle("", isOn: Binding(
                get: { rule.enabled },
                set: { v in var r = rule; r.enabled = v; AssignmentRules.update(r); reload() }
            ))
            .labelsHidden().toggleStyle(.switch).controlSize(.mini)

            VStack(alignment: .leading, spacing: 3) {
                Text(RuleSentence.make(conditions: rule.conditions, setCategory: rule.setCategory,
                                       recurring: rule.recurring, full: false))
                    .fixedSize(horizontal: false, vertical: true)
                Text(rule.enabled ? "\(affected) Buchungen betroffen" : "Deaktiviert")
                    .font(.system(size: 11)).foregroundColor(.secondary)
            }
            Spacer(minLength: 8)
            Menu {
                Button("Aktuelles Konto") { apply(rule, scope: "__current") }
                Button("Alle Konten") { apply(rule, scope: "__all") }
                Divider()
                ForEach(MultibankingStore.shared.slots) { s in
                    Button(s.nickname ?? s.displayName) { apply(rule, scope: s.id) }
                }
            } label: { Image(systemName: "arrow.triangle.2.circlepath").foregroundColor(.secondary) }
            .menuStyle(.borderlessButton).fixedSize().help("Auf bestehende Buchungen anwenden")

            Button(role: .destructive) { AssignmentRules.remove(id: rule.id); reload() } label: {
                Image(systemName: "trash").foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(14)
        .opacity(rule.enabled ? 1 : 0.55)
        .accentCard(.sbBlueStrong)
    }

    private func matchCount(_ rule: AssignmentRule) -> Int {
        let map = AssignmentRules.cadenceMap(for: transactions)
        return transactions.filter { rule.matches($0, cadence: AssignmentRules.cadence(for: $0, map: map)) }.count
    }

    // MARK: Section 2 — Händler-Namen

    private var merchantSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            collapsibleHeader("Händler-Namen", systemImage: "building.2", count: merchantRules.count, isOpen: $expandMerchant,
                              hint: "Vereinheitlicht kryptische Kontoauszug-Texte zu sauberen Händlernamen.",
                              color: .sbOrangeStrong)
            if expandMerchant {
                if merchantRules.isEmpty {
                    emptyHint("Noch keine Händler-Regeln.")
                } else {
                    ForEach(merchantRules) { rule in
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(rule.pattern) → \(rule.merchant)").font(.system(size: 13, weight: .medium)).lineLimit(1)
                            Text("\(scopeLabel(rule.matchScope)) · \(rule.matchType.rawValue)\(rule.enabled ? "" : " · aus")")
                                .font(.system(size: 11)).foregroundColor(.secondary)
                        }
                        Spacer()
                        Button(role: .destructive) { _ = MerchantResolver.removeRule(id: rule.id); reload() } label: {
                            Image(systemName: "trash").foregroundColor(.secondary)
                        }.buttonStyle(.plain)
                    }
                    .padding(14).opacity(rule.enabled ? 1 : 0.55).accentCard(.sbOrangeStrong)
                    }
                }
            }
        }
    }

    // MARK: Section 3 — Eigene Regeln (manuelle Markierungen)

    private var markSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            collapsibleHeader("Eigene Regeln", systemImage: "checkmark.seal", count: assignments.byKey.count, isOpen: $expandMarks,
                              hint: "Einzelne Händler, die du selbst als Abo/Fixkost bestätigt oder ausgeschlossen hast.",
                              color: .sbGreenStrong)
            let entries = assignments.byKey.sorted { $0.key < $1.key }
            if expandMarks {
                if entries.isEmpty {
                    emptyHint("Keine manuellen Markierungen.")
                } else {
                    ForEach(entries, id: \.key) { key, a in
                    HStack(spacing: 10) {
                        Image(systemName: a.state == .excluded ? "xmark.circle" : "checkmark.circle")
                            .foregroundColor(a.state == .excluded ? .sbRedStrong : .sbGreenStrong)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(key.isEmpty ? key : key.prefix(1).uppercased() + key.dropFirst())
                                .font(.system(size: 13, weight: .medium)).lineLimit(1)
                            Text(markSubtitle(a)).font(.system(size: 11)).foregroundColor(.secondary)
                        }
                        Spacer()
                        Button(role: .destructive) {
                            assignments = assignments.setting(key) { $0.state = .neutral; $0.tab = nil }
                            assignments.save(); reload()
                        } label: { Image(systemName: "trash").foregroundColor(.secondary) }
                        .buttonStyle(.plain).help("Markierung entfernen")
                    }
                    .padding(14).accentCard(.sbGreenStrong)
                    }
                }
            }
        }
    }

    private func markSubtitle(_ a: RecurringAssignment) -> String {
        switch a.state {
        case .excluded:  return "ausgeschlossen"
        case .confirmed: return a.tab.map { "bestätigt · \($0)" } ?? "bestätigt"
        case .neutral:   return a.tab ?? "—"
        }
    }

    // MARK: Apply (Konto-Scope)

    private func transactions(forScope scope: String) -> [TransactionsResponse.Transaction] {
        switch scope {
        case "__current": return transactions
        case "__all":
            let ids = MultibankingStore.shared.slots.map { $0.id }
            return (try? TransactionsDatabase.loadUnifiedTransactions(slots: ids, days: 365)) ?? transactions
        default:
            return (try? TransactionsDatabase.loadUnifiedTransactions(slots: [scope], days: 365)) ?? []
        }
    }

    private func apply(_ rule: AssignmentRule, scope: String) {
        let txs = transactions(forScope: scope)
        let map = AssignmentRules.cadenceMap(for: txs)
        var count = 0
        if let cat = rule.setCategory {
            for tx in txs where rule.matches(tx, cadence: AssignmentRules.cadence(for: tx, map: map)) {
                let fp = TransactionRecord.fingerprint(for: tx)
                let slot = tx.slotId ?? TransactionsDatabase.activeSlotId
                TransactionCategorizer.saveOverride(txID: fp, slotId: slot, category: cat)
                try? TransactionsDatabase.updateKategorie(txID: fp, slotId: slot, kategorie: cat.displayName)
                count += 1
            }
        }
        if rule.recurring != nil {
            let matched = AssignmentRules.matchingTransactions(rule, in: txs, cadenceMap: map)
            AssignmentRules.applyRecurring(rule, to: matched)
            count = max(count, matched.count)
        }
        applyStatus = "Auf \(count) Buchung(en) angewendet."
        reload()
    }

    // MARK: Building blocks

    private func collapsibleHeader(_ title: String, systemImage: String, count: Int,
                                   isOpen: Binding<Bool>, hint: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Button { withAnimation(.easeOut(duration: 0.18)) { isOpen.wrappedValue.toggle() } } label: {
                HStack(spacing: 6) {
                    Image(systemName: isOpen.wrappedValue ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10, weight: .bold)).foregroundColor(.secondary)
                    Image(systemName: systemImage).font(.system(size: 11)).foregroundColor(color)
                    Text(title.uppercased()).font(.system(size: 12, weight: .bold)).foregroundColor(.secondary).tracking(0.4)
                    Spacer()
                    Text("\(count)").font(.system(size: 11, weight: .semibold)).foregroundColor(color)
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(Capsule().fill(color.opacity(0.13)))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if isOpen.wrappedValue {
                Text(hint).font(.system(size: 12)).foregroundColor(.secondary)
            }
        }
        .padding(.bottom, 2)
    }

    private func emptyHint(_ text: String) -> some View {
        Text(text).font(.system(size: 12)).foregroundColor(.secondary)
            .padding(.horizontal, 12).padding(.vertical, 8)
    }
}

// MARK: - Inline-Regelassistent

private struct RuleAssistantView: View {
    let transactions: [TransactionsResponse.Transaction]
    let onBack: () -> Void
    /// (Regel, applyScope) — nil = nur speichern; sonst zusätzlich anwenden.
    let onSave: (AssignmentRule?, String?) -> Void

    @State private var conditions: [RuleCondition] = [RuleCondition()]
    @State private var setCategory: TransactionCategory? = nil
    @State private var recurring: RecurringAction? = nil
    @State private var merchantName: String = ""
    @State private var categoryEnabled = true
    @State private var recurringEnabled = false
    @State private var merchantEnabled = false
    @State private var applyScope: String = "__current"
    @State private var cadenceMap: [String: PaymentFrequency] = [:]

    private var validConditions: [RuleCondition] {
        conditions.filter { !$0.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || $0.field.fixedOptions != nil }
    }
    private var effectiveCategory: TransactionCategory? { categoryEnabled ? setCategory : nil }
    private var effectiveRecurring: RecurringAction? { recurringEnabled ? recurring : nil }
    private var draft: AssignmentRule {
        AssignmentRules.make(conditions: validConditions, setCategory: effectiveCategory, recurring: effectiveRecurring)
    }
    private var matches: [TransactionsResponse.Transaction] {
        validConditions.isEmpty ? [] : transactions.filter { draft.matches($0, cadence: AssignmentRules.cadence(for: $0, map: cadenceMap)) }
    }
    private var merchantNameTrimmed: String { merchantName.trimmingCharacters(in: .whitespacesAndNewlines) }
    /// Erste Text-Bedingung — Basis für die Händler-Regel (Muster + Scope).
    private var firstTextCondition: RuleCondition? {
        validConditions.first {
            [.searchText, .empfaenger, .verwendungszweck, .endToEndId, .merchant].contains($0.field)
                && [.contains, .equals].contains($0.op)
        }
    }
    private var merchantActionReady: Bool { merchantEnabled && !merchantNameTrimmed.isEmpty && firstTextCondition != nil }
    private var canSave: Bool {
        !validConditions.isEmpty && (effectiveCategory != nil || effectiveRecurring != nil || merchantActionReady)
    }

    /// Speichert: ggf. Händler-Regel (MerchantUserRule) + ggf. Zuordnungs-Regel (AssignmentRule).
    private func performSave(scope: String?) {
        if merchantActionReady, let tc = firstTextCondition {
            let s: MerchantUserRule.MatchScope = {
                switch tc.field {
                case .empfaenger:       return .empfaenger
                case .verwendungszweck: return .verwendungszweck
                case .endToEndId:       return .endToEndId
                default:                return .searchText
                }
            }()
            MerchantResolver.saveRule(pattern: tc.value, merchant: merchantNameTrimmed,
                                      scope: s, matchType: tc.op == .equals ? .equals : .contains)
        }
        let hasAssignment = effectiveCategory != nil || effectiveRecurring != nil
        onSave(hasAssignment ? draft : nil, hasAssignment ? scope : nil)
    }

    var body: some View {
        VStack(spacing: 0) {
            // Kopf mit Zurück-Link
            VStack(alignment: .leading, spacing: 3) {
                Button(action: onBack) {
                    Label("Regeln", systemImage: "chevron.left").font(.system(size: 13)).foregroundColor(.sbBlueStrong)
                }
                .buttonStyle(.plain)
                Text("Neue Regel").font(.system(size: 20, weight: .bold))
                Text("Bedingungen festlegen · Aktion wählen · Treffer live prüfen")
                    .font(.system(size: 12.5)).foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20).padding(.top, 14).padding(.bottom, 13)
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    readbackBanner
                    stepOne
                    stepTwo
                    preview
                }
                .padding(20)
            }

            Divider()
            footer
        }
        .background(Color.panelBackground)
        .onAppear { cadenceMap = AssignmentRules.cadenceMap(for: transactions) }
    }

    // A) Readback-Banner
    private var readbackBanner: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "sparkles").foregroundColor(.sbBlueStrong)
            Text(RuleSentence.make(conditions: validConditions, setCategory: effectiveCategory,
                                   recurring: effectiveRecurring, full: true))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.sbBlueSoft)
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.sbBlueStrong.opacity(0.25), lineWidth: 1))
        )
    }

    // B) Schritt 1
    private var stepOne: some View {
        VStack(alignment: .leading, spacing: 8) {
            stepLabel(1, "Wenn …", "welche Buchungen sollen erfasst werden?")
            ForEach(Array(conditions.enumerated()), id: \.element.id) { i, _ in
                HStack(alignment: .center, spacing: 8) {
                    // Verbinder-Spalte: WENN bzw. platzsparender UND/ODER-Toggle
                    Group {
                        if i == 0 {
                            Text("WENN").font(.system(size: 11, weight: .bold)).foregroundColor(Color(NSColor.tertiaryLabelColor))
                        } else {
                            let isAnd = conditions[i].joiner == .all
                            Button { conditions[i].joiner = isAnd ? .any : .all } label: {
                                Text(isAnd ? "UND" : "ODER")
                                    .font(.system(size: 11, weight: .bold))
                                    .foregroundColor(.sbBlueStrong)
                                    .frame(width: 44, height: 22)
                                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.sbBlueSoft)
                                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.sbBlueStrong.opacity(0.3), lineWidth: 1)))
                            }
                            .buttonStyle(.plain)
                            .help("Umschalten UND/ODER")
                        }
                    }
                    .frame(width: 50, alignment: .leading)

                    conditionBox($conditions[i])

                    if conditions.count > 1 {
                        let rowID = conditions[i].id
                        Button { conditions.removeAll { $0.id == rowID } } label: {
                            Image(systemName: "minus.circle").foregroundColor(.secondary)
                        }.buttonStyle(.plain)
                    } else {
                        Spacer().frame(width: 18)
                    }
                }
            }
            Button { conditions.append(RuleCondition()) } label: {
                Label("Bedingung hinzufügen", systemImage: "plus").font(.system(size: 13))
            }
            .buttonStyle(.plain).foregroundColor(.sbBlueStrong).padding(.leading, 58)
        }
    }

    private func setField(_ c: Binding<RuleCondition>, _ f: RuleField) {
        c.field.wrappedValue = f
        if !RuleOperator.options(for: f).contains(c.op.wrappedValue) {
            c.op.wrappedValue = RuleOperator.options(for: f).first ?? .contains
        }
        if let opts = f.fixedOptions {
            if !opts.contains(c.value.wrappedValue) { c.value.wrappedValue = opts.first ?? "" }
        } else {
            let fixed = Set((RuleField.direction.fixedOptions ?? []) + (RuleField.interval.fixedOptions ?? []))
            if fixed.contains(c.value.wrappedValue) { c.value.wrappedValue = "" }
        }
    }

    @ViewBuilder
    private func conditionBox(_ c: Binding<RuleCondition>) -> some View {
        HStack(spacing: 8) {
            // Feld-Menu (Button-Liste mit Häkchen)
            Menu {
                ForEach(RuleField.allCases, id: \.self) { f in
                    Button { setField(c, f) } label: {
                        Label(f.label, systemImage: c.wrappedValue.field == f ? "checkmark" : f.icon)
                    }
                }
            } label: { MenuTriggerLabel(text: c.wrappedValue.field.label, systemImage: c.wrappedValue.field.icon) }
            .menuStyle(.borderlessButton).frame(width: 140)

            // Operator-Menu
            Menu {
                ForEach(RuleOperator.options(for: c.wrappedValue.field), id: \.self) { o in
                    Button { c.op.wrappedValue = o } label: { menuCheckItem(o.label, selected: c.wrappedValue.op == o) }
                }
            } label: { MenuTriggerLabel(text: c.wrappedValue.op.label) }
            .menuStyle(.borderlessButton).frame(width: 120)

            // Wert — fixedOptions als Menu, sonst flexibles Textfeld
            if let opts = c.wrappedValue.field.fixedOptions {
                Menu {
                    ForEach(opts, id: \.self) { o in
                        Button { c.value.wrappedValue = o } label: { menuCheckItem(o, selected: c.wrappedValue.value == o) }
                    }
                } label: { MenuTriggerLabel(text: c.wrappedValue.value.isEmpty ? (opts.first ?? "—") : c.wrappedValue.value) }
                .menuStyle(.borderlessButton).frame(width: 150)
                Spacer(minLength: 0)
            } else {
                TextField(c.wrappedValue.field.isAmount ? "Betrag in €" : "Text eingeben …", text: c.value)
                    .textFieldStyle(.plain)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.sbInputTint)
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.sbBorder, lineWidth: 1)))
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.cardBackground)
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.sbBorder, lineWidth: 1)))
    }

    // C) Schritt 2
    private var stepTwo: some View {
        VStack(alignment: .leading, spacing: 8) {
            stepLabel(2, "Dann …", "was soll mit diesen Buchungen passieren?", color: .sbGreenStrong)
            actionCard(
                on: $categoryEnabled, icon: "tag", title: "Kategorie setzen",
                desc: "Ordnet die Buchung einer Ausgaben-Kategorie zu.",
                accent: .sbGreenStrong
            ) {
                Menu {
                    ForEach(TransactionCategory.allCases, id: \.self) { c in
                        Button { setCategory = c } label: { menuCheckItem(c.displayName, selected: setCategory == c) }
                    }
                } label: { MenuTriggerLabel(text: setCategory?.displayName ?? "wählen …") }
                .menuStyle(.borderlessButton).fixedSize().disabled(!categoryEnabled)
            }
            actionCard(
                on: $recurringEnabled, icon: "repeat", title: "Als wiederkehrend markieren",
                desc: "Erscheint dann unter Abos & Verträge.",
                accent: .sbBlueStrong, danger: recurring == .exclude
            ) {
                Menu {
                    ForEach(RecurringAction.allCases, id: \.self) { r in
                        Button { recurring = r } label: { menuCheckItem(r.label, selected: recurring == r) }
                    }
                } label: { MenuTriggerLabel(text: recurring?.label ?? "wählen …") }
                .menuStyle(.borderlessButton).fixedSize().disabled(!recurringEnabled)
            }
            actionCard(
                on: $merchantEnabled, icon: "character.cursor.ibeam", title: "Händlername setzen",
                desc: "Vereinheitlicht den angezeigten Namen (z. B. AMZN MKTP → Amazon).",
                accent: .sbOrangeStrong
            ) {
                TextField("Name", text: $merchantName)
                    .textFieldStyle(.plain).frame(width: 150)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.sbInputTint)
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.sbBorder, lineWidth: 1)))
                    .disabled(!merchantEnabled)
            }
            if merchantEnabled, firstTextCondition == nil {
                Text("Für die Händler-Regel braucht es eine Text-Bedingung (Volltext/Empfänger/Zweck enthält/ist).")
                    .font(.system(size: 11)).foregroundColor(.sbOrangeStrong).padding(.leading, 4)
            }
        }
    }

    @ViewBuilder
    private func actionCard<Trailing: View>(on: Binding<Bool>, icon: String, title: String, desc: String,
                                            accent: Color, danger: Bool = false,
                                            @ViewBuilder trailing: () -> Trailing) -> some View {
        // Aktionstyp-Farbe; `exclude` (danger) überschreibt mit Rot.
        let ac = danger ? Color.sbRedStrong : accent
        HStack(spacing: 12) {
            Button { on.wrappedValue.toggle() } label: {
                Image(systemName: on.wrappedValue ? "checkmark.square.fill" : "square")
                    .font(.system(size: 18)).foregroundColor(on.wrappedValue ? ac : .secondary)
            }.buttonStyle(.plain)
            Image(systemName: icon).foregroundColor(ac)   // Icon trägt die Farbe immer (Identität)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(desc).font(.system(size: 11)).foregroundColor(.secondary)
            }
            Spacer()
            trailing().opacity(on.wrappedValue ? 1 : 0.4)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(on.wrappedValue ? ac.opacity(0.04) : Color.cardBackground)
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(on.wrappedValue ? ac : Color.sbBorder, lineWidth: on.wrappedValue ? 2.5 : 1))
        )
    }

    // D) Vorschau
    private var preview: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Vorschau").font(.system(size: 12, weight: .bold)).foregroundColor(.secondary).tracking(0.4)
                Spacer()
                Text("\(matches.count) von \(transactions.count) Buchungen").font(.system(size: 12)).foregroundColor(.secondary)
            }
            if matches.isEmpty {
                Text("Noch keine Treffer — gib oben eine Bedingung ein.")
                    .font(.system(size: 12)).foregroundColor(.secondary).padding(.vertical, 8)
            } else {
                ForEach(Array(matches.prefix(12).enumerated()), id: \.offset) { _, tx in
                    Button { applyFromTransaction(tx) } label: { previewRow(tx) }.buttonStyle(.plain)
                }
                Text("Tipp: Auf eine Buchung tippen, um die Bedingungen daraus zu übernehmen.")
                    .font(.system(size: 11)).foregroundColor(.secondary).padding(.top, 2)
            }
        }
    }

    @ViewBuilder
    private func previewRow(_ tx: TransactionsResponse.Transaction) -> some View {
        let merchant = FixedCostsAnalyzer.merchantName(for: tx)
        let source = tx.parsedAmount < 0 ? (tx.creditor?.name ?? "") : (tx.debtor?.name ?? "")
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text(highlightedName(merchant)).lineLimit(1)
                if !source.isEmpty, source.caseInsensitiveCompare(merchant) != .orderedSame {
                    Text("\(tx.parsedAmount < 0 ? "Empfänger" : "Absender"): \(source)")
                        .font(.system(size: 10)).foregroundColor(.secondary).lineLimit(1)
                }
            }
            Spacer()
            Text(String(tx.bookingDate?.prefix(10) ?? "")).font(.system(size: 11)).foregroundColor(.secondary)
            Text(String(format: "%.2f €", tx.parsedAmount))
                .font(.system(size: 12, weight: .medium)).monospacedDigit()
                .foregroundColor(tx.parsedAmount < 0 ? .expenseRed : .incomeGreen)
                .frame(width: 90, alignment: .trailing)
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.cardBackground)
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.sbBorder, lineWidth: 1)))
        .contentShape(Rectangle())
    }

    // E) Footer
    private var footer: some View {
        HStack(spacing: 10) {
            Image(systemName: "tray.full").font(.system(size: 12)).foregroundColor(.secondary)
            Text("Anwenden auf").font(.system(size: 12)).foregroundColor(.secondary)
            Menu {
                Button { applyScope = "__current" } label: { menuCheckItem("Aktuelles Konto", selected: applyScope == "__current") }
                Button { applyScope = "__all" } label: { menuCheckItem("Alle Konten", selected: applyScope == "__all") }
                Divider()
                ForEach(MultibankingStore.shared.slots) { s in
                    Button { applyScope = s.id } label: { menuCheckItem(s.nickname ?? s.displayName, selected: applyScope == s.id) }
                }
            } label: { MenuTriggerLabel(text: scopeName) }
            .menuStyle(.borderlessButton).fixedSize()
            Spacer()
            Button("Abbrechen", action: onBack)
            Button("Nur speichern") { performSave(scope: nil) }.disabled(!canSave)
            Button("Speichern & anwenden") { performSave(scope: applyScope) }
                .buttonStyle(.borderedProminent).disabled(!canSave)
        }
        .padding(.horizontal, 20).padding(.vertical, 12)
    }

    private var scopeName: String {
        switch applyScope {
        case "__current": return "Aktuelles Konto"
        case "__all":     return "Alle Konten"
        default:          return MultibankingStore.shared.slots.first { $0.id == applyScope }.map { $0.nickname ?? $0.displayName } ?? "Konto"
        }
    }

    private func stepLabel(_ n: Int, _ title: String, _ hint: String, color: Color = .sbBlueStrong) -> some View {
        HStack(spacing: 8) {
            Text("\(n)").font(.system(size: 12, weight: .bold)).foregroundColor(.white)
                .frame(width: 20, height: 20).background(Circle().fill(color))
            Text(title).font(.system(size: 15, weight: .semibold))
            Text(hint).font(.system(size: 12)).foregroundColor(.secondary)
        }
    }

    /// Suchbegriff der ersten Text-Bedingung (für Vorschau-Highlight).
    private var highlightTerm: String? {
        validConditions.first {
            [.searchText, .empfaenger, .verwendungszweck].contains($0.field) && [.contains, .equals].contains($0.op)
        }?.value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func highlightedName(_ name: String) -> AttributedString {
        var a = AttributedString(name)
        a.font = .system(size: 12, weight: .medium)
        if let term = highlightTerm, !term.isEmpty, let r = a.range(of: term, options: .caseInsensitive) {
            a[r].backgroundColor = Color.sbOrangeStrong.opacity(0.28)
        }
        return a
    }

    private func applyFromTransaction(_ tx: TransactionsResponse.Transaction) {
        let merchant = FixedCostsAnalyzer.merchantName(for: tx).trimmingCharacters(in: .whitespacesAndNewlines)
        let hay = RuleInput(tx).text(for: .searchText)
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "de_DE")).lowercased()
        let m = merchant.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "de_DE")).lowercased()
        var conds: [RuleCondition] = []
        if !merchant.isEmpty, hay.contains(m) {
            conds.append(RuleCondition(field: .searchText, op: .contains, value: merchant))
        } else if let p = tx.creditor?.name, !p.isEmpty {
            conds.append(RuleCondition(field: .empfaenger, op: .equals, value: p))
        } else if let a = tx.debtor?.name, !a.isEmpty {
            conds.append(RuleCondition(field: .absender, op: .equals, value: a))
        }
        conds.append(RuleCondition(field: .amount, op: .amountEquals, value: String(format: "%.2f", abs(tx.parsedAmount))))
        conditions = conds.isEmpty ? [RuleCondition()] : conds
    }
}
