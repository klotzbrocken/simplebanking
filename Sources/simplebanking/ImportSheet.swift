import SwiftUI
import AppKit
import UniformTypeIdentifiers

enum ImportSource: Hashable {
    case deepSync180
    case deepSync365
    case ofxFile
    case camtFile
}

@MainActor
struct ImportSheet: View {
    let slotId: String
    let bankDisplayName: String
    /// Called by the sheet when it needs the master password. Return `nil` on user-cancel.
    let requestMasterPassword: () -> String?
    let onClose: () -> Void

    @State private var selection: ImportSource = .deepSync180
    @State private var isRunning: Bool = false
    @State private var statusMessage: String? = nil
    @State private var result: ImportResult? = nil
    @State private var errorMessage: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // ── Header ────────────────────────────────────────
            HStack(spacing: 10) {
                Image(systemName: "arrow.down.doc.fill")
                    .font(.system(size: 22, weight: .regular))
                    .foregroundColor(.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text(t("Umsätze importieren", "Import transactions"))
                        .font(.system(size: 16, weight: .semibold))
                    Text(bankDisplayName)
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }
                Spacer()
            }

            Divider()

            if let result {
                resultView(result)
            } else if let errorMessage {
                errorView(errorMessage)
            } else if isRunning {
                runningView()
            } else {
                sourcePickerView()
            }

            Spacer(minLength: 0)

            // ── Footer ────────────────────────────────────────
            HStack {
                if result != nil || errorMessage != nil {
                    Button(t("Schließen", "Close")) { onClose() }
                        .keyboardShortcut(.defaultAction)
                } else if isRunning {
                    Button(t("Abbrechen", "Cancel")) { onClose() }
                        .disabled(true) // running: cancellation not wired in M2
                } else {
                    Button(t("Abbrechen", "Cancel")) { onClose() }
                        .keyboardShortcut(.cancelAction)
                    Spacer()
                    Button(t("Importieren", "Import")) { Task { await runImport() } }
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(20)
        .frame(width: 460, height: 380)
    }

    // MARK: - Subviews

    private func sourcePickerView() -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(t("Quelle wählen", "Choose source"))
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.secondary)

            radio(.deepSync180,
                  title: t("180 Tage von der Bank laden", "Load 180 days from bank"),
                  subtitle: t("Ca. 6 Monate Historie. Ggf. TAN-Bestätigung nötig.",
                              "About 6 months of history. May require TAN confirmation."))

            radio(.deepSync365,
                  title: t("365 Tage von der Bank laden", "Load 365 days from bank"),
                  subtitle: t("Volles Jahr. Ggf. TAN-Bestätigung nötig.",
                              "Full year. May require TAN confirmation."))

            Divider().padding(.vertical, 2)

            radio(.ofxFile,
                  title: t("OFX-Datei importieren", "Import OFX file"),
                  subtitle: t("DKB, Comdirect u.a. — Datei aus dem Online-Banking auswählen.",
                              "DKB, Comdirect et al. — pick a file from your online banking export."))

