import AppKit
import WebKit

/// Login-Fenster für den dm-eBon-Slot. Zeigt account.dm.de in einer WKWebView.
///
/// dm authentifiziert API-Calls NICHT über ein langlebiges Cookie (wie REWE),
/// sondern über einen KURZLEBIGEN Bearer-JWT (~2,5 min) aus Curity. Den können
/// wir nicht aus dem Cookie-Store lesen — stattdessen hängt ein at-document-start
/// injiziertes JS-Snippet sich in `window.fetch` UND `XMLHttpRequest` ein und
/// schickt jeden gesehenen `Authorization: Bearer …`-Header per
/// `webkit.messageHandlers.dmToken` ans native Swift. Wir halten immer den
/// FRISCHESTEN Token und benutzen ihn beim Sync.
@MainActor
final class DMAuthWebView: NSObject, NSWindowDelegate, WKScriptMessageHandler, WKNavigationDelegate {
    static let purchasesURL = "https://account.dm.de/purchases"

    /// Diagnose-Schalter (ohne Neu-Build umlegbar):
    ///   defaults write tech.yaxi.simplebanking dmHarvestHook -bool NO|YES
    /// Default = an. Bei NO wird der fetch/XHR-Hook NICHT injiziert (um zu testen,
    /// ob der Hook selbst die dm-SPA bricht).
    private static var harvestEnabled: Bool {
        UserDefaults.standard.object(forKey: "dmHarvestHook") as? Bool ?? true
    }

    private var window: NSWindow!
    private var webView: WKWebView!
    private var statusLabel: NSTextField!
    private var syncButton: NSButton!
    private let slotId: String
    private let bankId: String

    /// Frischester via JS-Hook geernteter Bearer-Token (ohne "Bearer "-Präfix).
    private var latestToken: String = ""
    /// Auto-Sync nur einmal pro Fenster (Token wird mehrfach gepostet).
    private var didAutoSync = false

    var onSynced: ((DMSyncResult) -> Void)?

    /// Meldet das Schließen des Fensters und ob je ein Sync gelang. Der Aufrufer legt
    /// den Slot an, BEVOR dieses Fenster erscheint — bricht der Nutzer den Login ab,
    /// bliebe sonst ein Konto zurück, das er nie wollte.
    var onDismissed: ((_ didSync: Bool) -> Void)?
    /// Headless-Abschluss: true = synchronisiert, false = Timeout/Login nötig.
    var onFinished: ((Bool) -> Void)?
    private var headless = false
    private var finished = false

    private static var retained: [String: DMAuthWebView] = [:]

    init(slotId: String, bankId: String = "primary") {
        self.slotId = slotId
        self.bankId = bankId
        super.init()
    }

    @discardableResult
    static func present(slotId: String,
                        onSynced: ((DMSyncResult) -> Void)? = nil,
                        onDismissed: ((Bool) -> Void)? = nil) -> DMAuthWebView {
        let c = DMAuthWebView(slotId: slotId)
        c.onSynced = onSynced
        c.onDismissed = onDismissed
        retained[slotId] = c
        c.show()
        return c
    }

    /// Unsichtbarer Hintergrund-Sync auf Basis der gespeicherten dm-Sitzung.
    static func presentHeadless(slotId: String, timeout: TimeInterval = 25,
                                onFinished: @escaping (Bool) -> Void) {
        let c = DMAuthWebView(slotId: slotId)
        c.headless = true
        c.onFinished = onFinished
        retained[slotId] = c
        c.show(timeout: timeout)
    }

    private func finish(_ ok: Bool) {
        guard !finished else { return }
        finished = true
        if headless {
            webView?.configuration.userContentController.removeScriptMessageHandler(forName: "dmToken")
            let id = slotId
            DispatchQueue.main.async { DMAuthWebView.retained[id] = nil }
        }
        onFinished?(ok)
    }

