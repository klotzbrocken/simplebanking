import AppKit
import LocalAuthentication

enum MasterPasswordResult {
    case password(String)
    /// Entsperren UND danach Touch ID direkt einrichten („Touch ID einrichten"-Button).
    case passwordSetupBiometric(String)
    case reset
    case cancelled
}

/// NSPanel-Subklasse, die Key/Main-Status erzwingt. Zusammen mit `.nonactivatingPanel`
/// kann das Passwort-Panel so den Tastaturfokus bekommen, OHNE dass die (Accessory-)
/// App in den Vordergrund aktiviert werden muss — genau der Fall, der auf macOS 26
/// mit `NSApp.activate` scheiterte (App wurde nie aktiv → Panel nie Key → Lockout).
private final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
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
    /// Checkbox „Mit Touch ID entsperren" — bietet die Einrichtung direkt bei der
    /// Passwort-Eingabe an (statt eines separaten Buttons). Sichtbar, solange
    /// Touch-ID-Hardware da ist und noch kein Passwort biometrisch gespeichert wurde.
    private let biometricCheckbox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let canEnroll: Bool

    /// `offerBiometricSetup`: ob die Enrollment-Checkbox „Künftig mit Touch ID
    /// entsperren" angeboten wird. `false` in Re-Auth-Kontexten (z.B. Settings fragt
    /// das Passwort für eine Einzelaktion ab) — dort würde ein Haken ins Leere laufen,
    /// weil der Aufrufer kein `BiometricStore.save` ausführt. Einrichtung passiert nur
    /// beim echten Start-Entsperren bzw. in Settings → Touch ID.
    /// `suppressBiometricButton`: unterdrückt den „Mit Touch ID entsperren"-Button
    /// (und Auto-Prompt). Genutzt, wenn das Panel als **Fallback** erscheint, NACHDEM
    /// Touch ID bereits vor dem Panel versucht wurde (und abgelehnt/fehlgeschlagen ist)
    /// — dann wäre ein erneuter Biometrie-Button sinnlos und liefe im Modal-Mode ohnehin
    /// ins Leere. Reine Passwort-Eingabe.
    init(isUnlock: Bool, offerBiometricSetup: Bool = true, suppressBiometricButton: Bool = false) {
        self.isUnlock = isUnlock

        // Schon eingerichtet (nur Unlock): „Mit Touch ID entsperren"-Button + Auto-Prompt.
        // Noch nicht eingerichtet, Hardware da, Enrollment erlaubt: Checkbox zur
        // Einrichtung bei der Passwort-Eingabe — Touch ID wird beim Tippen mit aktiviert.
        let alreadyEnrolled = isUnlock && !suppressBiometricButton && BiometricStore.isAvailable && BiometricStore.hasSavedPassword
        // Enrollment-Checkbox nur, wenn noch NICHTS gespeichert ist (unabhängig vom
        // Suppress-Fallback — sonst würde sie nach abgelehnter Biometrie fälschlich
        // wieder erscheinen, obwohl bereits ein Passwort gespeichert ist).
        let canEnroll = offerBiometricSetup && BiometricStore.isAvailable && !BiometricStore.hasSavedPassword
        self.canEnroll = canEnroll
        let panelHeight: CGFloat = {
            if isUnlock { return (alreadyEnrolled || canEnroll) ? 350 : 280 }
            return canEnroll ? 430 : 380
        }()
        
        panel = KeyablePanel(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: panelHeight),
            styleMask: [.titled, .closable, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.title = isUnlock ? "simplebanking entsperren" : "Master-Passwort festlegen"
        panel.isFloatingPanel = true
        panel.level = .floating
        // Sofort Key werden (nicht erst bei Klick in ein Feld) und beim Verlust der
        // App-Aktivierung nicht verschwinden — das Panel muss im Hintergrund tippbar sein.
        panel.becomesKeyOnlyIfNeeded = false
        panel.hidesOnDeactivate = false

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

        // Touch ID: entweder „entsperren" (schon eingerichtet, nur Unlock) oder eine
        // Einrichtungs-Checkbox (Hardware da, noch nicht gespeichert) — letztere auch
        // im Setup-Dialog, damit Touch ID direkt beim Festlegen des Passworts aktiviert
        // wird.
        if alreadyEnrolled || canEnroll {
            let separator = NSBox()
            separator.boxType = .separator
            stackViews.append(separator)
        }
        if alreadyEnrolled {
            let button = NSButton(title: "  Mit Touch ID entsperren",
                                  target: self, action: #selector(onTouchID))
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
        } else if canEnroll {
            biometricCheckbox.title = isUnlock
                ? "Künftig mit Touch ID entsperren"
                : "Mit Touch ID entsperren (empfohlen)"
            biometricCheckbox.state = .on   // Opt-in standardmäßig an
            stackViews.append(biometricCheckbox)

            let hint = NSTextField(wrappingLabelWithString: isUnlock
                ? "Touch ID wird nach dem Entsperren eingerichtet — du wirst einmal gefragt."
                : "Nach dem Speichern wirst du einmal nach Touch ID gefragt.")
            hint.font = .systemFont(ofSize: 11)
            hint.textColor = .secondaryLabelColor
            hint.alignment = .center
            hint.preferredMaxLayoutWidth = 300
            hint.widthAnchor.constraint(equalToConstant: 300).isActive = true
            stackViews.append(hint)
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
        // `.accessory`-Apps (LSUIElement) können unter macOS 26 NICHT mehr per
        // `NSApp.activate` in den Vordergrund gebracht werden (kooperatives
        // Aktivierungsmodell → App bleibt inaktiv, `active=false`). Ein zuvor
        // versuchter `.regular`-Policy-Switch half nicht (Diagnose: App wurde trotzdem
        // nicht aktiv) und ließ nur das Dock-Icon aufblitzen.
        //
        // Lösung: Das Panel ist ein `.nonactivatingPanel` (KeyablePanel) → es wird Key
        // und nimmt Tastatureingaben an, OHNE dass die App aktiv werden muss. Kein
        // Policy-Switch, kein `NSApp.activate` nötig.
        NSApp.activate(ignoringOtherApps: true)   // best effort; schadet nicht
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        panel.orderFrontRegardless()
        panel.makeKey()
        // Kein Auto-Touch-ID mehr hier drin: Biometrie läuft VOR dem Panel (async,
        // außerhalb der Modal-Schleife). `NSApp.runModal` pumpt die Runloop im
        // Modal-Mode, in dem `DispatchQueue.main`/Swift-Concurrency NICHT laufen — ein
        // Touch-ID-Task würde hier steckenbleiben.

        _ = NSApp.runModal(for: panel)
        touchIDTask?.cancel()
        panel.orderOut(nil)
        return result
    }

    @objc private func onTouchID() {
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
                // gespeicherte Anmeldung ungültig → bereinigen, Button deaktivieren und
                // Hinweis zeigen, damit Touch ID neu eingerichtet werden kann.
                if !Self.isUserCancel(error) {
                    BiometricStore.clear()
                    self.touchIDButton?.isEnabled = false
                    self.touchIDHint.stringValue = "Touch ID muss neu eingerichtet werden — Passwort eingeben."
                    self.touchIDHint.isHidden = false
                }
            }
        }
    }

    private static func isUserCancel(_ error: Error) -> Bool {
        if let la = error as? LAError {
            switch la.code {
            case .userCancel, .appCancel, .systemCancel, .userFallback: return true
            default: return false
            }
        }
        // Keychain-Read (ACL-Item) liefert OSStatus statt LAError.
        let ns = error as NSError
        if ns.domain == NSOSStatusErrorDomain {
            return ns.code == Int(errSecUserCanceled)
        }
        return false
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
        
        // Checkbox „Mit Touch ID entsperren" an → nach erfolgreichem Unlock/Setup
        // Touch ID einrichten (Aufrufer ruft enableBiometric → System-Prompt).
        let wantsBiometric = canEnroll && biometricCheckbox.state == .on
        result = wantsBiometric ? .passwordSetupBiometric(p) : .password(p)
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
