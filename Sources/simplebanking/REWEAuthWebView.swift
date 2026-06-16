import AppKit
import WebKit

/// Login-Fenster für den REWE-eBon-Slot. Zeigt rewe.de in einer WKWebView; nach
/// dem Login werden Cookies (Domain-gefiltert auf www.rewe.de) + der NATIVE
/// User-Agent geerntet und an `REWEService.sync` übergeben.
///
/// Wichtig (Phase-0/2-Erkenntnisse): KEIN `customUserAgent` (Fake-UA + WebKit-TLS
/// → Cloudflare-Turnstile-Schleife). Nur www.rewe.de-Cookies senden (nicht die
/// von account.rewe.de). Datenpfad läuft via `URLSession` über `REWEService`.
@MainActor
final class REWEAuthWebView: NSObject, NSWindowDelegate {
    static let imMarkt = "https://www.rewe.de/shop/mydata/meine-einkaeufe/im-markt"

    private var window: NSWindow!
    private var webView: WKWebView!
    private var statusLabel: NSTextField!
    private var syncButton: NSButton!
    private let slotId: String
    private let bankId: String

    /// Wird nach erfolgreichem Sync aufgerufen (z. B. zum Anlegen des Slots).
    var onSynced: ((REWESyncResult) -> Void)?

    /// Hält das offene Fenster am Leben, bis es geschlossen wird.
    private static var retained: REWEAuthWebView?

    init(slotId: String, bankId: String = "primary") {
        self.slotId = slotId
        self.bankId = bankId
        super.init()
    }

    /// Öffnet das Login-/Sync-Fenster.
    @discardableResult
    static func present(slotId: String, onSynced: ((REWESyncResult) -> Void)? = nil) -> REWEAuthWebView {
        let c = REWEAuthWebView(slotId: slotId)
        c.onSynced = onSynced
        retained = c
        c.show()
        return c
    }

    private func show() {
        let frame = NSRect(x: 0, y: 0, width: 780, height: 720)
        window = NSWindow(contentRect: frame, styleMask: [.titled, .closable, .resizable],
                          backing: .buffered, defer: false)
        window.title = "REWE eBons verbinden"
        window.delegate = self
        window.center()

        let content = NSView(frame: frame)
        content.autoresizesSubviews = true

        let bar = NSView(frame: NSRect(x: 0, y: frame.height - 40, width: frame.width, height: 40))
        bar.autoresizingMask = [.width, .minYMargin]
        syncButton = NSButton(title: "Einkäufe synchronisieren", target: self, action: #selector(syncTapped))
        syncButton.bezelStyle = .rounded
        syncButton.frame = NSRect(x: 8, y: 6, width: 220, height: 28)
        statusLabel = NSTextField(labelWithString: "Bitte bei REWE einloggen, dann synchronisieren.")
        statusLabel.frame = NSRect(x: 238, y: 10, width: frame.width - 248, height: 20)
        statusLabel.autoresizingMask = [.width]
        statusLabel.lineBreakMode = .byTruncatingTail
        bar.addSubview(syncButton)
        bar.addSubview(statusLabel)

        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = .default()   // persistent → Login bleibt erhalten
        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: frame.width, height: frame.height - 40),
                            configuration: cfg)
        webView.autoresizingMask = [.width, .height]

        content.addSubview(webView)
        content.addSubview(bar)
        window.contentView = content
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        webView.load(URLRequest(url: URL(string: Self.imMarkt)!))
    }

    func windowWillClose(_ notification: Notification) {
        Self.retained = nil
    }

    @objc private func syncTapped() {
        syncButton.isEnabled = false
        statusLabel.stringValue = "Synchronisiere…"
        Task {
            do {
                let cookie = await harvestCookieHeader()
                guard cookie.contains("rstp=") else {
                    statusLabel.stringValue = "Nicht eingeloggt — bitte zuerst bei REWE anmelden."
                    syncButton.isEnabled = true
                    return
                }
                let ua = await webViewUserAgent()
                let result = try await REWEService.sync(cookieHeader: cookie, userAgent: ua,
                                                        slotId: slotId, bankId: bankId)
                statusLabel.stringValue = "✅ \(result.listed) Bons · \(result.matched) mit Warenkorb · \(result.stored) gespeichert"
                onSynced?(result)
            } catch {
                statusLabel.stringValue = "Fehler: \(error)"
                AppLogger.log("REWE sync failed: \(error)", category: "REWE", level: "WARN")
            }
            syncButton.isEnabled = true
        }
    }

    // MARK: - Harvest

    /// Nur Cookies, die ein Browser an `host` schicken würde (www.rewe.de /
    /// rewe.de / .rewe.de) — NICHT die von account.rewe.de (Keycloak etc.).
    static func cookieHostMatches(_ cookieDomain: String, _ host: String) -> Bool {
        let d = cookieDomain.hasPrefix(".") ? String(cookieDomain.dropFirst()) : cookieDomain
        return host == d || host.hasSuffix("." + d)
    }

    private func harvestCookieHeader(host: String = "www.rewe.de") async -> String {
        let store = webView.configuration.websiteDataStore.httpCookieStore
        return await withCheckedContinuation { (cont: CheckedContinuation<String, Never>) in
            store.getAllCookies { cookies in
                cont.resume(returning: cookies
                    .filter { REWEAuthWebView.cookieHostMatches($0.domain, host) }
                    .map { "\($0.name)=\($0.value)" }
                    .joined(separator: "; "))
            }
        }
    }

    private func webViewUserAgent() async -> String {
        await withCheckedContinuation { (cont: CheckedContinuation<String, Never>) in
            webView.evaluateJavaScript("navigator.userAgent") { result, _ in
                cont.resume(returning: (result as? String) ?? "")
            }
        }
    }
}
