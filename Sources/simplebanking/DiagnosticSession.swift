import Foundation
import AppKit
import Network

// MARK: - DiagnosticSession
//
// Orchestriert eine zeitlich klar abgegrenzte „Bank-Diagnose". Ablauf:
//
//   1. Logger-Zustand merken und auf `enabled=true` setzen
//   2. Pro Slot (sequenziell, Bank-Rate-Limits respektieren):
//      a) Slot aktiv schalten (Switch + CredentialsStore.activeSlotId)
//      b) Credentials mit Master-Passwort laden
//      c) `fetchBalances()` aufrufen, Dauer messen, Outcome speichern
//      d) `fetchTransactions(from: 30d ago)` aufrufen, Outcome speichern
//      e) Bei jedem Fehler: AppLogger schreibt Detail-Log; YAXI-SDK-Trace
//         entsteht über die bestehende `writeTrace()`-Logik in YaxiService
//   3. Original-Slot wiederherstellen, Logger-Zustand zurück
//   4. `summary.txt` ins root Log-Verzeichnis schreiben (kein neuer Subdir)
//   5. Erzeugte Trace-Files (mtime > Session-Start) für den Mail-Versand
//      sammeln — der User schickt nur diese Session, kein Alt-Material.

@MainActor
final class DiagnosticSession: ObservableObject {

    let id: String
    let startedAt: Date

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var probes: [SlotProbe] = []

    enum Phase {
        case idle
        case running(slotIndex: Int, total: Int, label: String)
        case done(Report)
        case failed(String)
    }

    struct Report {
        let id: String
        let startedAt: Date
        let finishedAt: Date
        let probes: [SlotProbe]
        let summaryFile: URL
        let mailAttachments: [URL]
    }

    struct SlotProbe: Identifiable, Equatable {
        let slotId: String
        let bankName: String
        let ibanPrefix: String
        let balance: ProbeResult
        let transactions: ProbeResult
        var id: String { slotId }
    }

    enum ProbeResult: Equatable {
        case ok(durationMs: Int)
        case failed(message: String, durationMs: Int)
        case skipped(reason: String)

        var glyph: String {
            switch self {
            case .ok:      return "✓"
            case .failed:  return "✗"
            case .skipped: return "—"
            }
        }
    }

    // MARK: - Init / lifecycle

    private let originalLoggerEnabled: Bool
    private let originalActiveIndex: Int
    private let originalSlotContext: SlotContext.Snapshot

    init() {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        self.id = f.string(from: Date())
        self.startedAt = Date()
        self.originalLoggerEnabled = AppLogger.isEnabled
        self.originalActiveIndex = MultibankingStore.shared.activeIndex
        // Snapshot der ZENTRALEN Slot-Pointer (Yaxi + Credentials + DB) —
        // Diagnose schaltet pro Slot atomar via SlotContext.activate, damit
        // alle 3 Layer immer konsistent sind. Vorher manuelles Set von 2/3
        // Layern → Cross-Slot-Auth + falsche DB-Schreibziele.
        self.originalSlotContext = SlotContext.snapshot()
        AppLogger.log("diagnostic: session \(id) created", category: "Diagnostic")
        // Logger wird in run() aktiviert, NICHT hier — sonst bleibt
        // verbose-Logging aktiv wenn der User das Sheet öffnet und ohne
        // Probe wieder schließt (Datenschutz-Risiko in Banking-App).
    }

    /// Stellt Logger- und Slot-Zustand wieder her. Idempotent; wird aus
    /// `run()` und aus `.onDisappear` der Sheet gerufen.
    func finalize() async {
        MultibankingStore.shared.setActive(index: originalActiveIndex)
        SlotContext.restore(originalSlotContext)
        // SessionStore-Cache ist seit Refactor 2026-05-19 per-slot lazy —
        // kein expliziter Reload mehr nötig.
        if !originalLoggerEnabled && AppLogger.isEnabled {
            AppLogger.setEnabled(false)
            AppLogger.log("diagnostic: logger restored to disabled", category: "Diagnostic")
        }
    }

    // MARK: - Probe execution

