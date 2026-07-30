import AppKit
import Foundation

// MARK: - BankSlot

/// Herkunft eines Slots. `nil`/`.yaxi` = klassischer Bank-Slot über YAXI.
/// `.rewe` / `.dm` = eBon-Slots (kein YAXI/IBAN, eigener Datenpfad, kein Refresh
/// über die Bank-Call-Pfade — nur manueller Sync über ein Login-Fenster).
/// `CaseIterable`, damit Aufräum-Pfade (z.B. `MerchantSession.clearAll` beim
/// vollständigen Zurücksetzen) alle Quellen erfassen und ein künftig ergänzter
/// Händler nicht still übersehen wird.
enum SlotSource: String, Codable, CaseIterable {
    case yaxi
    case rewe
    case dm
    case amazon
    case paypal
}

struct BankSlot: Codable, Identifiable, Equatable {
    let id: String          // UUID string, stable identifier
    var iban: String
    var displayName: String
    var logoId: String?
    var currency: String? = nil   // ISO-Code, z.B. "EUR", "USD" — auto aus Balance-API
    var nickname: String? = nil   // nutzer-definierbares Kürzel, z.B. "Privat", "Reisen"
    var customColor: String? = nil  // user-chosen hex color (without #), e.g. "FF5500"
    /// `nil` = Legacy/Bank-Slot (YAXI). Optional gehalten, damit bereits
    /// persistierte Slots ohne dieses Feld weiterhin sauber dekodieren.
    var source: SlotSource? = nil

    /// True für REWE-eBon-Slots — Bank-Call-/YAXI-Pfade müssen diese überspringen.
    var isREWE: Bool { source == .rewe }
    /// True für dm-eBon-Slots.
    var isDM: Bool { source == .dm }
    /// True für Amazon-Bestell-Slots.
    var isAmazon: Bool { source == .amazon }
    /// True für PayPal-Slots. PayPal ist KEIN Receipt-Slot: es hat einen echten
    /// Kontostand und echte Transaktionen (normale DB + normale Umsatzliste),
    /// nur der Auth-/Refresh-Pfad läuft über einen eigenen Provider (nicht YAXI).
    var isPayPal: Bool { source == .paypal }
    /// True für jeden eBon-/Kassenbon-/Bestell-Slot (REWE, dm, Amazon): kein
    /// YAXI/IBAN, kein Auto-Refresh, Anzeige aus lokal gespeicherten Bons.
    /// Bank-Aggregat- und YAXI-Pfade müssen diese Slots überspringen.
    var isReceiptSlot: Bool { source == .rewe || source == .dm || source == .amazon }

    /// Marken-Logo des eBon-Slots (Menüleiste/Flyout/Panel) — quelle-abhängig.
    var receiptLogoImage: NSImage? {
        switch source {
        case .dm: return DMLogoAsset.image
        case .amazon: return AmazonLogoAsset.image
        default: return ReweLogoAsset.image
        }
    }
    /// Anzeigename des eBon-Slots.
    var receiptBrandName: String {
        switch source {
        case .dm: return "dm"
        case .amazon: return "Amazon"
        default: return "REWE"
        }
    }

    /// Marken-Logo für Menüleiste/Flyout/Pillen — deckt Receipt-Slots UND PayPal ab
    /// (PayPal ist kein Receipt-Slot, hat aber ein eigenes eingebettetes Logo).
    var brandLogoImage: NSImage? {
        if source == .paypal { return PayPalLogoAsset.image }
        return isReceiptSlot ? receiptLogoImage : nil
    }

    static func makeNew(iban: String, displayName: String, logoId: String?) -> BankSlot {
        BankSlot(id: UUID().uuidString, iban: iban, displayName: displayName, logoId: logoId)
    }

    /// Erzeugt einen REWE-eBon-Slot (kein IBAN/YAXI-Connection).
    static func makeREWE(displayName: String = "REWE") -> BankSlot {
        BankSlot(id: UUID().uuidString, iban: "", displayName: displayName,
                 logoId: "rewe", currency: "EUR", source: .rewe)
    }

    /// Erzeugt einen dm-eBon-Slot (kein IBAN/YAXI-Connection).
    static func makeDM(displayName: String = "dm") -> BankSlot {
        BankSlot(id: UUID().uuidString, iban: "", displayName: displayName,
                 logoId: "dm", currency: "EUR", source: .dm)
    }

