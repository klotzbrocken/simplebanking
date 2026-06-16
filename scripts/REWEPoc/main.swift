import AppKit
import WebKit
import PDFKit

// REWE eBon — Phase-0-PoC. PDF-Abruf via curl-Subprozess (Nicht-WebKit-Client,
// setzt Sec-Fetch-User: ?1 als Klartext — das war der Knackpunkt). Login via
// WKWebView, Cookies (nur www.rewe.de-Domain) ernten, Liste via URLSession.

let UA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/148.0.0.0 Safari/537.36"
let IM_MARKT = "https://www.rewe.de/shop/mydata/meine-einkaeufe/im-markt"

func cookieHostMatches(_ cookieDomain: String, _ host: String) -> Bool {
    let d = cookieDomain.hasPrefix(".") ? String(cookieDomain.dropFirst()) : cookieDomain
    return host == d || host.hasSuffix("." + d)
}

/// PDF via curl-Subprozess (off-main). Liefert (HTTP-Code, Bytes).
func curlPDF(_ urlStr: String, cookie: String, ua: String) async -> (Int, Data) {
    await Task.detached { () -> (Int, Data) in
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("rewe-\(UUID().uuidString).pdf")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        p.arguments = [
            "-sS", "--http1.1",
            "-H", "User-Agent: \(ua)",
            "-H", "Accept: text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
            "-H", "Referer: \(IM_MARKT)",
            "-H", "Sec-Fetch-Dest: document", "-H", "Sec-Fetch-Mode: navigate",
            "-H", "Sec-Fetch-Site: same-origin", "-H", "Sec-Fetch-User: ?1",
            "-H", "Upgrade-Insecure-Requests: 1",
            "-H", "Cookie: \(cookie)",
            "-o", tmp.path, "-w", "%{http_code}", urlStr,
        ]
        let out = Pipe(); p.standardOutput = out
        let err = Pipe(); p.standardError = err
        do { try p.run() } catch { return (-1, Data()) }
        p.waitUntilExit()
        let codeStr = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let code = Int(codeStr.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        let data = (try? Data(contentsOf: tmp)) ?? Data()
        try? FileManager.default.removeItem(at: tmp)
        return (code, data)
    }.value
}

/// Entpackt eine eBon-ZIP (via /usr/bin/unzip) und liefert alle enthaltenen PDFs.
func unzipPDFs(_ zip: Data) async -> [Data] {
    await Task.detached { () -> [Data] in
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("rewezip-\(UUID().uuidString)")
        let zipURL = dir.appendingPathExtension("zip")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? zip.write(to: zipURL)
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        p.arguments = ["-o", "-q", zipURL.path, "-d", dir.path]
        do { try p.run(); p.waitUntilExit() } catch { return [] }
        var pdfs: [Data] = []
        if let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
            for f in files where f.pathExtension.lowercased() == "pdf" {
                if let d = try? Data(contentsOf: f) { pdfs.append(d) }
            }
        }
        try? FileManager.default.removeItem(at: dir)
        try? FileManager.default.removeItem(at: zipURL)
        return pdfs
    }.value
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    var webView: WKWebView!
    var output: NSTextView!
    let mono = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)

    func applicationDidFinishLaunching(_ note: Notification) {
        let frame = NSRect(x: 0, y: 0, width: 1200, height: 820)
        window = NSWindow(contentRect: frame, styleMask: [.titled, .closable, .resizable, .miniaturizable],
                          backing: .buffered, defer: false)
        window.title = "REWE eBon — Phase 0 PoC (curl)"
        window.center()
        let content = NSView(frame: frame); content.autoresizesSubviews = true
        let bar = NSView(frame: NSRect(x: 0, y: frame.height - 44, width: frame.width, height: 44))
        bar.autoresizingMask = [.width, .minYMargin]
        let run = NSButton(title: "Bons holen & parsen", target: self, action: #selector(runTapped))
        run.bezelStyle = .rounded; run.frame = NSRect(x: 8, y: 7, width: 190, height: 30)
        let clear = NSButton(title: "Log leeren", target: self, action: #selector(clearTapped))
        clear.bezelStyle = .rounded; clear.frame = NSRect(x: 204, y: 7, width: 110, height: 30)
        let reset = NSButton(title: "Session zurücksetzen", target: self, action: #selector(resetTapped))
        reset.bezelStyle = .rounded; reset.frame = NSRect(x: 320, y: 7, width: 180, height: 30)
        bar.addSubview(run); bar.addSubview(clear); bar.addSubview(reset)
        let split = NSSplitView(frame: NSRect(x: 0, y: 0, width: frame.width, height: frame.height - 44))
        split.autoresizingMask = [.width, .height]; split.isVertical = true; split.dividerStyle = .thin
        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 640, height: split.bounds.height))
        // KEIN customUserAgent! Ein gefälschter UA + WebKit-TLS = inkonsistent →
        // Cloudflare-Turnstile-Schleife. Stattdessen liest curl den ECHTEN
        // WebView-UA aus (siehe webViewUA()), damit Cookies+Abruf UA-konsistent sind.
        let scroll = NSScrollView(frame: NSRect(x: 640, y: 0, width: 560, height: split.bounds.height))
        scroll.hasVerticalScroller = true; scroll.borderType = .noBorder
        let tv = NSTextView(frame: scroll.bounds)
        tv.isEditable = false; tv.font = mono
        tv.minSize = NSSize(width: 0, height: 0)
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        tv.isVerticallyResizable = true; tv.isHorizontallyResizable = false
        tv.autoresizingMask = [.width]
        tv.textContainer?.widthTracksTextView = true
        tv.textContainer?.containerSize = NSSize(width: scroll.bounds.width, height: CGFloat.greatestFiniteMagnitude)
        scroll.documentView = tv; output = tv
        split.addArrangedSubview(webView); split.addArrangedSubview(scroll)
        content.addSubview(split); content.addSubview(bar)
        window.contentView = content; window.makeKeyAndOrderFront(nil)
        NSApp.setActivationPolicy(.regular); NSApp.activate(ignoringOtherApps: true)
        log("➊ Auf rewe.de einloggen (»Im Markt«).")
        log("➋ Dann »Bons holen & parsen«. PDF via curl.\n")
        webView.load(URLRequest(url: URL(string: IM_MARKT)!))
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ s: NSApplication) -> Bool { true }

    func log(_ s: String) {
        output.textStorage?.append(NSAttributedString(string: s + "\n",
            attributes: [.font: mono, .foregroundColor: NSColor.textColor]))
        output.scrollToEndOfDocument(nil)
    }
    @objc func clearTapped() { output.string = "" }
    @objc func runTapped() { Task { await fetchAndParse() } }
    @objc func resetTapped() {
        let store = webView.configuration.websiteDataStore
        store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast) {
            Task { @MainActor in
                self.log("🧹 Session/Cookies gelöscht. Bitte komplett neu einloggen.")
                self.webView.load(URLRequest(url: URL(string: IM_MARKT)!))
            }
        }
    }

    func cookieHeader(host: String = "www.rewe.de") async -> String {
        let store = webView.configuration.websiteDataStore.httpCookieStore
        return await withCheckedContinuation { (cont: CheckedContinuation<String, Never>) in
            store.getAllCookies { cookies in
                cont.resume(returning: cookies.filter { cookieHostMatches($0.domain, host) }
                    .map { "\($0.name)=\($0.value)" }.joined(separator: "; "))
            }
        }
    }

    func webViewUA() async -> String {
        await withCheckedContinuation { (cont: CheckedContinuation<String, Never>) in
            webView.evaluateJavaScript("navigator.userAgent") { result, _ in
                cont.resume(returning: (result as? String) ?? UA)
            }
        }
    }

    func fetchAndParse() async {
        let cookie = await cookieHeader()
        guard cookie.contains("rstp=") else { log("⚠️ Nicht eingeloggt (kein rstp)."); return }
        let ua = await webViewUA()
        log("UA: \(ua.prefix(60))…")
        do {
            var lreq = URLRequest(url: URL(string: "https://www.rewe.de/shop/api/receipts/")!)
            lreq.setValue(cookie, forHTTPHeaderField: "Cookie")
            lreq.setValue(ua, forHTTPHeaderField: "User-Agent")
            lreq.setValue("application/json", forHTTPHeaderField: "Accept")
            lreq.setValue(IM_MARKT, forHTTPHeaderField: "Referer")
            let cfg = URLSessionConfiguration.ephemeral; cfg.httpCookieStorage = nil; cfg.httpShouldSetCookies = false
            let (ldata, lresp) = try await URLSession(configuration: cfg).data(for: lreq)
            log("=== Liste HTTP \((lresp as? HTTPURLResponse)?.statusCode ?? 0) ===")
            guard let obj = try? JSONSerialization.jsonObject(with: ldata) as? [String: Any],
                  let items = obj["items"] as? [[String: Any]],
                  let rid = items.first?["receiptId"] as? String else { log("⚠️ Liste fehlgeschlagen."); return }
            let bonTotal = (items.first?["receiptTotalPrice"] as? Int) ?? 0
            log("✅ \(items.count) Bons · erster: \(euro(bonTotal))")

            // ZIP aller Bons in EINEM Request. Phase-2-Frage: geht das sauber via
            // URLSession, oder braucht's den curl-Subprozess?
            func isZip(_ d: Data) -> Bool { d.prefix(2).elementsEqual(Array("PK".utf8)) }
            let zipURL = "https://www.rewe.de/api/receipts/zip"
            var zdata = Data(); var via = ""

            // 1) URLSession (sauberer nativer Weg)
            var zreq = URLRequest(url: URL(string: zipURL)!)
            zreq.setValue(cookie, forHTTPHeaderField: "Cookie")
            zreq.setValue(ua, forHTTPHeaderField: "User-Agent")
            zreq.setValue("text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8", forHTTPHeaderField: "Accept")
            zreq.setValue(IM_MARKT, forHTTPHeaderField: "Referer")
            zreq.setValue("document", forHTTPHeaderField: "Sec-Fetch-Dest")
            zreq.setValue("navigate", forHTTPHeaderField: "Sec-Fetch-Mode")
            zreq.setValue("same-origin", forHTTPHeaderField: "Sec-Fetch-Site")
            zreq.setValue("?1", forHTTPHeaderField: "Sec-Fetch-User")
            let zcfg = URLSessionConfiguration.ephemeral; zcfg.httpCookieStorage = nil; zcfg.httpShouldSetCookies = false
            if let (d, resp) = try? await URLSession(configuration: zcfg).data(for: zreq) {
                let c = (resp as? HTTPURLResponse)?.statusCode ?? 0
                log("ZIP via URLSession: HTTP \(c) · \(d.count) bytes · ZIP=\(isZip(d))")
                if isZip(d) { zdata = d; via = "URLSession ✅" }
            } else {
                log("ZIP via URLSession: Fehler")
            }

            // 2) Fallback curl (PoC-Beweis)
            if zdata.isEmpty {
                let (c, d) = await curlPDF(zipURL, cookie: cookie, ua: ua)
                log("ZIP via curl: HTTP \(c) · \(d.count) bytes · ZIP=\(isZip(d))")
                if isZip(d) { zdata = d; via = "curl (URLSession ging NICHT)" }
            }

            guard !zdata.isEmpty else { log("⚠️ ZIP weder via URLSession noch curl bekommen."); return }
            log("📦 ZIP via \(via)")
            let pdfs = await unzipPDFs(zdata)
            log("📦 \(pdfs.count) PDFs im ZIP")
            guard let first = pdfs.first, let zdoc = PDFDocument(data: first), let ztext = zdoc.string, !ztext.isEmpty else {
                log("⚠️ ZIP da, aber keine lesbare PDF darin."); return
            }
            let zp = ReceiptParser.parse(ztext)
            let zsum = zp.items.reduce(0) { $0 + $1.totalCents }
            log("=== ERSTER BON AUS ZIP === Artikel \(zp.items.count) · Σ \(euro(zsum)) vs \(zp.totalCents.map(euro) ?? "—") → \(zsum == (zp.totalCents ?? -1) ? "✅ MATCH" : "⚠️")")
        } catch { log("❌ \(error)") }
    }

    func euro(_ c: Int) -> String { String(format: "%.2f €", Double(c) / 100) }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
