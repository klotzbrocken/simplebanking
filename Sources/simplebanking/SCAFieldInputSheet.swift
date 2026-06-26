import AppKit
import SwiftUI

// MARK: - SCAFieldInputPresenter
//
// Bridge zwischen dem `async`-API von `YaxiService.handleSCA` und dem
// modalen NSPanel-Sheet. Aufrufer macht:
//
//     let tan = await SCAFieldInputPresenter.present(spec)
//
// und bekommt den eingegebenen String — oder nil bei Cancel/Close.
//
// Die `fieldInputProvider`-Closure auf `YaxiService` wird einmalig beim
// App-Start in `BalanceBar` auf diesen Presenter verdrahtet.

@MainActor
enum SCAFieldInputPresenter {

    /// Gesetzt (vom Setup-Panel während der Verbindungsprüfung), wenn das Setup-
    /// Fenster gerade per `NSApp.runModal(for:)` **app-modal** läuft. Dann zeigen wir
    /// das TAN-Feld als **verschachtelte modale Session** (eigenes `runModal`), damit
    /// es zuverlässig im Vordergrund erscheint.
    ///
    /// WICHTIG — kein `beginSheet`: Ein `beginSheet` an einem Fenster, das selbst per
    /// `runModal(for:)` app-modal läuft, hängt NICHT als echtes Sheet an, sondern
    /// erscheint als separates Fenster HINTER dem Modal (HVB-Bug: Feld unsichtbar,
    /// taucht erst auf, wenn man das Setup-Fenster schließt).
    nonisolated(unsafe) static weak var hostWindow: NSWindow?

    /// Zeigt das TAN-Feld modal, returnt async den User-Wert oder nil bei Cancel.
    static func present(_ spec: SCAFieldInput.Spec) async -> String? {
        await withCheckedContinuation { (cont: CheckedContinuation<String?, Never>) in
            let inModalSetup = hostWindow != nil

            let panel = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: 380, height: 230),
                styleMask: [.titled, .closable],
                backing: .buffered, defer: false
            )
            panel.title = L10n.t("Bank-Eingabe erforderlich", "Bank input required")
            panel.titlebarAppearsTransparent = false
            panel.isReleasedWhenClosed = false

            if inModalSetup {
                // Verschachtelte modale Session — bringt das Feld VOR das modale
                // Setup-Fenster. `finish` garantiert genau ein `stopModal` (sonst
                // würde ein zweiter Aufruf die ÄUSSERE Setup-Session beenden).
                let coord = SCAModalCoordinator()
                let finish: @MainActor (String?) -> Void = { value in
                    guard !coord.stopped else { return }
                    coord.stopped = true
                    coord.value = value
                    NSApp.stopModal()
                }
                let delegate = SCAFieldInputWindowDelegate { finish(nil) }
                panel.delegate = delegate
                objc_setAssociatedObject(panel, &SCAFieldInputDelegateKey,
                                         delegate, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
                panel.contentView = NSHostingView(rootView: SCAFieldInputView(
                    spec: spec,
                    onSubmit: { finish($0) },
                    onCancel: { finish(nil) }
                ))

                // In einer VERSCHACHTELTEN Modal-Session (das Setup-Fenster läuft schon
                // app-modal) ordnet `runModal(for:)` das innere Fenster NICHT zuverlässig
                // über das äußere — sonst bleibt das TAN-Feld dahinter. Daher explizit
                // nach vorn holen + Level über das Setup-Panel heben.
                panel.level = .modalPanel
                NSApp.activate(ignoringOtherApps: true)
                panel.center()
                panel.makeKeyAndOrderFront(nil)
                NSApp.runModal(for: panel)   // blockiert bis Submit/Cancel/Close
                panel.delegate = nil
                panel.close()
                cont.resume(returning: coord.value)
            } else {
                // Fallback außerhalb des Setups (Refresh/Transfer, kein äußeres
                // Modal): frei schwebendes, nicht-blockierendes Panel — die App
                // bleibt bedienbar. ContinuationBox garantiert genau ein resume.
                let box = ContinuationBox(cont: cont, host: nil)
                let delegate = SCAFieldInputWindowDelegate { box.resolve(nil, panel: panel) }
                panel.delegate = delegate
                objc_setAssociatedObject(panel, &SCAFieldInputDelegateKey,
                                         delegate, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
                panel.contentView = NSHostingView(rootView: SCAFieldInputView(
                    spec: spec,
                    onSubmit: { value in box.resolve(value, panel: panel) },
                    onCancel: { box.resolve(nil, panel: panel) }
                ))
                panel.isFloatingPanel = true
                panel.center()
                panel.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
            }
        }
    }
}