    /// Erzeugt einen Amazon-Bestell-Slot (kein IBAN/YAXI-Connection).
    static func makeAmazon(displayName: String = "Amazon") -> BankSlot {
        BankSlot(id: UUID().uuidString, iban: "", displayName: displayName,
                 logoId: "amazon", currency: "EUR", source: .amazon)
    }

    /// Erzeugt einen PayPal-Slot (echtes Konto via NVP-API, kein IBAN/YAXI).
    static func makePayPal(displayName: String = "PayPal") -> BankSlot {
        BankSlot(id: UUID().uuidString, iban: "", displayName: displayName,
                 logoId: "paypal", currency: "EUR", source: .paypal)
    }
}

// MARK: - MultibankingStore

/// Single source of truth for all bank slots and the active slot index.
/// Thread-safe via @MainActor; persist to UserDefaults as JSON.
@MainActor
final class MultibankingStore: ObservableObject {

    static let shared = MultibankingStore()

    /// Im Testlauf eine Wegwerf-Domain statt der echten.
    ///
    /// `UserDefaults.standard` ist unter Test dieselbe wie im Betrieb — ein Test, der die
    /// Slot-Liste austauscht, hätte die echten Konten des Nutzers überschrieben. Nur das
    /// App-Support-Verzeichnis war bisher abgeschirmt (`CredentialsStore.appSupportURL`),
    /// die UserDefaults nicht. Dieselbe Begründung, dieselbe Erkennung: `XCTestCase`
    /// existiert genau dann, wenn das Test-Bundle geladen ist — vom Linker garantiert,
    /// keine Heuristik.
    static let defaults: UserDefaults = {
        let sandboxName = "simplebanking.tests.multibanking"
        if NSClassFromString("XCTestCase") != nil,
           let sandbox = UserDefaults(suiteName: sandboxName) {
            sandbox.removePersistentDomain(forName: sandboxName)
            return sandbox
        }
        return .standard
    }()

    private let slotsKey        = "simplebanking.multibanking.slots"
    private let activeIndexKey  = "simplebanking.multibanking.activeIndex"

    @Published private(set) var slots: [BankSlot] = []
    @Published private(set) var activeIndex: Int = 0
    /// Monoton steigender Counter, der bei jedem Slot-Switch inkrementiert
    /// wird. Async Bank-Calls schnappen einen Snapshot und verwerfen ihre
    /// Continuation, wenn der Snapshot nicht mehr passt — verhindert dass
    /// Daten aus Slot A nach einem Switch im Kontext von Slot B landen.
    /// Genutzt vom `YaxiService` SCA-Field-Branch für die Slot-Race-Defense.
    @Published private(set) var activeSlotEpoch: Int = 0

    var activeSlot: BankSlot? { slots.indices.contains(activeIndex) ? slots[activeIndex] : slots.first }

    /// Anzahl echter Bank-Konten (ohne eBon-Slots wie REWE/dm). Unified bezieht
    /// sich NUR auf echte Konten — die Übersicht ist erst ab 2 davon sinnvoll.
    var realSlotCount: Int { slots.filter { !$0.isReceiptSlot }.count }

    private init() {
        load()
        migrateFromLegacyIfNeeded()
        fixDuplicateDisplayNames()
    }

    // MARK: - Public API

    /// `makeActive`/`autoUnified` default true (bestehendes Bank-Verhalten).
    /// REWE legt den Slot bewusst NICHT-aktiv und ohne Aggregat-Zwang an, damit
    /// das Hinzufügen mitten in der Session die aktive Bank-Ansicht nicht
    /// destabilisiert (vermeidet Re-Render auf einen halb-fertigen Slot).
    func addSlot(_ slot: BankSlot, makeActive: Bool = true, autoUnified: Bool = true) {
        slots.append(slot)
        if makeActive { activeIndex = slots.count - 1 }
        save()
        // Unified nur bei >=2 ECHTEN Konten auto-aktivieren (eBon-Slots zählen nicht).
        if autoUnified, realSlotCount > 1 {
            UserDefaults.standard.set(true, forKey: "unifiedModeEnabled")
        }
    }

