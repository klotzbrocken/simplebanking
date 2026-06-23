import AppKit
import LocalAuthentication

enum MasterPasswordResult {
    case password(String)
    /// Entsperren UND danach Touch ID direkt einrichten („Touch ID einrichten"-Button).
    case passwordSetupBiometric(String)
    case reset
    case cancelled
}

@MainActor
final class MasterPasswordPanel {
    private let panel: NSPanel
    private let passField = NSSecureTextField(string: "")
    private let confirmField = NSSecureTextField(string: "")
    private let mismatchLabel = NSTextField(labelWithString: "")
    private var result: MasterPasswordResult = .cancelled
    private let isUnlock: Bool
    private var touchIDTask: Task<Void, Never>?
    private weak var touchIDButton: NSButton?
    private let touchIDHint = NSTextField(labelWithString: "")
    /// „Touch ID einrichten" wurde geklickt, bevor ein Passwort da war → beim
    /// nächsten Entsperren (OK/Enter) Touch ID mit einrichten.
    private var pendingBiometricSetup = false

    init(isUnlock: Bool) {
        self.isUnlock = isUnlock

        // Button immer zeigen, wenn die Hardware da ist — auch wenn Touch ID (noch)
        // nicht eingerichtet ist (dann richtet der Klick es ein).
        let showTouchID = isUnlock && BiometricStore.isAvailable
        let panelHeight: CGFloat = isUnlock ? (showTouchID ? 340 : 280) : 380
        
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: panelHeight),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        panel.title = isUnlock ? "simplebanking entsperren" : "Master-Passwort festlegen"
        panel.isFloatingPanel = true
        panel.level = .floating

        let content = NSView()
        content.translatesAutoresizingMaskIntoConstraints = false
        panel.contentView = content

        // App Icon — robust loader mit Fallback-Chain (NSImage(named:) returnt nil
        // ohne Asset-Catalog, NSApplicationIconName nur wenn macOS die App "kennt").
        let iconView = NSImageView()
        if let appIcon = AppIconLoader.load() {
            iconView.image = appIcon
        }
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.translatesAutoresizingMaskIntoConstraints = false
        
        // Title
        let titleLabel = NSTextField(labelWithString: isUnlock ? "Entsperren" : "Master-Passwort")
        titleLabel.font = .systemFont(ofSize: 18, weight: .semibold)
        titleLabel.alignment = .center
        
        let infoText = isUnlock
            ? "Gib dein Master-Passwort ein, um simplebanking zu entsperren."
            : "Das Master-Passwort verschlüsselt deine Bank-Zugangsdaten im Keychain.\nEs wird NICHT gespeichert – merke es dir gut!"
        let info = NSTextField(wrappingLabelWithString: infoText)
        info.textColor = .secondaryLabelColor
        info.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        info.alignment = .center