/// Hält Ergebnis + „genau ein stopModal"-Flag für die verschachtelte TAN-Session.
@MainActor
private final class SCAModalCoordinator {
    var value: String?
    var stopped = false
}

private nonisolated(unsafe) var SCAFieldInputDelegateKey: UInt8 = 0

/// Idempotenter Wrapper für die Continuation — verhindert doppeltes resume,
/// wenn Submit + Window-Close kurz hintereinander feuern.
@MainActor
private final class ContinuationBox {
    private var cont: CheckedContinuation<String?, Never>?
    private weak var host: NSWindow?
    init(cont: CheckedContinuation<String?, Never>, host: NSWindow?) {
        self.cont = cont
        self.host = host
    }
    func resolve(_ value: String?, panel: NSPanel) {
        guard let c = cont else { return }
        cont = nil
        if let host { host.endSheet(panel) } else { panel.close() }
        c.resume(returning: value)
    }
}

private final class SCAFieldInputWindowDelegate: NSObject, NSWindowDelegate {
    let onClose: @MainActor () -> Void
    init(onClose: @escaping @MainActor () -> Void) { self.onClose = onClose }
    func windowWillClose(_ notification: Notification) {
        MainActor.assumeIsolated { onClose() }
    }
}

// MARK: - View

private struct SCAFieldInputView: View {
    let spec: SCAFieldInput.Spec
    let onSubmit: (String) -> Void
    let onCancel: () -> Void

    @State private var value: String = ""
    @FocusState private var focused: Bool

    private var promptText: String {
        if let m = spec.msg?.trimmingCharacters(in: .whitespacesAndNewlines), !m.isEmpty { return m }
        return L10n.t(
            "Bitte gib den von der Bank angeforderten Code ein.",
            "Please enter the code requested by your bank."
        )
    }

    private var isValid: Bool { SCAFieldInput.isValid(value, spec: spec) }
    private var isSecure: Bool {
        spec.secrecyLevel == .otp || spec.secrecyLevel == .password
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(spec.bankDisplayName)
                .font(.system(size: 15, weight: .semibold))
            // Challenge-Text der Bank anzeigen, falls vorhanden (z.B. „TAN an
            // ***1234"); sonst generischer Hinweis.
            Text(promptText)
                .font(.system(size: 12))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Group {
                if isSecure {
                    SecureField("", text: $value)
                        .focused($focused)
                } else {
                    TextField("", text: $value)
                        .focused($focused)
                }
            }
            .textFieldStyle(.roundedBorder)
            .font(.system(size: 18, weight: .medium).monospacedDigit())
            .onSubmit { if isValid { onSubmit(value) } }

            let hint = SCAFieldInput.hint(for: spec)
            if !hint.isEmpty {
                Text(hint)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }

            Spacer(minLength: 4)

            HStack {
                Spacer()
                Button(L10n.t("Abbrechen", "Cancel")) { onCancel() }
                    .keyboardShortcut(.cancelAction)
                Button(L10n.t("Bestätigen", "Confirm")) { onSubmit(value) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!isValid)
            }
        }
        .padding(20)
        .frame(width: 380, height: 230)
        .onAppear { focused = true }
    }
}