    func removeSlot(id: String) {
        guard let idx = slots.firstIndex(where: { $0.id == id }) else { return }
        let removed = slots[idx]
        // Purge transactions for this slot from local DB.
        try? TransactionsDatabase.deleteTransactions(forSlotId: id)
        // eBon-Slots (REWE/dm/Amazon): zusätzlich die gespeicherten Bons UND die
        // lokale Händler-Login-Sitzung (Cookies) löschen — sonst leaken Bon-Daten
        // und der Login bleibt erhalten.
        if removed.isReceiptSlot {
            try? ReweReceiptStore.deleteAll(slotId: id)
            if let source = removed.source { MerchantSession.clear(source: source) }
        }
        // Per-Slot Daten aufräumen — sonst leakt der entfernte Slot:
        //  - Bank-Credentials (encrypted, aber dead file auf Platte)
        //  - YAXI session/connectionData (sensitive)
        //  - cachedBalance.<id> + lastSeenTxSig.<id> in UserDefaults (Bloat)
        Self.purgePerSlotData(slotId: id)
        slots.remove(at: idx)
        if activeIndex >= slots.count { activeIndex = max(0, slots.count - 1) }
        save()
        // Auto-disable unified mode when fewer than 2 REAL accounts remain
        // (eBon-Slots wie REWE/dm zählen nicht).
        if realSlotCount <= 1 {
            UserDefaults.standard.set(false, forKey: "unifiedModeEnabled")
        }
    }

    /// Leert die Slot-Liste — für das vollständige Zurücksetzen.
    ///
    /// `performSecurityReset` löscht die UserDefaults als Ganzes, die Liste lebt aber
    /// zusätzlich im Speicher: Der nächste `save()` schrieb sie ungefragt zurück, und
    /// das eben zurückgesetzte Konto war wieder da. Gemeldet am 29.07. für einen
    /// REWE-Slot, den ein Kunde weder löschen noch zurücksetzen konnte.
    ///
    /// Die per-Slot-Daten räumt der Reset-Pfad selbst ab (Credentials, Sessions,
    /// UserDefaults-Domain); hier gehen nur die Dinge weg, die er nicht kennt: die
    /// Bons der Händler-Slots.
    func removeAllSlots() {
        for slot in slots where slot.isReceiptSlot {
            try? ReweReceiptStore.deleteAll(slotId: slot.id)
        }
        slots = []
        activeIndex = 0
        save()
    }

    /// Räumt alle slot-suffixed Persistenz-Spuren weg. **Die einzige Stelle dafür** —
    /// eine neue per-Slot-Persistenz gehört hierher und sonst nirgendwohin.
    ///
    /// Bis 2.0 löschte `SettingsPanel.deleteSlot` zusätzlich selbst: die
    /// Credentials-Datei (was die Legacy-Schutzklausel in
    /// `CredentialsStore.deleteSlotFile` umging) und acht hartkodierte
    /// UserDefaults-Keys, deren Namensschema vom echten abwich: `YaxiService` lässt für
    /// `legacy` das Suffix WEG, die Liste hängte immer `.legacy` an und traf damit ins
    /// Leere. Deshalb werden die Keys jetzt über die Builder von `YaxiService` gebildet.
    ///
    /// **Diese Funktion läuft nur auf ausdrückliche Nutzerentscheidung.** Zwei Aufrufer:
    /// `removeSlot` (hinter dem destruktiven Button des Bestätigungsdialogs) und der
    /// Abbruch des „Konto hinzufügen"-Assistenten, der seine vorläufige Slot-ID
    /// zurücknimmt. Deshalb `.delete` für den Legacy-Slot: der Dialog verspricht „und
    /// alle zugehörigen Daten werden unwiderruflich gelöscht", und das muss auch für das
    /// Konto gelten, mit dem der Nutzer angefangen hat.
    ///
    /// YAXI-Session-Cleanup läuft in einem detached Task (actor-isolated),
    /// die anderen Cleanups sync.
    static func purgePerSlotData(slotId: String) {
        // YAXI session + connectionData (sensitive!) — actor-isolated, fire-and-forget.
        Task { await YaxiService.sessionStore.clearAll(slotId: slotId) }
        // Encrypted credentials file — inkl. Legacy, siehe oben.
        CredentialsStore.deleteSlotFile(slotId: slotId, legacyPolicy: .delete)
        // Slot-Einstellungen (Gehaltstag, Schwellen, Budget …).
        BankSlotSettingsStore.delete(slotId: slotId)
        // UserDefaults pro-slot-suffixed keys — Schreibweise über dieselben Builder,
        // die beim Schreiben verwendet werden.
        let defaults = UserDefaults.standard
        for key in [
            YaxiService.ibanKey(for: slotId),
            YaxiService.connectionIdKey(for: slotId),
            YaxiService.credModelFullKey(for: slotId),
            YaxiService.credModelUserIdKey(for: slotId),
            YaxiService.credModelNoneKey(for: slotId),
            YaxiService.connectionNameKey(for: slotId),
            "simplebanking.cachedBalance.\(slotId)",
            "simplebanking.lastSeenTxSig.\(slotId)",
        ] {
            defaults.removeObject(forKey: key)
        }
    }