    private func show(timeout: TimeInterval = 0) {
        let frame = NSRect(x: 0, y: 0, width: 780, height: 720)

        // JS-Hook: Authorization-Header aus fetch + XHR abgreifen → native posten.
        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = .default()   // persistent → Login bleibt erhalten
        if Self.harvestEnabled {
            let userScript = WKUserScript(source: Self.tokenHookJS, injectionTime: .atDocumentStart,
                                          forMainFrameOnly: false)
            cfg.userContentController.addUserScript(userScript)
            cfg.userContentController.add(self, name: "dmToken")
        }
        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: frame.width, height: frame.height - 40),
                            configuration: cfg)
        webView.autoresizingMask = [.width, .height]
        webView.navigationDelegate = self
        // Echte Safari-UA, damit die WebView nicht als veralteter Client gilt.
        webView.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Safari/605.1.15"

        syncButton = NSButton(title: "Einkäufe synchronisieren", target: self, action: #selector(syncTapped))
        syncButton.bezelStyle = .rounded
        statusLabel = NSTextField(labelWithString: "Bei dm einloggen und Einkäufe öffnen, dann synchronisieren.")
        statusLabel.lineBreakMode = .byTruncatingTail

        if headless {
            // KEIN Fenster: WKWebView lädt + führt JS (Angular + Token-Hook) auch
            // ohne View-Hierarchie aus.
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in self?.finish(false) }
            webView.load(URLRequest(url: URL(string: Self.purchasesURL)!))
            return
        }

        window = NSWindow(contentRect: frame, styleMask: [.titled, .closable, .resizable],
                          backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "dm eBons verbinden"
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
        webView.load(URLRequest(url: URL(string: Self.purchasesURL)!))
    }

    func windowWillClose(_ notification: Notification) {
        onDismissed?(finished)
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "dmToken")
        Self.retained[slotId] = nil
    }

    // MARK: - Token-Hook

    /// Hängt sich in fetch + XHR und meldet den Bearer-Token ans native Swift —
    /// aber NUR den, der an die eBon-relevanten dm-Dienste (purchasehistory / ebon)
    /// geht. So erwischen wir die richtige Token-Audience und nicht den eines
    /// anderen dm-Microservices (sonst 400/403 beim API-Call).
    private static let tokenHookJS = """
    (function() {
      function relevant(url) {
        return typeof url === 'string' &&
               (url.indexOf('purchasehistory') !== -1 || url.indexOf('ebon-prod') !== -1);
      }
      function cap(h, url) {
        if (relevant(url) && typeof h === 'string' && /^Bearer\\s+/i.test(h)) {
          try { window.webkit.messageHandlers.dmToken.postMessage(h.replace(/^Bearer\\s+/i, '')); } catch (e) {}
        }
      }
      var of = window.fetch;
      window.fetch = function() {
        try {
          var a0 = arguments[0];
          var url = (typeof a0 === 'string') ? a0 : (a0 && a0.url) ? a0.url : '';
          var init = arguments[1] || {};
          var hs = init.headers;
          if (hs) {
            if (typeof hs.get === 'function') { cap(hs.get('authorization'), url); }
            else { cap(hs['authorization'] || hs['Authorization'], url); }
          }
        } catch (e) {}
        return of.apply(this, arguments);
      };
      var oo = XMLHttpRequest.prototype.open;
      XMLHttpRequest.prototype.open = function(m, u) { try { this.__dmURL = u; } catch (e) {} return oo.apply(this, arguments); };
      var os = XMLHttpRequest.prototype.setRequestHeader;
      XMLHttpRequest.prototype.setRequestHeader = function(k, v) {
        try { if (/^authorization$/i.test(k)) cap(v, this.__dmURL || ''); } catch (e) {}
        return os.apply(this, arguments);
      };
    })();
    """

    // MARK: - Navigation-Diagnose

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        let url = webView.url?.absoluteString ?? "?"
        AppLogger.log("dm webview loaded: \(url)", category: "DM")
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        AppLogger.log("dm webview didFail: \(error)", category: "DM", level: "WARN")
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        AppLogger.log("dm webview didFailProvisional: \(error)", category: "DM", level: "WARN")
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "dmToken", let token = message.body as? String, !token.isEmpty else { return }
        latestToken = token
        if syncButton.isEnabled == false { return }   // läuft gerade — Status nicht überschreiben
        // Auto-Sync, sobald ein gültiger Token da ist — kein manueller Klick nötig.
        if !didAutoSync, !DMService.isExpired(token) {
            didAutoSync = true
            syncTapped()
        } else {
            statusLabel.stringValue = "Bereit — jetzt synchronisieren."
        }
    }

    // MARK: - Sync

    @objc private func syncTapped() {
        guard !latestToken.isEmpty, !DMService.isExpired(latestToken) else {
            statusLabel.stringValue = "Noch kein gültiger dm-Login erkannt — bitte Einkäufe öffnen."
            return
        }
        syncButton.isEnabled = false
        statusLabel.stringValue = "Synchronisiere…"
        let token = latestToken
        Task {
            do {
                let result = try await DMService.sync(token: token, slotId: slotId, bankId: bankId)
                statusLabel.stringValue = "✅ \(result.listed) Einkäufe · \(result.detailed) mit Warenkorb · \(result.stored) gespeichert"
                onSynced?(result)
                finish(true)
            } catch DMServiceError.tokenExpired {
                statusLabel.stringValue = "Sitzung abgelaufen — Seite neu laden und nochmal synchronisieren."
                if headless { finish(false) }
            } catch {
                statusLabel.stringValue = "Fehler: \(error)"
                AppLogger.log("dm sync failed: \(error)", category: "DM", level: "WARN")
                if headless { finish(false) }
            }
            syncButton.isEnabled = true
        }
    }
}