            radio(.camtFile,
                  title: t("CAMT.053-Datei importieren", "Import CAMT.053 file"),
                  subtitle: t("SEPA-XML. Fast alle deutschen Banken exportieren dieses Format.",
                              "SEPA XML. Almost every German bank exports this format."))
        }
    }

    private func runningView() -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                ProgressView().scaleEffect(0.8)
                Text(statusMessage ?? t("Lade Umsätze…", "Fetching transactions…"))
                    .font(.system(size: 13))
            }
            Text(t("Dies kann einige Sekunden dauern.", "This may take a few seconds."))
                .font(.system(size: 11))
                .foregroundColor(.secondary)
        }
    }

    private func resultView(_ r: ImportResult) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
                Text(t("Import erfolgreich", "Import successful"))
                    .font(.system(size: 14, weight: .semibold))
            }
            VStack(alignment: .leading, spacing: 4) {
                row(t("Neu importiert", "Newly imported"), "\(r.inserted)")
                row(t("Duplikate übersprungen", "Duplicates skipped"), "\(r.duplicates)")
                row(t("Gesamt verarbeitet", "Total processed"), "\(r.total)")
            }
            if !r.warnings.isEmpty {
                Text(t("Hinweise:", "Notes:"))
                    .font(.system(size: 12, weight: .medium))
                    .padding(.top, 4)
                ForEach(r.warnings, id: \.self) { w in
                    Text("• \(w)").font(.system(size: 11)).foregroundColor(.secondary)
                }
            }
        }
    }

    private func errorView(_ msg: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.orange)
                Text(t("Import fehlgeschlagen", "Import failed"))
                    .font(.system(size: 14, weight: .semibold))
            }
            Text(msg)
                .font(.system(size: 12))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Helpers

    private func radio(_ option: ImportSource, title: String, subtitle: String, disabled: Bool = false) -> some View {
        Button {
            guard !disabled else { return }
            selection = option
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: selection == option ? "largecircle.fill.circle" : "circle")
                    .foregroundColor(disabled ? .secondary : (selection == option ? .accentColor : .secondary))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 13, weight: .medium))
                        .foregroundColor(disabled ? .secondary : .primary)
                    Text(subtitle).font(.system(size: 11)).foregroundColor(.secondary)
                }
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(disabled ? 0.6 : 1)
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).font(.system(size: 12)).foregroundColor(.secondary)
            Spacer()
            Text(value).font(.system(size: 12, weight: .medium))
        }
    }

    // MARK: - Actions

    private func runImport() async {
        errorMessage = nil
        result = nil

        switch selection {
        case .deepSync180, .deepSync365:
            let days = selection == .deepSync180 ? 180 : 365
            await runDeepSync(days: days)
        case .ofxFile:
            await runOfxImport()
        case .camtFile:
            await runCamtImport()
        }
    }

    private func runOfxImport() async {
        guard let url = pickFile(extensions: ["ofx", "qfx"], prompt: t("OFX-Datei wählen", "Choose OFX file")) else {
            return
        }
        isRunning = true
        statusMessage = t("Lese OFX-Datei…", "Reading OFX file…")
        do {
            let r = try OFXImporter.importFile(url: url, slotId: slotId)
            isRunning = false
            result = r
        } catch {
            isRunning = false
            errorMessage = error.localizedDescription
        }
    }

    private func runCamtImport() async {
        guard let url = pickFile(extensions: ["xml", "camt"], prompt: t("CAMT.053-Datei wählen", "Choose CAMT.053 file")) else {
            return
        }
        isRunning = true
        statusMessage = t("Lese CAMT.053-Datei…", "Reading CAMT.053 file…")
        do {
            let r = try Camt053Importer.importFile(url: url, slotId: slotId)
            isRunning = false
            result = r
        } catch {
            isRunning = false
            errorMessage = error.localizedDescription
        }
    }

    /// Show a modal NSOpenPanel to pick a single file with the given extensions.
    private func pickFile(extensions: [String], prompt: String) -> URL? {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = extensions.compactMap { .init(filenameExtension: $0) }
        panel.message = prompt
        return panel.runModal() == .OK ? panel.url : nil
    }

    private func runDeepSync(days: Int) async {
        guard let pw = requestMasterPassword() else {
            // User cancelled master password prompt — silent, return to picker
            return
        }

        isRunning = true
        statusMessage = t("Lade \(days) Tage von der Bank…",
                          "Loading \(days) days from the bank…")
        do {
            let r = try await YaxiDeepSyncImporter.importHistory(
                slotId: slotId,
                days: days,
                masterPassword: pw
            )
            isRunning = false
            result = r
        } catch {
            isRunning = false
            errorMessage = error.localizedDescription
        }
    }

    private func t(_ de: String, _ en: String) -> String {
        // Simple locale dispatch to match the project's t() helper usage
        (Locale.current.language.languageCode?.identifier == "de") ? de : en
    }
}