    func setActive(index: Int) {
        guard slots.indices.contains(index) else { return }
        activeIndex = index
        activeSlotEpoch &+= 1   // overflow-safe — Snapshots vergleichen mit ==
        UserDefaults.standard.set(activeIndex, forKey: activeIndexKey)
    }

    func updateSlot(_ slot: BankSlot) {
        guard let idx = slots.firstIndex(where: { $0.id == slot.id }) else { return }
        slots[idx] = slot
        save()
    }

    func updateCurrency(_ currency: String, forSlotId id: String) {
        guard let idx = slots.firstIndex(where: { $0.id == id }) else { return }
        guard slots[idx].currency != currency else { return }
        slots[idx].currency = currency
        save()
    }

    func updateNickname(_ nickname: String?, forSlotId id: String) {
        guard let idx = slots.firstIndex(where: { $0.id == id }) else { return }
        slots[idx].nickname = nickname
        save()
    }

    func updateCustomColor(_ hex: String?, forSlotId id: String) {
        guard let idx = slots.firstIndex(where: { $0.id == id }) else { return }
        slots[idx].customColor = hex
        save()
    }

    /// Injects ephemeral demo slots without persisting to UserDefaults.
    func injectDemoSlots(_ demoSlots: [BankSlot]) {
        slots = demoSlots
        activeIndex = 0
    }

    /// Restores slots that were active before demo mode and persists them.
    /// Defensiv: wenn der übergebene Backup leer ist ODER Demo-Slot-IDs
    /// enthält (Indikator für Korruption), reloaden wir lieber sauber aus
    /// UserDefaults statt das Backup blind zu persistieren.
    /// Hintergrund-Bug: `applySlotToViewModel` hatte früher in Demo-Mode
    /// einen Auto-Heal-`updateSlot()`-Call ausgelöst → Demo-Slots landeten
    /// in UserDefaults und überschrieben echte Banken.
    func restoreDemoSlots(_ previousSlots: [BankSlot], activeIndex previousIndex: Int) {
        let looksCorrupt = previousSlots.contains { $0.id.hasPrefix("demo-slot-") }
        if previousSlots.isEmpty || looksCorrupt {
            reloadFromDisk()
            return
        }
        slots = previousSlots
        activeIndex = previousSlots.indices.contains(previousIndex) ? previousIndex : 0
        save()
    }

    /// Liest die persistierten Slots frisch aus UserDefaults ein. Verwendung:
    /// als Reset-Pfad nach Demo-Modus, wenn das in-memory Backup nicht mehr
    /// vertrauenswürdig ist. `injectDemoSlots` schreibt nicht, daher ist
    /// UserDefaults im Demo-Modus weiterhin die Source-of-Truth für echte Slots.
    func reloadFromDisk() {
        load()
    }

    func moveSlot(from source: IndexSet, to destination: Int) {
        slots.move(fromOffsets: source, toOffset: destination)
        if !slots.indices.contains(activeIndex) { activeIndex = 0 }
        save()
    }