    /// Probiert sequentiell alle Slots. Ruft `progress` bei jedem Slot-Wechsel
    /// auf, damit die UI mitlaufen kann. Liefert `Report` zurück; UI kann
    /// gleichzeitig `phase` per Combine beobachten.
    func run(masterPassword: String) async {
        let slots = MultibankingStore.shared.slots
        guard !slots.isEmpty else {
            phase = .failed(L10n.t("Keine Banken konfiguriert.", "No banks configured."))
            return  // Kein finalize nötig — Logger wurde nie aktiviert.
        }
        // Erst HIER Logger anschalten — alles davor (init, no-slots-Guard)
        // läuft mit dem User-konfigurierten Logger-State.
        if !originalLoggerEnabled {
            AppLogger.setEnabled(true)
        }
        AppLogger.log("diagnostic: session \(id) started", category: "Diagnostic")

        // Date format für from=YYYY-MM-DD (laut YaxiService.fetchTransactions)
        let isoDate: DateFormatter = {
            let f = DateFormatter()
            f.dateFormat = "yyyy-MM-dd"
            return f
        }()
        let from30d = isoDate.string(from: Date().addingTimeInterval(-30 * 24 * 3600))

        var collected: [SlotProbe] = []

        for (idx, slot) in slots.enumerated() {
            // Cancel-Check zwischen Slots — wenn der User die Sheet zumacht,
            // soll die Diagnose nicht weiter Banken anrufen.
            if Task.isCancelled {
                AppLogger.log("diagnostic: session \(id) cancelled at slot \(idx)/\(slots.count)",
                              category: "Diagnostic", level: "WARN")
                break
            }
            phase = .running(slotIndex: idx + 1, total: slots.count, label: slot.displayName)

            MultibankingStore.shared.setActive(index: idx)
            // Atomarer Switch aller 3 Storage-Layer (Yaxi/Credentials/DB) —
            // sonst feuern fetchBalances/fetchTransactions mit Connection-/
            // Session-Daten des vorherigen Slots gegen die Bank des neuen
            // (Cross-Slot-Auth), bzw. Trace-Schreibziele landen im falschen Slot.
            SlotContext.activate(slotId: slot.id)
            // SessionStore-Cache ist per-slot lazy (Refactor 2026-05-19) —
            // der nachfolgende fetchBalances/fetchTransactions lädt automatisch
            // den richtigen Slot. Cache aber sicherheitshalber invalidieren,
            // falls die Diagnose-Sitzung gerade nach externen Disk-Schreibern
            // den Slot anspricht.
            await YaxiService.sessionStore.invalidateCache(slotId: slot.id)
            // Kurzer Tick: SessionStore lauscht auf Slot-Wechsel über Notifications
            // / Combine; wir geben ihm eine Slice Time, sich auf den neuen Slot
            // einzustellen. 100 ms ist konservativ und unmerklich für den User.
            try? await Task.sleep(nanoseconds: 100_000_000)

            let probe = await probeSlot(slot: slot, masterPassword: masterPassword, from30d: from30d)
            collected.append(probe)
            await MainActor.run { self.probes = collected }
        }

        // Slot-Restore
        await finalize()

        // Summary schreiben + Mail-Attachements zusammenstellen
        let finishedAt = Date()
        let summaryURL = writeSummary(probes: collected, finishedAt: finishedAt)
        let attachments = collectMailAttachments(summaryURL: summaryURL)

        let report = Report(
            id: id,
            startedAt: startedAt,
            finishedAt: finishedAt,
            probes: collected,
            summaryFile: summaryURL,
            mailAttachments: attachments
        )
        phase = .done(report)
        AppLogger.log("diagnostic: session \(id) finished — \(collected.count) slots", category: "Diagnostic")
    }

