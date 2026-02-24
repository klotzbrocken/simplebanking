import AppKit
import SwiftUI

// MARK: - Entry point

enum OnboardingPanel {
    static func show(bankName: String) {
        let view = OnboardingView(bankName: bankName) {
            NSApp.stopModal(withCode: .stop)
        }
        let hostingController = NSHostingController(rootView: view)
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 400),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        panel.title = ""
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.contentViewController = hostingController
        panel.center()
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        NSApp.runModal(for: panel)
        panel.orderOut(nil)
    }
}

// MARK: - Model

private struct OnboardingPage {
    let systemImage: String
    let imageColor: Color
    let title: String
    let body: String
    let features: [Feature]

    struct Feature {
        let icon: String
        let text: String
    }
}

private let pages: [OnboardingPage] = [
    OnboardingPage(
        systemImage: "checkmark.seal.fill",
        imageColor: .green,
        title: "Einrichtung abgeschlossen!",
        body: "simplebanking läuft jetzt in deiner Menüleiste.",
        features: []
    ),
    OnboardingPage(
        systemImage: "macwindow.on.rectangle",
        imageColor: .accentColor,
        title: "So funktioniert's",
        body: "",
        features: [
            .init(icon: "cursorarrow.click", text: "Klick auf den Kontostand öffnet die Umsatzliste"),
            .init(icon: "arrow.clockwise", text: "Kontostand wird automatisch aktualisiert"),
            .init(icon: "magnifyingglass", text: "Umsätze durchsuchen, filtern und analysieren"),
            .init(icon: "cursorarrow.click.2", text: "Rechtsklick → Sperren, Einstellungen, Demo-Modus"),
        ]
    ),
    OnboardingPage(
        systemImage: "lock.shield.fill",
        imageColor: Color(NSColor.systemIndigo),
        title: "Deine Daten sind sicher",
        body: "",
        features: [
            .init(icon: "key.fill", text: "Master-Passwort verschlüsselt alle Daten lokal"),
            .init(icon: "touchid", text: "Touch ID für schnelles Entsperren aktivierbar"),
            .init(icon: "iphone.and.arrow.forward", text: "Keine Daten in der Cloud – alles bleibt auf deinem Mac"),
        ]
    ),
]

// MARK: - View

private struct OnboardingView: View {
    let bankName: String
    let onDismiss: () -> Void

    @State private var currentPage = 0

    private var isFirst: Bool { currentPage == 0 }
    private var isLast: Bool { currentPage == pages.count - 1 }

    var body: some View {
        VStack(spacing: 0) {
            // Content area
            ZStack {
                ForEach(pages.indices, id: \.self) { index in
                    PageView(page: pages[index], bankName: bankName)
                        .opacity(currentPage == index ? 1 : 0)
                        .animation(.easeInOut(duration: 0.2), value: currentPage)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 40)
            .padding(.top, 36)
            .padding(.bottom, 20)

            // Bottom bar: dots + buttons
            VStack(spacing: 16) {
                Divider()
                HStack {
                    // Back button
                    Button(action: { currentPage -= 1 }) {
                        Text("← Zurück")
                            .font(.system(size: 13))
                    }
                    .buttonStyle(PlainButtonStyle())
                    .foregroundColor(.secondary)
                    .opacity(isFirst ? 0 : 1)
                    .disabled(isFirst)

                    Spacer()

                    // Page dots
                    HStack(spacing: 6) {
                        ForEach(pages.indices, id: \.self) { index in
                            Circle()
                                .fill(currentPage == index ? Color.accentColor : Color(NSColor.tertiaryLabelColor))
                                .frame(width: 7, height: 7)
                                .animation(.easeInOut(duration: 0.2), value: currentPage)
                        }
                    }

                    Spacer()

                    // Next / Done button
                    Button(action: {
                        if isLast {
                            onDismiss()
                        } else {
                            currentPage += 1
                        }
                    }) {
                        Text(isLast ? "Los geht's!" : "Weiter →")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 7)
                            .background(Color.accentColor)
                            .cornerRadius(8)
                    }
                    .buttonStyle(PlainButtonStyle())
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 20)
            }
        }
        .frame(width: 460, height: 400)
        .background(Color(NSColor.windowBackgroundColor))
    }
}

// MARK: - Page content

private struct PageView: View {
    let page: OnboardingPage
    let bankName: String

    var body: some View {
        VStack(spacing: 0) {
            // Icon
            Image(systemName: page.systemImage)
                .font(.system(size: 52, weight: .semibold))
                .foregroundColor(page.imageColor)
                .padding(.bottom, 16)

            // Title
            Text(page.title)
                .font(.system(size: 20, weight: .bold))
                .multilineTextAlignment(.center)
                .padding(.bottom, 6)

            // Body text or bank subtitle
            if page.features.isEmpty {
                VStack(spacing: 4) {
                    if !bankName.isEmpty {
                        Text("Verbunden mit \(bankName)")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundColor(.accentColor)
                            .padding(.bottom, 4)
                    }
                    Text(page.body)
                        .font(.system(size: 14))
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                }
            } else {
                // Feature list
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(page.features.indices, id: \.self) { i in
                        FeatureRow(icon: page.features[i].icon, text: page.features[i].text)
                    }
                }
                .padding(.top, 8)
            }

            Spacer()
        }
    }
}

private struct FeatureRow: View {
    let icon: String
    let text: String

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 16))
                .foregroundColor(.accentColor)
                .frame(width: 24)
            Text(text)
                .font(.system(size: 13))
                .foregroundColor(.primary)
            Spacer()
        }
    }
}
