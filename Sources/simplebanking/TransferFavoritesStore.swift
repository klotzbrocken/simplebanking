import Foundation

// MARK: - TransferFavoritesStore
//
// User-Defaults-basierte Persistenz für Empfänger-Favoriten im Geld-senden-
// Dialog. Schlüssel = "<slotId>|<normalisierte IBAN>". Pro Slot getrennt,
// damit Favoriten nicht zwischen Bank-Konten leaken.

enum TransferFavoritesStore {
    private static let storageKey = "simplebanking.transfer.favorites"

    static func compositeKey(slotId: String, iban: String) -> String {
        let normalized = TransferRequest.normalizeIban(iban)
        return "\(slotId)|\(normalized)"
    }

    static func load() -> Set<String> {
        guard let raw = UserDefaults.standard.array(forKey: storageKey) as? [String] else {
            return []
        }
        return Set(raw)
    }

    static func isFavorite(slotId: String, iban: String) -> Bool {
        load().contains(compositeKey(slotId: slotId, iban: iban))
    }

    @discardableResult
    static func toggle(slotId: String, iban: String) -> Bool {
        var current = load()
        let key = compositeKey(slotId: slotId, iban: iban)
        let nowFavorite: Bool
        if current.contains(key) {
            current.remove(key)
            nowFavorite = false
        } else {
            current.insert(key)
            nowFavorite = true
        }
        UserDefaults.standard.set(Array(current), forKey: storageKey)
        return nowFavorite
    }
}