        // Password field
        let passLabel = NSTextField(labelWithString: "Master-Passwort")
        passLabel.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .medium)
        passField.placeholderString = "Passwort eingeben…"
        passField.font = .systemFont(ofSize: 14)

        // Confirm field (only for setup)
        let confirmLabel = NSTextField(labelWithString: "Passwort bestätigen")
        confirmLabel.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .medium)
        confirmField.placeholderString = "Passwort wiederholen…"
        confirmField.font = .systemFont(ofSize: 14)
        
        // Mismatch warning
        mismatchLabel.textColor = .systemRed
        mismatchLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        mismatchLabel.isHidden = true
        
        // Add target for live validation
        confirmField.target = self
        confirmField.action = #selector(validatePasswords)
        passField.target = self
        passField.action = #selector(validatePasswords)

        // Buttons
        let buttons = NSStackView()
        buttons.orientation = .horizontal
        buttons.spacing = 10
        buttons.alignment = .centerY

        let cancel = NSButton(title: "Abbrechen", target: self, action: #selector(onCancel))
        cancel.bezelStyle = .rounded
        
        let ok = NSButton(title: isUnlock ? "Entsperren" : "Speichern", target: self, action: #selector(onOK))
        ok.bezelStyle = .rounded
        ok.keyEquivalent = "\r"

        buttons.addArrangedSubview(cancel)
        buttons.addArrangedSubview(NSView()) // Spacer
        
        // Add reset button only in unlock mode
        if isUnlock {
            let reset = NSButton(title: "Zurücksetzen…", target: self, action: #selector(onReset))
            reset.bezelStyle = .accessoryBarAction
            buttons.addArrangedSubview(reset)
        }
        
        buttons.addArrangedSubview(ok)
        buttons.arrangedSubviews[1].setContentHuggingPriority(.defaultLow, for: .horizontal)

        // Build view hierarchy
        var stackViews: [NSView] = [iconView, titleLabel, info, passLabel, passField]

        if !isUnlock {
            stackViews.append(confirmLabel)
            stackViews.append(confirmField)
            stackViews.append(mismatchLabel)
        }

        // Touch ID button (Unlock-Modus, wenn Hardware verfügbar). Titel/Verhalten
        // hängen davon ab, ob Touch ID schon eingerichtet ist.
        if showTouchID {
            let separator = NSBox()
            separator.boxType = .separator
            stackViews.append(separator)

            let configured = BiometricStore.hasSavedPassword
            let button = NSButton(title: configured ? "  Mit Touch ID entsperren" : "  Touch ID einrichten",
                                  target: self, action: #selector(onTouchIDButton))
            button.bezelStyle = .rounded
            button.image = NSImage(systemSymbolName: "touchid", accessibilityDescription: "Touch ID")
            button.imagePosition = .imageLeft
            button.contentTintColor = .controlAccentColor
            button.translatesAutoresizingMaskIntoConstraints = false
            button.widthAnchor.constraint(equalToConstant: 220).isActive = true
            self.touchIDButton = button
            stackViews.append(button)

            touchIDHint.font = .systemFont(ofSize: 11)
            touchIDHint.textColor = .secondaryLabelColor
            touchIDHint.alignment = .center
            touchIDHint.isHidden = true
            stackViews.append(touchIDHint)
        }

        stackViews.append(buttons)

        let stack = NSStackView(views: stackViews)
        stack.orientation = .vertical
        stack.spacing = 12
        stack.alignment = .centerX
        stack.edgeInsets = NSEdgeInsets(top: 24, left: 32, bottom: 24, right: 32)
        stack.translatesAutoresizingMaskIntoConstraints = false

        content.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            
            iconView.widthAnchor.constraint(equalToConstant: 64),
            iconView.heightAnchor.constraint(equalToConstant: 64),
            
            passField.widthAnchor.constraint(equalToConstant: 300),
            passField.heightAnchor.constraint(equalToConstant: 28),
            
            passLabel.widthAnchor.constraint(equalToConstant: 300),
            
            info.widthAnchor.constraint(equalToConstant: 320),
        ])
        
        if !isUnlock {
            NSLayoutConstraint.activate([
                confirmField.widthAnchor.constraint(equalToConstant: 300),
                confirmField.heightAnchor.constraint(equalToConstant: 28),
                confirmLabel.widthAnchor.constraint(equalToConstant: 300),
            ])
        }

        panel.initialFirstResponder = passField
    }

    func runModalWithResult() -> MasterPasswordResult {
        NSApp.activate(ignoringOtherApps: true)
        panel.center()
        panel.makeKeyAndOrderFront(nil)

        // Touch ID automatisch starten, sobald das Panel sichtbar ist
        if isUnlock && BiometricStore.isAvailable && BiometricStore.hasSavedPassword {
            DispatchQueue.main.async { [weak self] in
                self?.onTouchID()
            }
        }

        _ = NSApp.runModal(for: panel)
        touchIDTask?.cancel()
        panel.orderOut(nil)
        return result
    }

    /// Eine Aktion, zwei Zustände: konfiguriert → entsperren, sonst → einrichten.
    @objc private func onTouchIDButton() {
        if BiometricStore.hasSavedPassword {
            onTouchID()
        } else {
            onSetupTouchID()
        }
    }

    private func onTouchID() {
        touchIDTask?.cancel()
        touchIDTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let password = try await BiometricStore.loadPassword(
                    reason: "simplebanking entsperren"
                )
                guard !Task.isCancelled else { return }
                self.result = .password(password)
                NSApp.stopModal(withCode: .stop)
            } catch {
                guard !Task.isCancelled else { return }
                AppLogger.log("Touch ID failed: \(error.localizedDescription)", category: "Biometric", level: "WARN")
                // User-Abbruch: einfach Passwort-Eingabe ermöglichen. Sonst ist die
                // gespeicherte Anmeldung ungültig → bereinigen und auf „einrichten"
                // umstellen, damit Touch ID neu angelegt werden kann.
                if !Self.isUserCancel(error) {
                    BiometricStore.clear()
                    self.touchIDButton?.title = "  Touch ID einrichten"
                    self.touchIDHint.stringValue = "Touch ID muss neu eingerichtet werden — Passwort eingeben."
                    self.touchIDHint.isHidden = false
                }
            }
        }
    }

    /// Richtet Touch ID ein: erfordert das Master-Passwort (zum biometrisch
    /// geschützten Speichern). Verifikation übernimmt der Aufrufer (`completeUnlock`).
    private func onSetupTouchID() {
        let pw = passField.stringValue
        guard !pw.isEmpty else {
            // Noch kein Passwort: Intent merken, Feld fokussieren. Beim Entsperren
            // (OK/Enter) wird Touch ID dann mit eingerichtet.
            pendingBiometricSetup = true
            touchIDHint.stringValue = "Passwort eingeben und entsperren — Touch ID wird dabei eingerichtet."
            touchIDHint.isHidden = false
            passField.becomeFirstResponder()
            UserDefaults.standard.set(false, forKey: "biometricOfferDismissed")
            return
        }
        result = .passwordSetupBiometric(pw)
        NSApp.stopModal(withCode: .stop)
    }

    private static func isUserCancel(_ error: Error) -> Bool {
        guard let la = error as? LAError else { return false }
        switch la.code {
        case .userCancel, .appCancel, .systemCancel, .userFallback: return true
        default: return false
        }
    }
    
    @objc private func validatePasswords() {
        guard !isUnlock else { return }
        
        let pass1 = passField.stringValue
        let pass2 = confirmField.stringValue
        
        if !pass2.isEmpty && pass1 != pass2 {
            mismatchLabel.stringValue = "Passwörter stimmen nicht überein"
            mismatchLabel.isHidden = false
        } else if !pass2.isEmpty && pass1 == pass2 {
            mismatchLabel.stringValue = "Passwörter stimmen überein"
            mismatchLabel.textColor = .systemGreen
            mismatchLabel.isHidden = false
        } else {
            mismatchLabel.isHidden = true
        }
    }

    @objc private func onOK() {
        let p = passField.stringValue
        guard !p.isEmpty else { 
            NSSound.beep()
            shakeField(passField)
            return 
        }
        
        // For setup mode: verify passwords match
        if !isUnlock {
            let confirm = confirmField.stringValue
            if p != confirm {
                mismatchLabel.stringValue = "Passwörter stimmen nicht überein"
                mismatchLabel.textColor = .systemRed
                mismatchLabel.isHidden = false
                NSSound.beep()
                shakeField(confirmField)
                return
            }
            
            // Check minimum length
            if p.count < 4 {
                mismatchLabel.stringValue = "Mindestens 4 Zeichen erforderlich"
                mismatchLabel.textColor = .systemRed
                mismatchLabel.isHidden = false
                NSSound.beep()
                shakeField(passField)
                return
            }
        }
        
        // Touch-ID-Einrichtung wurde vorher angestoßen → beim Entsperren mit einrichten.
        result = (isUnlock && pendingBiometricSetup) ? .passwordSetupBiometric(p) : .password(p)
        NSApp.stopModal(withCode: .stop)
    }

    @objc private func onCancel() {
        result = .cancelled
        NSApp.stopModal(withCode: .abort)
    }
    
    @objc private func onReset() {
        let alert = NSAlert()
        alert.messageText = "Alle Daten löschen?"
        alert.informativeText = "Dies löscht alle gespeicherten Banking-Daten. Du musst die App danach neu einrichten."
        alert.addButton(withTitle: "Abbrechen")
        alert.addButton(withTitle: "Zurücksetzen")
        alert.alertStyle = .critical
        
        if alert.runModal() == .alertSecondButtonReturn {
            result = .reset
            NSApp.stopModal(withCode: .stop)
        }
    }
    
    private func shakeField(_ field: NSTextField) {
        let animation = CAKeyframeAnimation(keyPath: "transform.translation.x")
        animation.timingFunction = CAMediaTimingFunction(name: .linear)
        animation.duration = 0.4
        animation.values = [-8, 8, -6, 6, -4, 4, -2, 2, 0]
        field.layer?.add(animation, forKey: "shake")
    }
}
