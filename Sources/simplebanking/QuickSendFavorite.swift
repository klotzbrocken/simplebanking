import Foundation
import Combine

// MARK: - QuickSendFavorite
//
// Eine vom User gepinnte Schnellüberweisungs-Vorlage für den Quick-Send-Drawer
// im Flyout. Bewusst klein: ein Emoji-Shortcut plus die vier Prefill-Felder.
// Persistenz als JSON-Array in UserDefaults — max. `maxCount` Slots, passend zur
// Vorlagen-Reihe im Drawer.

struct QuickSendFavorite: Codable, Identifiable, Equatable {
    var id: UUID
    var emoji: String
    var name: String
    /// Normalisierte IBAN (ohne Spaces, uppercase) — wie `TransferRequest.normalizeIban`.
    var iban: String
    /// Roh-Eingabe wie im Betrag-Feld ("850,00").
    var amount: String
    var purpose: String

    init(id: UUID = UUID(),
         emoji: String,
         name: String,
         iban: String,
         amount: String,
         purpose: String) {
        self.id = id
        self.emoji = emoji
        self.name = name
        self.iban = iban
        self.amount = amount
        self.purpose = purpose
    }
}

// MARK: - QuickSendFavoritesStore

/// UserDefaults-gestützter Store für die gepinnten Quick-Send-Vorlagen.
/// `@Published items` treibt sowohl die Drawer-Vorlagenreihe als auch den
/// Editor in den Einstellungen.
@MainActor
final class QuickSendFavoritesStore: ObservableObject {
    static let shared = QuickSendFavoritesStore()

    /// Passend zur 4er-Vorlagenreihe im Drawer.
    static let maxCount = 4
    static let defaultsKey = "quickSendFavorites"

    @Published private(set) var items: [QuickSendFavorite]

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.items = Self.load(from: defaults)
    }

    var canAddMore: Bool { items.count < Self.maxCount }

    // MARK: Persistence (pure — testbar mit injizierten Defaults)

    static func load(from defaults: UserDefaults) -> [QuickSendFavorite] {
        guard let data = defaults.data(forKey: defaultsKey),
              let decoded = try? JSONDecoder().decode([QuickSendFavorite].self, from: data)
        else { return [] }
        return Array(decoded.prefix(maxCount))
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(items) {
            defaults.set(data, forKey: Self.defaultsKey)
        }
    }

    // MARK: Mutations

    /// Hängt eine Vorlage an. No-op (gibt `false` zurück) sobald `maxCount` erreicht ist.
    @discardableResult
    func add(_ favorite: QuickSendFavorite) -> Bool {
        guard items.count < Self.maxCount else { return false }
        items.append(favorite)
        persist()
        return true
    }

    func remove(id: UUID) {
        items.removeAll { $0.id == id }
        persist()
    }

    func move(from source: IndexSet, to destination: Int) {
        items.move(fromOffsets: source, toOffset: destination)
        persist()
    }

    func update(_ favorite: QuickSendFavorite) {
        guard let idx = items.firstIndex(where: { $0.id == favorite.id }) else { return }
        items[idx] = favorite
        persist()
    }
}
