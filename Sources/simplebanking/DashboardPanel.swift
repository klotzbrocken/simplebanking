import AppKit
import SwiftUI

/// Hosts the unified `DashboardView` in a themed, resizable `NSPanel` — mirrors the
/// `TransactionsPanel` hosting pattern. One instance, reused; `show(tab:…)` deep-links to a tab.
@MainActor
final class DashboardPanel: NSObject, NSWindowDelegate {
    private let panel: NSPanel
    private let model: DashboardModel

    var isVisible: Bool { panel.isVisible }

    // Feste Fenstergröße = maximierte Umsatzliste (TransactionsPanel im Breit-Modus).
    static let defaultWidth: CGFloat = TransactionsPanel.wideWidth     // 840
    static let defaultHeight: CGFloat = TransactionsPanel.panelHeight  // 620

    override init() {
        model = DashboardModel()
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: Self.defaultWidth, height: Self.defaultHeight),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        super.init()

        panel.title = "Dashboard"
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.backgroundColor = NSColor(name: nil) { appearance in
            let theme = ThemeManager.shared.currentTheme
            return appearance.bestMatch(from: [.darkAqua, .vibrantDark]) != nil
                ? theme.panelDarkColor
                : theme.panelLightColor
        }
        panel.isFloatingPanel = false
        panel.hidesOnDeactivate = false
        if #available(macOS 11.0, *) {
            panel.toolbarStyle = .unifiedCompact
        }
        panel.collectionBehavior = [.fullScreenNone, .managed]
        panel.isReleasedWhenClosed = false
        // Da die Titelleiste transparent/versteckt ist: auch per Fenster-Hintergrund verschiebbar.
        panel.isMovableByWindowBackground = true
        panel.delegate = self

        let host = NSHostingView(rootView: DashboardView(model: model))
        host.translatesAutoresizingMaskIntoConstraints = false
        // Der Host darf die Fenstergröße NICHT steuern — sonst springt das Fenster beim Tab-Wechsel
        // auf die Idealgröße des neuen Tab-Inhalts zurück. Größe kommt allein vom (resizable) Panel.
        if #available(macOS 13.0, *) {
            host.sizingOptions = []
        }
        let content = NSView()
        content.addSubview(host)
        panel.contentView = content
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            host.topAnchor.constraint(equalTo: content.topAnchor),
            host.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
    }

    /// Open (or re-focus) the dashboard at `tab`, refreshing the data snapshot.
    func show(tab: DashboardTab, transactions: [TransactionsResponse.Transaction], balance: Double) {
        model.transactions = transactions
        model.balance = balance
        model.tab = tab
        if !panel.isVisible {
            clampAndCenterToScreen()
        }
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Feste Größe (auf die sichtbare Bildschirmfläche gedeckelt, falls Display kleiner) + zentriert.
    private func clampAndCenterToScreen() {
        let visible = (panel.screen ?? NSScreen.main)?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let margin: CGFloat = 24
        let w = min(Self.defaultWidth, visible.width - margin)
        let h = min(Self.defaultHeight, visible.height - margin)
        let size = NSSize(width: w, height: h)
        panel.setContentSize(size)
        panel.contentMinSize = size
        panel.contentMaxSize = size   // fix: keine manuelle Größenänderung nötig/möglich
        let frame = panel.frame
        panel.setFrameOrigin(NSPoint(x: visible.midX - frame.width / 2, y: visible.midY - frame.height / 2))
    }

    func close() {
        panel.orderOut(nil)
    }
}
