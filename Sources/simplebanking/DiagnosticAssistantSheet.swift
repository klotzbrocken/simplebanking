import SwiftUI
import AppKit

// MARK: - DiagnosticAssistantSheet
//
// 3-Phasen-Sheet (idle / running / done) für die Bank-Diagnose. Wird vom
// BalanceBar-Mehr-Menü aufgerufen ("Bank-Diagnose…").
//
// Holt das Master-Passwort über die übergebene `requestMasterPassword`-
// Closure (gleiches Pattern wie TransferSheet). Ohne PW kein Probe — wir
// brauchen verschlüsselte FinTS-Credentials.

@MainActor
struct DiagnosticAssistantSheet: View {

    let requestMasterPassword: () -> String?
    let onClose: () -> Void

    @StateObject private var session = DiagnosticSession()
    @State private var lastError: String? = nil
    @State private var runTask: Task<Void, Never>? = nil
    /// Angehakte Banken. Leer = noch nicht initialisiert; wird beim Erscheinen
    /// mit allen vorbelegt, damit sich am bisherigen Verhalten nichts ändert.
    @State private var auswahl: Set<String> = []
    /// Startzeit der laufenden Bank — für den Hinweis auf eine wartende Freigabe.
    @State private var laufSeit: Date? = nil
    /// Ergebnis der Einrichtungs-Auswertung, sobald sie einmal lief.
    @State private var einrichtungsBericht: SetupDiagnosticsReport.Bericht? = nil
    @State private var einrichtungsFehler: String? = nil

    var body: some View {
        VStack(spacing: 0) {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            Divider().opacity(0.6)
            footer
        }
        .frame(width: 540, height: 580)
        .background(Color.panelBackground)
        .onAppear {
            if auswahl.isEmpty {
                auswahl = Set(MultibankingStore.shared.slots.map(\.id))
            }
        }
        .onDisappear {
            // Beim Schließen: laufende Diagnose-Task cancelen (sonst würde
            // sie weiter Slots aktivieren, Bank-Calls feuern und Traces
            // schreiben), dann Logger-/Slot-Restore via finalize.
            runTask?.cancel()
            Task { await session.finalize() }
        }
    }

    // MARK: - Content per phase

    @ViewBuilder
    private var content: some View {
        switch session.phase {
        case .idle:                       idleView
        case .running(let i, let n, let l):
            runningView(i: i, n: n, label: l)
                // Bei jedem Bankwechsel die Uhr neu stellen, sonst zeigt der
                // Hinweis ab der zweiten Bank sofort an.
                .onChange(of: l) { _ in laufSeit = Date() }
        case .done(let report):           doneView(report: report)
        case .failed(let msg):            errorView(msg: msg)
        }
    }

    // MARK: idle

