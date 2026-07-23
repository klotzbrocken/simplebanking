import WebKit

/// Verwaltung der lokal gespeicherten Händler-Login-Sitzungen (Cookies/WebKit-Daten).
/// REWE/dm/Amazon nutzen bewusst `WKWebsiteDataStore.default()`, damit der Login für
/// den automatischen Sync erhalten bleibt. „Abmelden" löscht die Domain-Daten eines
/// Händlers aus diesem geteilten Store → der nächste Sync verlangt erneuten Login.
@MainActor
enum MerchantSession {

    /// WebKit-Daten-Domains, die zu einem Händler gehören.
    nonisolated static func domains(for source: SlotSource) -> [String] {
        switch source {
        case .rewe:   return ["rewe.de"]
        case .dm:     return ["dm.de", "dmtech.com"]
        case .amazon: return ["amazon.de"]
        case .yaxi, .paypal: return []   // PayPal nutzt API, keine WebKit-Sitzung
        }
    }

    /// Löscht alle WebKit-Daten (Cookies, Storage) der Händler-Domains.
    static func clear(source: SlotSource, completion: (() -> Void)? = nil) {
        let domains = domains(for: source)
        guard !domains.isEmpty else { completion?(); return }
        let store = WKWebsiteDataStore.default()
        let types = WKWebsiteDataStore.allWebsiteDataTypes()
        store.fetchDataRecords(ofTypes: types) { records in
            let matching = records.filter { rec in
                let name = rec.displayName
                return domains.contains { name == $0 || name.hasSuffix("." + $0) || name.contains($0) }
            }
            guard !matching.isEmpty else { completion?(); return }
            store.removeData(ofTypes: types, for: matching) { completion?() }
        }
    }
}
