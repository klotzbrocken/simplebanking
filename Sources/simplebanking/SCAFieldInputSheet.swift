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

    /// Wenn gesetzt (vom Setup-Panel während der Verbindungsprüfung), wird das
    /// Field-Input als **Sheet an diesem Fenster** gezeigt — statt als frei
    /// schwebendes NSPanel + `NSApp.activate`. Das verhindert die Fokus-/Modal-
    /// Störung, die sonst den Connect-Task cancelt (HVB-„CancellationError"-Bug).
    nonisolated(unsafe) static weak var hostWindow: NSWindow?

    /// Zeigt das Sheet modal, returnt async den User-Wert oder nil bei Cancel.
    static func present(_ spec: SCAFieldInput.Spec) async -> String? {
        await withCheckedContinuation { (cont: CheckedContinuation<String?, Never>) in
            let host = hostWindow
            // Hosting-Container — der Closure-Capture stellt sicher, dass nur
            // genau einmal `cont.resume` aufgerufen wird, egal ob Submit,
            // Cancel oder Window-Close den Flow beendet.
            let box = ContinuationBox(cont: cont, host: host)

            let panel = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: 380, height: 230),
                styleMask: [.titled, .closable],
                backing: .buffered, defer: false
            )
            panel.title = L10n.t("Bank-Eingabe erforderlich", "Bank input required")
            panel.titlebarAppearsTransparent = false
            panel.isReleasedWhenClosed = false

            let delegate = SCAFieldInputWindowDelegate { box.resolve(nil, panel: panel) }
            panel.delegate = delegate
            // Delegate am Window halten, damit es nicht gleich freigegeben wird.
            objc_setAssociatedObject(panel, &SCAFieldInputDelegateKey,
                                     delegate, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)

            let view = SCAFieldInputView(
                spec: spec,
                onSubmit: { value in box.resolve(value, panel: panel) },
                onCancel: { box.resolve(nil, panel: panel) }
            )
            panel.contentView = NSHostingView(rootView: view)

            if let host {
                // Als Sheet am Setup-Fenster — gleiche Modal-Session, kein Cancel.
                host.beginSheet(panel) { _ in }
            } else {
                // Fallback (SCA außerhalb des Setups, z.B. beim Refresh/Transfer):
                // frei schwebendes Panel.
                panel.isFloatingPanel = true
                panel.center()
                panel.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
            }
        }
    }
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