    private func probeSlot(slot: BankSlot, masterPassword: String, from30d: String) async -> SlotProbe {
        let ibanPrefix = String(slot.iban.prefix(8))
        let bankName = slot.displayName.nilIfEmpty ?? slot.nickname?.nilIfEmpty ?? slot.id

        // Credentials laden
        let creds: StoredCredentials
        do {
            creds = try CredentialsStore.load(masterPassword: masterPassword)
        } catch {
            AppLogger.log("diagnostic: credentials load failed slot=\(slot.id.prefix(8)): \(error)",
                          category: "Diagnostic", level: "WARN")
            return SlotProbe(
                slotId: slot.id, bankName: bankName, ibanPrefix: ibanPrefix,
                balance: .skipped(reason: L10n.t("Keine Credentials gespeichert", "No credentials stored")),
                transactions: .skipped(reason: L10n.t("Keine Credentials gespeichert", "No credentials stored"))
            )
        }

        // Cancellation-Check vor dem ersten Bankcall — User hat das Sheet
        // bereits geschlossen, bevor wir auf die Bank zugegriffen haben.
        // Sauberer Abbruch ohne den Slot-Kontext zu verschmutzen.
        if Task.isCancelled {
            let cancelled = L10n.t("Abgebrochen", "Cancelled")
            return SlotProbe(
                slotId: slot.id, bankName: bankName, ibanPrefix: ibanPrefix,
                balance: .skipped(reason: cancelled),
                transactions: .skipped(reason: cancelled)
            )
        }

        // Balance-Probe — alwaysTrace=true erzwingt YAXI-Trace auch im Erfolgsfall.
        // Wichtig: fetchBalances kann auch ohne throw mit ok=false zurückkehren
        // (bank busy, no connectionId, missing iban) — wir MÜSSEN response.ok
        // auswerten, sonst lügt der Diagnose-Report.
        let balanceStart = Date()
        let balanceResult: ProbeResult
        do {
            let response = try await YaxiService.fetchBalances(
                userId: creds.userId, password: creds.password,
                alwaysTrace: true,
                callSource: .diagnostic
            )
            let dur = msSince(balanceStart)
            if response.ok {
                balanceResult = .ok(durationMs: dur)
                AppLogger.log("diagnostic: \(slot.id.prefix(8)) balance ok in \(dur)ms",
                              category: "Diagnostic")
            } else {
                let msg = response.userMessage ?? response.error ?? "unknown"
                if response.error == "bank busy" {
                    // Mutex-Contention ist kein Bank-Fehler — als skipped markieren
                    balanceResult = .skipped(reason: L10n.t("Slot momentan besetzt", "Slot busy"))
                } else {
                    balanceResult = .failed(message: msg, durationMs: dur)
                }
                AppLogger.log("diagnostic: \(slot.id.prefix(8)) balance NOT-OK in \(dur)ms: \(msg)",
                              category: "Diagnostic", level: "ERROR")
            }
        } catch {
            let dur = msSince(balanceStart)
            let msg = humanReadable(error)
            balanceResult = .failed(message: msg, durationMs: dur)
            AppLogger.log("diagnostic: \(slot.id.prefix(8)) balance THREW in \(dur)ms: \(msg)",
                          category: "Diagnostic", level: "ERROR")
        }

        // Cancellation-Check zwischen Balance- und TX-Call. Wenn der User
        // während fetchBalances geschlossen hat, hat onDisappear bereits
        // finalize() gerufen und den ursprünglichen Slot-Kontext restauriert.
        // Ein weiterer Bankcall hier würde im falschen Kontext landen und
        // den restaurierten Slot mit Diagnose-Daten verschmutzen.
        if Task.isCancelled {
            return SlotProbe(
                slotId: slot.id, bankName: bankName, ibanPrefix: ibanPrefix,
                balance: balanceResult,
                transactions: .skipped(reason: L10n.t("Abgebrochen", "Cancelled"))
            )
        }

        // Transactions-Probe — auch wenn Balance failed, weil sich beide
        // unterschiedlich verhalten (z.B. Sparkasse: Balance ok, TX consent expired).
        let txStart = Date()
        let txResult: ProbeResult
        do {
            let response = try await YaxiService.fetchTransactions(
                userId: creds.userId, password: creds.password,
                from: from30d, alwaysTrace: true,
                callSource: .diagnostic
            )
            let dur = msSince(txStart)
            if response.ok ?? false {
                txResult = .ok(durationMs: dur)
                AppLogger.log("diagnostic: \(slot.id.prefix(8)) transactions ok in \(dur)ms",
                              category: "Diagnostic")
            } else {
                let msg = response.userMessage ?? response.error ?? "unknown"
                if response.error == "bank busy" {
                    txResult = .skipped(reason: L10n.t("Slot momentan besetzt", "Slot busy"))
                } else {
                    txResult = .failed(message: msg, durationMs: dur)
                }
                AppLogger.log("diagnostic: \(slot.id.prefix(8)) transactions NOT-OK in \(dur)ms: \(msg)",
                              category: "Diagnostic", level: "ERROR")
            }
        } catch {
            let dur = msSince(txStart)
            let msg = humanReadable(error)
            txResult = .failed(message: msg, durationMs: dur)
            AppLogger.log("diagnostic: \(slot.id.prefix(8)) transactions THREW in \(dur)ms: \(msg)",
                          category: "Diagnostic", level: "ERROR")
        }

        return SlotProbe(
            slotId: slot.id,
            bankName: bankName,
            ibanPrefix: ibanPrefix,
            balance: balanceResult,
            transactions: txResult
        )
    }

    // MARK: - Summary + attachments

