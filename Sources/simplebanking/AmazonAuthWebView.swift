import AppKit
import WebKit

/// Login-/Import-Fenster für den Amazon-Bestell-Slot. Amazon hat keine saubere
/// JSON-API und ist stark bot-geschützt — daher KEIN URLSession/cURL-Replay,
/// sondern **DOM-Scraping direkt in der WebView**: Nach dem Login auf der
/// „Meine Bestellungen"-Seite liest ein injiziertes JS die gerenderten
/// Bestellkarten (Datum, Summe, Artikeltitel) aus und übergibt sie ans native
/// Swift (`AmazonOrderParser`). Es werden die aktuell angezeigten Bestellungen
/// gescrapt — über den Zeitraum-Filter der Seite kann der User mehr laden und
/// erneut importieren. Kein Auto-Sync; nur vom User angestoßen.
@MainActor
final class AmazonAuthWebView: NSObject, NSWindowDelegate, WKNavigationDelegate {
    static let ordersURL = "https://www.amazon.de/gp/css/order-history?ref_=nav_orders_first"

    private var window: NSWindow!
    private var webView: WKWebView!
    private var statusLabel: NSTextField!
    private var syncButton: NSButton!
    private let slotId: String
    private let bankId: String

    var onSynced: ((AmazonSyncResult) -> Void)?

    /// Meldet das Schließen des Fensters und ob je ein Sync gelang. Der Aufrufer legt
    /// den Slot an, BEVOR dieses Fenster erscheint — bricht der Nutzer den Login ab,
    /// bliebe sonst ein Konto zurück, das er nie wollte.
    var onDismissed: ((_ didSync: Bool) -> Void)?
    /// Headless-Abschluss: true = importiert, false = Timeout/Login nötig.
    var onFinished: ((Bool) -> Void)?
    private var headless = false
    private var finished = false
    private static var retained: [String: AmazonAuthWebView] = [:]

    init(slotId: String, bankId: String = "primary") {
        self.slotId = slotId
        self.bankId = bankId
        super.init()
    }

    @discardableResult
    static func present(slotId: String,
                        onSynced: ((AmazonSyncResult) -> Void)? = nil,
                        onDismissed: ((Bool) -> Void)? = nil) -> AmazonAuthWebView {
        let c = AmazonAuthWebView(slotId: slotId)
        c.onSynced = onSynced
        c.onDismissed = onDismissed
        retained[slotId] = c
        c.show()
        return c
    }

    /// Unsichtbarer Hintergrund-Import: lädt die Bestellseite offscreen und nutzt
    /// die gespeicherte Login-Sitzung. `onFinished(true)` bei Erfolg, sonst (Login
    /// nötig/Timeout) `onFinished(false)` — dann KEIN Fenster.
    static func presentHeadless(slotId: String, timeout: TimeInterval = 25,
                                onFinished: @escaping (Bool) -> Void) {
        let c = AmazonAuthWebView(slotId: slotId)
        c.headless = true
        c.onFinished = onFinished
        retained[slotId] = c
        c.show(timeout: timeout)
    }

    private func finish(_ ok: Bool) {
        guard !finished else { return }
        finished = true
        if headless {
            // Webview windowless freigeben (kein NSWindow im Spiel). Verzögert,
            // um nicht aus einem laufenden WebView-Callback heraus zu deallozieren.
            let id = slotId
            DispatchQueue.main.async { AmazonAuthWebView.retained[id] = nil }
        }
        onFinished?(ok)
    }

