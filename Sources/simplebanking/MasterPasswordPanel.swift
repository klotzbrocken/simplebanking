import AppKit
import LocalAuthentication

enum MasterPasswordResult {
    case password(String)
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

    init(isUnlock: Bool) {
        self.isUnlock = isUnlock

        let showTouchID = isUnlock && BiometricStore.isAvailable && BiometricStore.hasSavedPassword
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
            : "Das Master-Passwort schützt deine Banking-Daten.\nEs wird NICHT gespeichert – merke es dir gut!"
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

        // Touch ID button (nur im Unlock-Modus, wenn verfügbar)
        if showTouchID {
            let separator = NSBox()
            separator.boxType = .separator
            stackViews.append(separator)

            let touchIDButton = NSButton(title: "  Mit Touch ID entsperren", target: self, action: #selector(onTouchID))
            touchIDButton.bezelStyle = .rounded
            touchIDButton.image = NSImage(systemSymbolName: "touchid", accessibilityDescription: "Touch ID")
            touchIDButton.imagePosition = .imageLeft
            touchIDButton.contentTintColor = .controlAccentColor
            touchIDButton.translatesAutoresizingMaskIntoConstraints = false
            touchIDButton.widthAnchor.constraint(equalToConstant: 220).isActive = true
            stackViews.append(touchIDButton)
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
                // Touch ID fehlgeschlagen – Nutzer kann weiterhin Passwort eingeben
                AppLogger.log("Touch ID failed: \(error.localizedDescription)", category: "Biometric", level: "WARN")
            }
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
        
        result = .password(p)
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