    /// Setzt den Slot des Erstkontos nach dem Einrichtungs-Assistenten.
    ///
    /// Früher hieß das schlicht `slots[0] = slot`, mit der stillschweigenden Annahme,
    /// an Index 0 stünde ein Platzhalter oder das Erstkonto. Die Annahme bricht,
    /// sobald jemand VOR der Bankeinrichtung einen eBon-Slot anlegt: Wer erst REWE
    /// und dann Amazon verbindet, hat `[REWE, Amazon]` — und die anschließende
    /// Bankeinrichtung hat REWE spurlos überschrieben. Ohne Hinweis, ohne Log, und
    /// mit verwaisten Bons in der Datenbank, weil dieser Pfad (anders als
    /// `removeSlot`) nichts aufräumt.
    ///
    /// Deshalb wird jetzt gezielt der Legacy-Slot ersetzt — der Assistent legt sein
    /// Erstkonto immer unter `id == "legacy"` an. Gibt es ihn noch nicht, wird der
    /// neue Slot VORNE eingefügt statt irgendetwas zu überschreiben.
    func replaceFirstSlot(with slot: BankSlot) {
        let result = Self.applyingFirstSlot(slot, to: slots)
        slots = result.slots
        activeIndex = result.activeIndex
        save()
    }

    /// Die reine Entscheidung hinter `replaceFirstSlot` — ohne Singleton und ohne
    /// UserDefaults, damit sie prüfbar ist.
    nonisolated static func applyingFirstSlot(
        _ slot: BankSlot,
        to existing: [BankSlot]
    ) -> (slots: [BankSlot], activeIndex: Int) {
        if let idx = existing.firstIndex(where: { $0.id == slot.id }) {
            var updated = existing
            updated[idx] = slot
            return (updated, idx)
        }
        return ([slot] + existing, 0)
    }

    // MARK: - Persistence

    #if DEBUG
    /// Nur für Tests: setzt die Liste direkt und schreibt sie durch. Der Store ist ein
    /// Singleton, deshalb sichern die Tests den Ausgangszustand und stellen ihn wieder her.
    func replaceAllSlotsForTesting(_ neue: [BankSlot]) {
        slots = neue
        activeIndex = 0
        save()
    }

    /// Nur für Tests: lädt aus den UserDefaults nach — deckt auf, wenn etwas den Weg
    /// zurück auf die Platte gefunden hat, das gelöscht sein sollte.
    func reloadFromDiskForTesting() {
        slots = []
        load()
    }
    #endif

    private func load() {
        let d = Self.defaults
        if let data = d.data(forKey: slotsKey),
           let decoded = try? JSONDecoder().decode([BankSlot].self, from: data) {
            slots = decoded
        }
        activeIndex = d.integer(forKey: activeIndexKey)
        if !slots.indices.contains(activeIndex) { activeIndex = 0 }
    }

    private func save() {
        let d = Self.defaults
        if let data = try? JSONEncoder().encode(slots) {
            d.set(data, forKey: slotsKey)
        }
        d.set(activeIndex, forKey: activeIndexKey)
    }

    // MARK: - Legacy migration

    /// If slots are empty but a legacy IBAN exists, import it as slot[0].
    private func migrateFromLegacyIfNeeded() {
        guard slots.isEmpty else { return }
        guard let iban = UserDefaults.standard.string(forKey: "simplebanking.iban"),
              !iban.isEmpty else { return }
        // Use the legacy ID so existing per-slot keys derived from this ID map correctly.
        let legacySlot = BankSlot(id: "legacy", iban: iban, displayName: "", logoId: nil)
        slots = [legacySlot]
        activeIndex = 0
        save()
    }

    /// One-time corruption fix: if the legacy slot shares a displayName with a newer slot,
    /// the legacy slot was corrupted by a race condition during second-account setup.
    /// Clear only the legacy slot's name so IBAN lookup re-derives the correct bank name.
    /// Non-legacy slots keep their user-chosen names unchanged.
    private func fixDuplicateDisplayNames() {
        guard slots.count > 1 else { return }
        guard let legacyIdx = slots.firstIndex(where: { $0.id == "legacy" }) else { return }
        let legacyName = slots[legacyIdx].displayName
        guard !legacyName.isEmpty else { return }
        let otherHasSameName = slots.indices.contains(where: { $0 != legacyIdx && slots[$0].displayName == legacyName })
        guard otherHasSameName else { return }
        // Legacy slot's name is duplicated — it got the second bank's name by mistake. Clear it.
        slots[legacyIdx] = BankSlot(id: "legacy", iban: slots[legacyIdx].iban, displayName: "", logoId: nil)
        save()
    }
}