    private func show(timeout: TimeInterval = 0) {
        let frame = NSRect(x: 0, y: 0, width: 820, height: 760)

        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = .default()   // persistent → Login bleibt erhalten
        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: frame.width, height: frame.height - 40),
                            configuration: cfg)
        webView.autoresizingMask = [.width, .height]
        webView.navigationDelegate = self
        // KEINE gefälschte UA: Amazons Bot-Erkennung gleicht UA gegen den echten
        // WebKit/TLS-Fingerprint ab — eine erfundene Safari-Version triggert das
        // Captcha (opfcaptcha). Native WKWebView-UA passt zum Engine-Fingerprint.

        syncButton = NSButton(title: "Bestellungen importieren", target: self, action: #selector(syncTapped))
        syncButton.bezelStyle = .rounded
        statusLabel = NSTextField(labelWithString: "Bei Amazon einloggen und Meine Bestellungen öffnen, dann importieren.")
        statusLabel.lineBreakMode = .byTruncatingTail

        if headless {
            // KEIN Fenster: WKWebView lädt + führt JS auch ohne View-Hierarchie aus.
            // Vermeidet jede NSWindow-Sichtbarkeits-/Release-Falle.
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in self?.finish(false) }
            webView.load(URLRequest(url: URL(string: Self.ordersURL)!))
            return
        }

        window = NSWindow(contentRect: frame, styleMask: [.titled, .closable, .resizable],
                          backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "Amazon Bestellungen verbinden"
        window.delegate = self
        window.center()

        let content = NSView(frame: frame)
        content.autoresizesSubviews = true
        let bar = NSView(frame: NSRect(x: 0, y: frame.height - 40, width: frame.width, height: 40))
        bar.autoresizingMask = [.width, .minYMargin]
        syncButton.frame = NSRect(x: 8, y: 6, width: 210, height: 28)
        statusLabel.frame = NSRect(x: 228, y: 10, width: frame.width - 238, height: 20)
        statusLabel.autoresizingMask = [.width]
        bar.addSubview(syncButton)
        bar.addSubview(statusLabel)
        content.addSubview(webView)
        content.addSubview(bar)
        window.contentView = content
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        webView.load(URLRequest(url: URL(string: Self.ordersURL)!))
    }

    func windowWillClose(_ notification: Notification) {
        onDismissed?(finished)
        Self.retained[slotId] = nil
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        let url = webView.url?.absoluteString ?? ""
        AppLogger.log("amazon webview loaded: \(url)", category: "Amazon")
        // Auto-Import, sobald die Bestellseite geladen ist — kein manueller Klick.
        // (Captcha/Signin-Seiten enthalten kein "order-history" → wird übersprungen.)
        guard url.contains("order-history") || url.contains("/your-orders") else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            guard let self, self.syncButton.isEnabled else { return }   // nicht doppelt
            self.syncTapped()
        }
    }

    // MARK: - Import

    @objc private func syncTapped() {
        syncButton.isEnabled = false
        statusLabel.stringValue = "Lese Bestellungen…"
        webView.evaluateJavaScript(Self.scraperJS) { [weak self] result, error in
            guard let self else { return }
            if let error {
                self.statusLabel.stringValue = "Fehler beim Lesen der Seite."
                AppLogger.log("amazon scrape JS error: \(error)", category: "Amazon", level: "WARN")
                self.syncButton.isEnabled = true
                return
            }
            let json = (result as? String) ?? "[]"
            let orders = AmazonOrderParser.decode(json)
            AppLogger.log("amazon scraped \(orders.count) orders", category: "Amazon")
            guard !orders.isEmpty else {
                self.statusLabel.stringValue = "Keine Bestellungen erkannt — Seite Meine Bestellungen offen und Zeitraum gewählt?"
                self.syncButton.isEnabled = true
                if self.headless { self.finish(false) }   // im Hintergrund: Login nötig
                return
            }
            do {
                let result = try AmazonService.persist(orders, slotId: self.slotId, bankId: self.bankId)
                self.statusLabel.stringValue = "✅ \(result.scraped) Bestellungen gelesen · \(result.stored) gespeichert"
                self.onSynced?(result)
                self.finish(true)
            } catch {
                self.statusLabel.stringValue = "Fehler beim Speichern: \(error)"
                AppLogger.log("amazon persist failed: \(error)", category: "Amazon", level: "WARN")
                if self.headless { self.finish(false) }
            }
            self.syncButton.isEnabled = true
        }
    }

    // MARK: - Scraper

    /// Liest die im DOM gerenderten Bestellkarten. Generisch gehalten (mehrere
    /// Selektor-/Regex-Fallbacks), da Amazon das Markup häufig ändert — wird mit
    /// echtem HTML nachgehärtet. Gibt einen JSON-String zurück.
    private static let scraperJS = #"""
    (function() {
      function clean(s){ return (s||'').replace(/\s+/g,' ').trim(); }
      var cards = document.querySelectorAll('.order-card, li.order-card, .js-order-card, .a-box-group.order, .order');
      var out = [];
      cards.forEach(function(card){
        var t = card.innerText || '';
        var mt = t.match(/(\d{1,3}(?:[.  ]\d{3})*,\d{2})\s*€|EUR\s*(\d{1,3}(?:[.  ]\d{3})*,\d{2})/);
        var totalText = mt ? (mt[1] || mt[2] || '') : '';
        var md = t.match(/(\d{1,2}\.\s*(?:Januar|Februar|März|Marz|April|Mai|Juni|Juli|August|September|Oktober|November|Dezember)\s*\d{4})|(\d{1,2}\.\d{1,2}\.\d{4})/);
        var dateText = md ? (md[1] || md[2] || '') : '';
        var mi = t.match(/(\d{3}-\d{7}-\d{7})/);
        var id = mi ? mi[1] : '';
        var items = [];
        card.querySelectorAll('a[href*="/product/"], a[href*="/dp/"], a[href*="/gp/product/"]').forEach(function(a){
          var n = clean(a.textContent);
          if (n && n.length > 2 && items.indexOf(n) < 0) items.push(n);
        });
        if (totalText || dateText || items.length) {
          out.push({ id: id, dateText: dateText, totalText: totalText, items: items });
        }
      });
      return JSON.stringify(out);
    })();
    """#
}
