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
final class REWEAuthWebView: NSObject, NSWindowDelegate, WKNavigationDelegate {
    static let imMarkt = "https://www.rewe.de/shop/mydata/meine-einkaeufe/im-markt"

    /// Auto-Sync nur einmal pro Fenster.
    private var didAutoSync = false

    private var window: NSWindow!
    private var webView: WKWebView!
    private var statusLabel: NSTextField!
    private var syncButton: NSButton!
    private let slotId: String
    private let bankId: String

    /// Wird nach erfolgreichem Sync aufgerufen (z. B. zum Anlegen des Slots).
    var onSynced: ((REWESyncResult) -> Void)?
    /// Headless-Abschluss: true = synchronisiert, false = Timeout/Login nötig.
    var onFinished: ((Bool) -> Void)?
    private var headless = false
    private var finished = false

    /// Hält das offene Fenster am Leben, bis es geschlossen wird.
    private static var retained: [String: REWEAuthWebView] = [:]

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
        retained[slotId] = c
        c.show()
        return c
    }

    /// Unsichtbarer Hintergrund-Sync auf Basis der gespeicherten REWE-Sitzung.
    static func presentHeadless(slotId: String, timeout: TimeInterval = 25,
                                onFinished: @escaping (Bool) -> Void) {
        let c = REWEAuthWebView(slotId: slotId)
        c.headless = true
        c.onFinished = onFinished
        retained[slotId] = c
        c.show(timeout: timeout)
    }

    private func finish(_ ok: Bool) {
        guard !finished else { return }
        finished = true
        if headless {
            let id = slotId
            DispatchQueue.main.async { REWEAuthWebView.retained[id] = nil }
        }
        onFinished?(ok)
    }

    private func show(timeout: TimeInterval = 0) {
        let frame = NSRect(x: 0, y: 0, width: 780, height: 720)

        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = .default()   // persistent → Login bleibt erhalten
        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: frame.width, height: frame.height - 40),
                            configuration: cfg)
        webView.autoresizingMask = [.width, .height]
        webView.navigationDelegate = self

        syncButton = NSButton(title: "Einkäufe synchronisieren", target: self, action: #selector(syncTapped))
        syncButton.bezelStyle = .rounded
        statusLabel = NSTextField(labelWithString: "Bitte bei REWE einloggen, dann synchronisieren.")
        statusLabel.lineBreakMode = .byTruncatingTail

        if headless {
            // KEIN Fenster: WKWebView lädt windowless; Cookie-Harvest + URLSession-Sync.
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in self?.finish(false) }
            webView.load(URLRequest(url: URL(string: Self.imMarkt)!))
            return
        }

        window = NSWindow(contentRect: frame, styleMask: [.titled, .closable, .resizable],
                          backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "REWE eBons verbinden"
        window.delegate = self
        window.center()
        let content = NSView(frame: frame)
        content.autoresizesSubviews = true
        let bar = NSView(frame: NSRect(x: 0, y: frame.height - 40, width: frame.width, height: 40))
        bar.autoresizingMask = [.width, .minYMargin]
        syncButton.frame = NSRect(x: 8, y: 6, width: 220, height: 28)
        statusLabel.frame = NSRect(x: 238, y: 10, width: frame.width - 248, height: 20)
        statusLabel.autoresizingMask = [.width]
        bar.addSubview(syncButton)
        bar.addSubview(statusLabel)
        content.addSubview(webView)
        content.addSubview(bar)
        window.contentView = content
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        webView.load(URLRequest(url: URL(string: Self.imMarkt)!))
    }

    func windowWillClose(_ notification: Notification) {
        Self.retained[slotId] = nil
    }

    /// Account-Chooser („Mit diesem Konto fortfahren") automatisch bestätigen, damit
    /// daraus die rstp-Sitzung entsteht — kein manueller Klick. Greift auch headless.
    private static let autoContinueJS = """
    (function() {
      var els = document.querySelectorAll('button, a, [role="button"]');
      for (var i = 0; i < els.length; i++) {
        var t = (els[i].innerText || els[i].textContent || '').toLowerCase();
        if (t.indexOf('fortfahren') > -1 || t.indexOf('diesem konto') > -1) { els[i].click(); return true; }
      }
      return false;
    })();
    """

    /// Auto-Sync, sobald eine Seite geladen ist und der rstp-Login-Cookie da ist —
    /// kein manueller Klick nötig.
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // Account-Chooser („mit diesem Konto fortfahren") rendert oft erst NACH
        // didFinish → mehrfach versuchen.
        autoContinue(attempt: 0)
        guard !didAutoSync else { return }
        Task {
            let cookie = await harvestCookieHeader()
            guard !didAutoSync, cookie.contains("rstp=") else { return }
            didAutoSync = true
            syncTapped()
        }
    }

    private func autoContinue(attempt: Int) {
        guard !didAutoSync, attempt < 8, let webView else { return }
        webView.evaluateJavaScript(Self.autoContinueJS) { [weak self] result, _ in
            guard let self else { return }
            if (result as? Bool) == true { return }   // geklickt → Navigation folgt
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { self.autoContinue(attempt: attempt + 1) }
        }
    }

    @objc private func syncTapped() { runSync(retry: 0) }

    /// Direkt nach der Kontoauswahl ist die REWE-Session/`cf_clearance` für die
    /// API oft noch nicht durchgereicht → erster Call 403. Darum bei Fehlschlag
    /// einmal kurz warten und erneut versuchen (statt Fenster zweimal öffnen).
    private func runSync(retry: Int) {
        syncButton.isEnabled = false
        statusLabel.stringValue = retry == 0 ? "Synchronisiere…" : "Sitzung wird vorbereitet…"
        Task {
            do {
                let cookie = await harvestCookieHeader()
                guard cookie.contains("rstp=") else {
                    statusLabel.stringValue = "Nicht eingeloggt — bitte zuerst bei REWE anmelden."
                    syncButton.isEnabled = true
                    if headless { finish(false) }
                    return
                }
                let ua = await webViewUserAgent()
                let result = try await REWEService.sync(cookieHeader: cookie, userAgent: ua,
                                                        slotId: slotId, bankId: bankId)
                statusLabel.stringValue = "✅ \(result.listed) Bons · \(result.matched) mit Warenkorb · \(result.stored) gespeichert"
                onSynced?(result)
                finish(true)
            } catch {
                if retry < 2 {
                    AppLogger.log("REWE sync retry \(retry + 1) nach Fehler: \(error)", category: "REWE")
                    syncButton.isEnabled = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in self?.runSync(retry: retry + 1) }
                    return
                }
                statusLabel.stringValue = "Fehler: \(error)"
                AppLogger.log("REWE sync failed: \(error)", category: "REWE", level: "WARN")
                if headless { finish(false) }
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