    private func writeSummary(probes: [SlotProbe], finishedAt: Date) -> URL {
        let url = AppLogger.logDirectoryURL.appendingPathComponent("diagnostic-summary-\(id).txt")
        var s = ""
        s += "==============================================\n"
        s += " simplebanking Bank-Diagnose\n"
        s += "==============================================\n"
        s += "Datum/Zeit:  \(formatHuman(startedAt))\n"
        s += "Session-ID:  \(id)\n"
        s += "Dauer:       \(Int(finishedAt.timeIntervalSince(startedAt)))s\n"
        s += "\n"

        // ── System ──
        s += "── System ───────────────────────────────────\n"
        s += "App:         simplebanking \(appVersion())\n"
        s += "Routex SDK:  \(routexSDKVersion())\n"
        s += "macOS:       \(macOSVersion())\n"
        s += "Architektur: \(systemArchitecture())\n"
        s += "Locale:      \(Locale.current.identifier)  TZ: \(TimeZone.current.identifier)\n"
        s += "Demo-Mode:   \(UserDefaults.standard.bool(forKey: "demoMode") ? "AN" : "AUS")\n"
        s += "Logger:      \(AppLogger.isEnabled ? "AN" : "AUS")  (vor Session: \(originalLoggerEnabled ? "AN" : "AUS"))\n"
        s += "Lizenz:      \(licenseStatusLabel())\n"
        s += "Netzwerk:    \(networkStatusLabel())\n"
        s += "\n"

        // ── Slots ──
        s += "── Banken (\(probes.count)) ───────────────────────────\n"
        for p in probes {
            s += "\n[\(p.bankName)]\n"
            s += "  Slot-ID:     \(String(p.slotId.prefix(8)))…\n"
            s += "  IBAN:        \(p.ibanPrefix)…\n"
            s += "  Balance:     \(p.balance.glyph) \(describe(p.balance))\n"
            s += "  Umsätze:     \(p.transactions.glyph) \(describe(p.transactions))\n"
            s += "  Cached-Bal:  \(cachedBalanceLabel(slotId: p.slotId))\n"
            s += "  Last-Sync:   \(lastSyncLabel(slotId: p.slotId))\n"
        }
        s += "\n"

        // ── Traces ──
        let traces = newTraceFiles()
        s += "── YAXI-Traces (\(traces.count)) ────────────────────────\n"
        if traces.isEmpty {
            s += "  (keine Trace-IDs verfügbar — älteres SDK oder Probe nie an die Bank gegangen)\n"
        } else {
            for t in traces {
                let size = (try? t.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                s += "  - \(t.lastPathComponent)  (\(size)b)\n"
            }
        }
        s += "\n"

        // ── Anhänge ──
        s += "── Mail-Anhänge ─────────────────────────────\n"
        s += "  - \(AppLogger.logFileURL.lastPathComponent) (Haupt-Log)\n"
        s += "  - \(url.lastPathComponent) (diese Datei)\n"
        for t in traces {
            s += "  - trace/\(t.lastPathComponent)\n"
        }
        s += "\n"
        s += "Bei Rückfragen: support@simplebanking.de\n"

        try? s.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    // MARK: - System / network labels

    private func macOSVersion() -> String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    }

    private func systemArchitecture() -> String {
        #if arch(arm64)
        return "arm64 (Apple Silicon)"
        #elseif arch(x86_64)
        return "x86_64 (Intel)"
        #else
        return "unknown"
        #endif
    }

    private func licenseStatusLabel() -> String {
        guard LicenseConfig.licensingEnabled else { return "Gating deaktiviert" }
        let m = LicenseManager.shared
        #if DEBUG
        if UserDefaults.standard.bool(forKey: "license.masterCodeActive") {
            return "Master-Code aktiv (DEBUG-Test)"
        }
        #endif
        return m.isLicensed ? "Lizenziert" : "Nicht lizenziert"
    }

    private func networkStatusLabel() -> String {
        // Synchroner Snapshot via NWPathMonitor — wir geben dem Monitor max 500ms.
        // NetworkSnapshot ist eine kleine class wegen Sendable-Anforderungen
        // an den Closure (mutable captures werden sonst geblockt).
        let snapshot = NetworkSnapshot()
        let semaphore = DispatchSemaphore(value: 0)
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { path in
            snapshot.set(status: path.status, interfaces: path.availableInterfaces.map { "\($0.type)" })
            semaphore.signal()
        }
        let queue = DispatchQueue(label: "diagnostic.network")
        monitor.start(queue: queue)
        _ = semaphore.wait(timeout: .now() + 0.5)
        monitor.cancel()
        switch snapshot.status {
        case .satisfied:    return "online (\(snapshot.interfaces.joined(separator: ", ")))"
        case .unsatisfied:  return "offline"
        case .requiresConnection: return "wartet auf Verbindung"
        @unknown default:   return "unbekannt"
        }
    }

    private func cachedBalanceLabel(slotId: String) -> String {
        let raw = UserDefaults.standard.object(forKey: "simplebanking.cachedBalance.\(slotId)") as? Double
        guard let raw else { return "—" }
        let f = NumberFormatter()
        f.locale = Locale(identifier: "de_DE")
        f.minimumFractionDigits = 2
        f.maximumFractionDigits = 2
        return "€ \(f.string(from: NSNumber(value: raw)) ?? "\(raw)")"
    }

    private func lastSyncLabel(slotId: String) -> String {
        guard let date = UserDefaults.standard.object(forKey: "simplebanking.lastBalanceFetch.\(slotId)") as? Date else {
            return "nie"
        }
        let f = DateFormatter()
        f.locale = Locale(identifier: "de_DE")
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.string(from: date)
    }

    /// Zusammenstellung der Files fürs Mail-Attachement: nur was zur
    /// Session gehört. Keine Alt-Logs / fremde Setup-Diagnosen mitschicken.
    private func collectMailAttachments(summaryURL: URL) -> [URL] {
        var urls: [URL] = [summaryURL]
        if FileManager.default.fileExists(atPath: AppLogger.logFileURL.path) {
            urls.append(AppLogger.logFileURL)
        }
        urls.append(contentsOf: newTraceFiles())
        return urls
    }

    private func newTraceFiles() -> [URL] {
        let traceDir = AppLogger.logDirectoryURL.appendingPathComponent("trace")
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: traceDir,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return entries
            .filter { (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast >= startedAt }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    // MARK: - Helpers

    private func msSince(_ date: Date) -> Int {
        Int(Date().timeIntervalSince(date) * 1000)
    }

    private func humanReadable(_ error: Error) -> String {
        let raw = "\(error)"
        // Routex-Errors sind oft sehr lang; auf 200 chars cappen für summary.txt
        return String(raw.prefix(200))
    }

    private func describe(_ r: ProbeResult) -> String {
        switch r {
        case .ok(let ms):                return "\(ms)ms ✓"
        case .failed(let msg, let ms):   return "\(ms)ms ✗ (\(String(msg.prefix(60))))"
        case .skipped(let reason):       return "— \(reason)"
        }
    }

    private func formatHuman(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "de_DE")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f.string(from: date)
    }

    private func appVersion() -> String {
        let dict = Bundle.main.infoDictionary
        let v = dict?["CFBundleShortVersionString"] as? String ?? "?"
        let b = dict?["CFBundleVersion"] as? String ?? "?"
        return "\(v) (Build \(b))"
    }

    /// Routex-SDK-Version + Revision-Prefix aus Info.plist (von build-app.sh
    /// aus `Package.resolved` injiziert). Bei Dev-Build via `swift run` ohne
    /// build-app.sh-Wrap fehlt der Key — wir geben "unknown" aus.
    private func routexSDKVersion() -> String {
        let dict = Bundle.main.infoDictionary
        let v = dict?["SBRoutexVersion"] as? String
        let r = dict?["SBRoutexRevision"] as? String
        switch (v, r) {
        case (let v?, let r?) where v != "?" && r != "?":
            return "\(v) (\(r))"
        case (let v?, _) where v != "?":
            return v
        default:
            return "unknown"
        }
    }
}

private extension String {
    func padded(to length: Int) -> String {
        if count >= length { return String(prefix(length)) }
        return self + String(repeating: " ", count: length - count)
    }
}

/// Thread-safe Snapshot des aktuellen Netzwerk-Pfads. Wird vom NWPathMonitor-
/// Closure befüllt; Closure läuft auf eigener Queue, daher atomic via NSLock.
private final class NetworkSnapshot: @unchecked Sendable {
    private let lock = NSLock()
    private var _status: NWPath.Status = .unsatisfied
    private var _interfaces: [String] = []

    var status: NWPath.Status {
        lock.lock(); defer { lock.unlock() }; return _status
    }
    var interfaces: [String] {
        lock.lock(); defer { lock.unlock() }; return _interfaces
    }
    func set(status: NWPath.Status, interfaces: [String]) {
        lock.lock(); defer { lock.unlock() }
        _status = status
        _interfaces = interfaces
    }
}