    private var idleView: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "stethoscope")
                    .font(.system(size: 28, weight: .regular))
                    .foregroundColor(.sbBlueStrong)
                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.t("Bank-Diagnose", "Bank Diagnostics"))
                        .font(.system(size: 16, weight: .semibold))
                    Text(L10n.t(
                        "Probiert Saldo + Umsätze pro Bank und sammelt die Logs für den Support.",
                        "Probes balance + transactions per bank and collects logs for support."))
                        .font(.system(size: 11))
                        .foregroundColor(.sbTextSecondary)
                }
                Spacer()
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(L10n.t("Wird probiert:", "Will be probed:"))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.sbTextSecondary)
                    Spacer()
                    Button(alleGewaehlt ? L10n.t("Keine", "None") : L10n.t("Alle", "All")) {
                        auswahl = alleGewaehlt ? [] : Set(MultibankingStore.shared.slots.map(\.id))
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundColor(.sbBlueStrong)
                }
                // Jede Bank einzeln abwählbar: Ein Probelauf kann eine Freigabe
                // kosten, deshalb soll man einer einzelnen Bank nachgehen können,
                // ohne alle anderen mit anzurufen.
                ForEach(MultibankingStore.shared.slots, id: \.id) { slot in
                    Button {
                        if auswahl.contains(slot.id) { auswahl.remove(slot.id) }
                        else { auswahl.insert(slot.id) }
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: auswahl.contains(slot.id)
                                  ? "checkmark.square.fill" : "square")
                                .font(.system(size: 12))
                                .foregroundColor(auswahl.contains(slot.id)
                                                 ? .sbBlueStrong : .sbTextSecondary)
                                .frame(width: 14)
                            Text(slot.displayName.nilIfEmpty ?? slot.id)
                                .font(.system(size: 12.5, weight: .medium))
                            Text(String(slot.iban.prefix(8)))
                                .font(.system(size: 11).monospacedDigit())
                                .foregroundColor(.sbTextSecondary)
                            Spacer()
                        }
                        .contentShape(Rectangle())
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(
                            RoundedRectangle(cornerRadius: 10).fill(Color.cardBackground)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Label(L10n.t("Diagnose aktiviert verbose-Logging temporär.",
                             "Diagnostics enables verbose logging temporarily."),
                      systemImage: "info.circle")
                    .font(.system(size: 11))
                    .foregroundColor(.sbTextSecondary)
                Label(L10n.t("Master-Passwort wird einmalig abgefragt.",
                             "Master password requested once."),
                      systemImage: "lock.shield")
                    .font(.system(size: 11))
                    .foregroundColor(.sbTextSecondary)
            }

            // Ersteinrichtung: nicht nachspielbar, deshalb wird sie mitgeschrieben und
            // hier im Nachhinein ausgewertet. Ein Knopf „Einrichtung testen" würde bei
            // jedem Druck echte Freigaben kosten.
            Divider().opacity(0.5)
            VStack(alignment: .leading, spacing: 6) {
                Text(L10n.t("Ersteinrichtung", "Initial setup"))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.sbTextSecondary)
                HStack(spacing: 10) {
                    Button(L10n.t("Letzte Einrichtung auswerten …", "Evaluate last setup …")) {
                        werteEinrichtungAus()
                    }
                    if let b = einrichtungsBericht {
                        Button(L10n.t("Im Finder zeigen", "Show in Finder")) {
                            NSWorkspace.shared.activateFileViewerSelecting([b.summaryFile])
                        }
                        Button(L10n.t("Per Mail senden", "Send by email")) {
                            sendeEinrichtung(b)
                        }
                    }
                    Spacer()
                }
                if let b = einrichtungsBericht {
                    Text(L10n.t("Bericht erstellt — \(b.anhaenge.count) Datei(en), \(b.traceAnzahl) Trace(s).",
                                "Report created — \(b.anhaenge.count) file(s), \(b.traceAnzahl) trace(s)."))
                        .font(.system(size: 10.5))
                        .foregroundColor(b.traceAnzahl == 0 ? .sbRedStrong : .sbTextSecondary)
                }
                if let f = einrichtungsFehler {
                    Text(f).font(.system(size: 10.5)).foregroundColor(.sbRedStrong)
                }
            }

            if let err = lastError {
                Text(err)
                    .font(.system(size: 11))
                    .foregroundColor(.sbRedStrong)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 22)
        .padding(.top, 16)
    }

    // MARK: running

    private func runningView(i: Int, n: Int, label: String) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                ProgressView()
                    .controlSize(.small)
                Text(L10n.t("Diagnose läuft …", "Diagnostics running …"))
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
                Text("\(i)/\(n)")
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundColor(.sbTextSecondary)
            }
            Text(L10n.t("Aktuell: \(label)", "Current: \(label)"))
                .font(.system(size: 12))
                .foregroundColor(.sbTextSecondary)

            // Dauert eine Bank auffällig lange, wartet fast immer eine Freigabe in
            // deren App — die Abfrage pollt dann still vor sich hin. Ohne diesen
            // Hinweis sieht man nur einen Balken und weiß nicht, dass man selbst
            // am Zug ist. Die Schwelle ist großzügig, damit sie bei normalen
            // Abrufen (unter zwei Sekunden) gar nicht erst auftaucht.
            TimelineView(.periodic(from: .now, by: 1)) { zeit in
                if let start = laufSeit,
                   zeit.date.timeIntervalSince(start) > 15 {
                    Label(L10n.t(
                        "Wartet auf eine Freigabe — bitte in der App von \(label) bestätigen.",
                        "Waiting for approval — please confirm in the \(label) app."),
                          systemImage: "iphone.and.arrow.forward")
                        .font(.system(size: 11.5))
                        .foregroundColor(.sbBlueStrong)
                }
            }

            // Live Probe-Status der bisher fertigen Slots
            ForEach(session.probes, id: \.slotId) { p in
                probeRow(p)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 22)
        .padding(.top, 16)
    }

    // MARK: done

    private func doneView(report: DiagnosticSession.Report) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 18))
                    .foregroundColor(.sbGreenStrong)
                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.t("Diagnose abgeschlossen", "Diagnostics complete"))
                        .font(.system(size: 14, weight: .semibold))
                    Text(L10n.t("Session \(report.id) · \(report.probes.count) Banken",
                                "Session \(report.id) · \(report.probes.count) banks"))
                        .font(.system(size: 11))
                        .foregroundColor(.sbTextSecondary)
                }
                Spacer()
            }

            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(report.probes, id: \.slotId) { p in
                        probeRow(p)
                    }
                }
            }
            .frame(maxHeight: 280)

            HStack(spacing: 6) {
                Image(systemName: "doc.text.fill")
                    .font(.system(size: 10))
                    .foregroundColor(.sbTextSecondary)
                Text(report.summaryFile.lastPathComponent)
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundColor(.sbTextSecondary)
                Spacer()
                Text(L10n.t("\(report.mailAttachments.count) Anhänge",
                            "\(report.mailAttachments.count) attachments"))
                    .font(.system(size: 11))
                    .foregroundColor(.sbTextSecondary)
            }
        }
        .padding(.horizontal, 22)
        .padding(.top, 16)
    }

    // MARK: error

    private func errorView(msg: String) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "xmark.octagon.fill")
                .font(.system(size: 44))
                .foregroundColor(.sbRedStrong)
            Text(L10n.t("Diagnose fehlgeschlagen", "Diagnostics failed"))
                .font(.system(size: 14, weight: .semibold))
            Text(msg)
                .font(.system(size: 12))
                .foregroundColor(.sbTextSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 16)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 30)
    }

    // MARK: - Probe row (used in running + done)

    private func probeRow(_ p: DiagnosticSession.SlotProbe) -> some View {
        HStack(spacing: 10) {
            // Das Gesamtergebnis, nicht nur der Saldo — sonst steht eine Bank grün
            // da, deren Umsatzabruf gescheitert ist. Genau das war der gemeldete Fall.
            Text(p.gesamt.glyph)
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(glyphColor(p.gesamt))
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(p.bankName)
                    .font(.system(size: 12.5, weight: .medium))
                Text("\(p.ibanPrefix)…  Balance: \(short(p.balance))   Umsätze: \(short(p.transactions))")
                    .font(.system(size: 10.5).monospacedDigit())
                    .foregroundColor(.sbTextSecondary)
                    .lineLimit(1)
            }
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10).fill(Color.cardBackground)
        )
    }

    private func glyphColor(_ r: DiagnosticSession.ProbeResult) -> Color {
        switch r {
        case .ok:      return .sbGreenStrong
        case .failed:  return .sbRedStrong
        case .skipped: return .sbTextSecondary
        }
    }

    private func short(_ r: DiagnosticSession.ProbeResult) -> String {
        switch r {
        case .ok(let ms):              return "\(ms)ms ✓"
        case .failed(_, let ms):       return "\(ms)ms ✗"
        case .skipped:                 return "—"
        }
    }

    // MARK: - Footer

    @ViewBuilder
    private var footer: some View {
        switch session.phase {
        case .idle:    footerIdle
        case .running: footerRunning
        case .done(let r):  footerDone(report: r)
        case .failed:  footerError
        }
    }

    private var footerIdle: some View {
        HStack(spacing: 10) {
            Spacer()
            Button(L10n.t("Schließen", "Close")) { onClose() }
                .keyboardShortcut(.cancelAction)
            Button(action: startSession) {
                HStack(spacing: 6) {
                    Image(systemName: "play.fill").font(.system(size: 11, weight: .semibold))
                    Text(L10n.t("Diagnose starten", "Start diagnostics"))
                        .font(.system(size: 13, weight: .semibold))
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 9)
                .foregroundColor(.white)
                .background(
                    RoundedRectangle(cornerRadius: 8).fill(Color.sbBlueStrong)
                )
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.defaultAction)
            .disabled(auswahl.isEmpty)
            .opacity(auswahl.isEmpty ? 0.5 : 1)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 14)
        .background(Color.panelBackground)
    }

    private var alleGewaehlt: Bool {
        auswahl.count == MultibankingStore.shared.slots.count
    }

    private var footerRunning: some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text(L10n.t("Bitte warten — schalte Banken durch.",
                        "Please wait — switching banks."))
                .font(.system(size: 12))
                .foregroundColor(.sbTextSecondary)
            Spacer()
            // Ohne diesen Knopf blieb nur das Schließen des Fensters. Wartet eine
            // Bank auf eine Freigabe, die nicht kommt, hängt der Lauf sonst
            // dreieinhalb Minuten je Probe.
            Button(L10n.t("Abbrechen", "Cancel")) {
                runTask?.cancel()
                laufSeit = nil
            }
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 14)
        .background(Color.panelBackground)
    }

    private func footerDone(report: DiagnosticSession.Report) -> some View {
        HStack(spacing: 10) {
            Button(L10n.t("Im Finder zeigen", "Show in Finder")) {
                NSWorkspace.shared.activateFileViewerSelecting([report.summaryFile])
            }
            Spacer()
            Button(L10n.t("Schließen", "Close")) { onClose() }
                .keyboardShortcut(.cancelAction)
            Button(action: { sendByMail(report: report) }) {
                HStack(spacing: 6) {
                    Image(systemName: "envelope.fill").font(.system(size: 11, weight: .semibold))
                    Text(L10n.t("Per Mail senden", "Send by email"))
                        .font(.system(size: 13, weight: .semibold))
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 9)
                .foregroundColor(.white)
                .background(
                    RoundedRectangle(cornerRadius: 8).fill(Color.sbBlueStrong)
                )
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 14)
        .background(Color.panelBackground)
    }

    private var footerError: some View {
        HStack {
            Spacer()
            Button(L10n.t("Schließen", "Close")) { onClose() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 14)
        .background(Color.panelBackground)
    }

    // MARK: - Actions

    private func startSession() {
        lastError = nil
        guard let pw = requestMasterPassword() else {
            lastError = L10n.t("Master-Passwort wird benötigt.", "Master password required.")
            return
        }
        // Task speichern, damit .onDisappear und der Abbrechen-Knopf sie cancelen können.
        runTask?.cancel()
        laufSeit = Date()
        let gewaehlt = auswahl
        runTask = Task { await session.run(masterPassword: pw, nurSlots: gewaehlt) }
    }

    private func werteEinrichtungAus() {
        einrichtungsFehler = nil
        do {
            einrichtungsBericht = try SetupDiagnosticsReport.ausLetztemVersuch()
        } catch {
            einrichtungsBericht = nil
            einrichtungsFehler = error.localizedDescription
        }
    }

    private func sendeEinrichtung(_ b: SetupDiagnosticsReport.Bericht) {
        guard let service = NSSharingService(named: .composeEmail) else { return }
        service.recipients = ["support@simplebanking.de"]
        service.subject = "simplebanking Einrichtungs-Diagnose"
        service.perform(withItems: b.anhaenge)
    }

    private func sendByMail(report: DiagnosticSession.Report) {
        guard let service = NSSharingService(named: .composeEmail) else { return }
        service.recipients = ["support@simplebanking.de"]
        service.subject = "simplebanking Bank-Diagnose \(report.id)"
        service.perform(withItems: report.mailAttachments)
    }
}
