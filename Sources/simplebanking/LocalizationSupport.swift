import Foundation

enum AppLanguage: String, CaseIterable {
    case system
    case de
    case en

    static let storageKey = "appLanguage"
    static let didChangeNotification = Notification.Name("AppLanguageChanged")

    var pickerLabel: String {
        switch self {
        case .system:
            return L10n.t("System", "System")
        case .de:
            return "Deutsch"
        case .en:
            return "English"
        }
    }

    static func selected() -> AppLanguage {
        let raw = UserDefaults.standard.string(forKey: storageKey) ?? AppLanguage.system.rawValue
        return AppLanguage(rawValue: raw) ?? .system
    }

    static func resolved() -> AppLanguage {
        let choice = selected()
        guard choice == .system else { return choice }

        let preferred = Locale.preferredLanguages.first?.lowercased() ?? ""
        return preferred.hasPrefix("de") ? .de : .en
    }
}

enum L10n {
    static func t(_ de: String, _ en: String) -> String {
        AppLanguage.resolved() == .de ? de : en
    }
}
