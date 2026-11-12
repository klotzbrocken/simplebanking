import Foundation

// MARK: - Eigene Kategorien
//
// Bis 2.1.0 waren die 14 Kategorien fest: nicht umbenennbar, nichts hinzuzufügen.
// *Gemeldet am 10.11.2026 von einem Tester, der von MoneyMoney kommt und dort einen
// eigenen Kategoriebaum pflegt.* Er fand dazu nichts in der Doku — richtig, denn es gab
// nichts zu dokumentieren.
//
// Warum das überhaupt geht, ohne die halbe App umzubauen: Die Kategorie einer Buchung
// ist an jeder Speicherstelle schon eine **Zeichenkette** — die Spalte `kategorie` in
// der Datenbank, der Override in den UserDefaults, `setCategory` in einer
// Zuordnungsregel. Nur der Typ im Programm war ein geschlossenes `enum`. Aus dem ist
// eine Struktur geworden (`TransactionCategory`), deren 14 eingebaute Werte dieselben
// `rawValue`s tragen wie vorher. Darum lesen bestehende Datenbanken, Overrides und
// Regeln unverändert weiter, und CLI und MCP-Server merken von der Änderung nichts:
// Die haben die Kategorie immer nur als Text gesehen.
//
// Zwei Dinge liegen hier:
// - **Eigene Kategorien** (Name + Symbol). Der Name ist die Identität; er steht so in
//   der Datenbank und im Override.
// - **Umbenennungen** der eingebauten. Nur die Anzeige ändert sich, der `rawValue`
//   bleibt — sonst wäre jede schon gespeicherte Zuordnung verloren.
//
// Gelesen wird aus Hintergrundfäden (Suchindex, Kategorisierung), geschrieben nur aus
// den Einstellungen. Darum Sperre und Zwischenspeicher: Ohne ihn liefe pro Zeile und
// pro Neuzeichnen ein JSON-Dekodierer.

struct Eigenkategorie: Codable, Hashable, Identifiable, Sendable {
    var name: String
    var symbol: String
    /// Kennung aus `Kategoriefarbe.palette`; `nil` heißt „die automatische".
    ///
    /// Hier in der Struktur und nicht in einer Tabelle neben den Namen: Bei einer
    /// eigenen Kategorie **ist** der Name die Identität, und beim Umbenennen zieht
    /// die Farbe damit von selbst mit. Optional, damit schon gespeicherte Listen
    /// ohne dieses Feld unverändert weitergelesen werden.
    var farbe: String?

    var id: String { name }

    init(name: String, symbol: String = "tag", farbe: String? = nil) {
        self.name = name
        self.symbol = symbol
        self.farbe = farbe
    }
}

enum Eigenkategorien {

    /// Symbole zur Auswahl. Bewusst kurz gehalten: Eine vollständige SF-Symbols-Liste
    /// ist eine eigene Oberfläche, und die Kategorie braucht ein Erkennungszeichen,
    /// keine Bildauswahl.
    static let symbolvorschlaege = [
        "tag", "pawprint", "figure.2.and.child.holdinghands", "graduationcap",
        "gift", "airplane", "book", "hammer", "leaf", "bolt", "wifi",
        "creditcard", "bag", "heart", "music.note", "gamecontroller",
        "wrench.and.screwdriver", "scissors", "dumbbell", "cup.and.saucer"
    ]

    /// Längste zulässige Bezeichnung. Länger passt in keine Pille, keinen Menüeintrag
    /// und keine Diagrammbeschriftung — und wird dort stillschweigend abgeschnitten.
    static let maximaleLaenge = 24

    /// Im Testlauf eine Wegwerf-Domain statt der echten — dieselbe Begründung und
    /// dieselbe Erkennung wie bei `MultibankingStore.defaults`: Ein Test, der eine
    /// Kategorie anlegt, hätte sonst die Kategorien des Nutzers verändert.
    /// `nonisolated(unsafe)`, weil dieser Laden aus jedem Faden gelesen wird und
    /// `UserDefaults` selbst fadensicher ist — nur der Compiler weiß das nicht.
    nonisolated(unsafe) static let defaults: UserDefaults = {
        let name = "simplebanking.tests.kategorien"
        if NSClassFromString("XCTestCase") != nil, let sandkasten = UserDefaults(suiteName: name) {
            sandkasten.removePersistentDomain(forName: name)
            return sandkasten
        }
        return .standard
    }()

    private static let schluesselEigene = "eigeneKategorien"
    private static let schluesselUmbenennungen = "kategorieUmbenennungen"
    /// Farben der **eingebauten**, nach `rawValue`. Der bleibt beim Umbenennen
    /// gleich — anders als bei einer eigenen Kategorie, deren Farbe deshalb in der
    /// Struktur steht.
    private static let schluesselFarben = "kategorieFarben"

    private static let sperre = NSLock()
    nonisolated(unsafe) private static var gepufferteEigene: [Eigenkategorie]?
    nonisolated(unsafe) private static var gepufferteUmbenennungen: [String: String]?
    nonisolated(unsafe) private static var gepufferteFarben: [String: String]?

    /// Meldung an die Oberfläche, dass sich die Kategorienliste geändert hat. Dieselbe,
    /// die schon beim Ändern einer einzelnen Buchung läuft — die Umsatzliste und die
    /// Auswertungen hören darauf bereits.
    static let aenderungsmeldung = Notification.Name("TransactionCategoriesChanged")

    // MARK: - Lesen

    static var alle: [Eigenkategorie] {
        sperre.lock()
        defer { sperre.unlock() }
        if let gepufferteEigene { return gepufferteEigene }
        let daten = defaults.data(forKey: schluesselEigene)
        let gelesen = daten.flatMap { try? JSONDecoder().decode([Eigenkategorie].self, from: $0) } ?? []
        gepufferteEigene = gelesen
        return gelesen
    }

    static var umbenennungen: [String: String] {
        sperre.lock()
        defer { sperre.unlock() }
        if let gepufferteUmbenennungen { return gepufferteUmbenennungen }
        let gelesen = defaults.dictionary(forKey: schluesselUmbenennungen) as? [String: String] ?? [:]
        gepufferteUmbenennungen = gelesen
        return gelesen
    }

    /// Das Symbol einer eigenen Kategorie, `nil` für alles andere.
    static func symbol(fuer name: String) -> String? {
        alle.first { Kategorienamen.normalisiert($0.name) == Kategorienamen.normalisiert(name) }?.symbol
    }

    static var farben: [String: String] {
        sperre.lock()
        defer { sperre.unlock() }
        if let gepufferteFarben { return gepufferteFarben }
        let gelesen = defaults.dictionary(forKey: schluesselFarben) as? [String: String] ?? [:]
        gepufferteFarben = gelesen
        return gelesen
    }

    /// Die selbst gewählte Farbkennung, `nil` wenn keine gewählt ist.
    ///
    /// Eine Stelle für beide Arten: Bei einer eigenen Kategorie steht sie in der
    /// Struktur, bei einer eingebauten in der Tabelle. Wer danach fragt, soll den
    /// Unterschied nicht kennen müssen.
    static func farbe(fuer kategorie: TransactionCategory) -> String? {
        if kategorie.istEigene {
            return alle.first {
                Kategorienamen.normalisiert($0.name) == Kategorienamen.normalisiert(kategorie.rawValue)
            }?.farbe
        }
        return farben[kategorie.rawValue]
    }

    // MARK: - Schreiben

    /// - Returns: `nil`, wenn angelegt; sonst der Grund, warum nicht.
    @discardableResult
    static func anlegen(name roh: String, symbol: String) -> Kategorienamen.Einwand? {
        guard let name = Kategorienamen.bereinigt(roh) else { return .leer }
        if let einwand = Kategorienamen.pruefe(name, belegt: belegteNamen()) { return einwand }
        var liste = alle
        liste.append(Eigenkategorie(name: name, symbol: symbol))
        speichere(eigene: liste)
        return nil
    }

    static func loeschen(name: String) {
        let ziel = Kategorienamen.normalisiert(name)
        speichere(eigene: alle.filter { Kategorienamen.normalisiert($0.name) != ziel })
    }

    /// Benennt eine **eigene** Kategorie um.
    ///
    /// Bei ihr **ist** der Name die Identität: Er steht als Bezeichnung in der
    /// Datenbank, als Wert im Override und in jeder Regel. Darum ziehen alle drei
    /// Zuordnungen mit um — sonst verlöre ein Umbenennen still jede bestehende
    /// Zuordnung, und zwar ohne Fehlermeldung: Die Buchungen trügen weiter den alten
    /// Namen, den es nicht mehr gibt.
    ///
    /// Beim **Löschen** bleiben die Zuordnungen bewusst liegen. Wer dieselbe Kategorie
    /// neu anlegt, hat sie damit zurück; bis dahin greift die automatische Zuordnung.
    @discardableResult
    static func umbenennen(eigene alt: String, auf roh: String) -> Kategorienamen.Einwand? {
        guard let neu = Kategorienamen.bereinigt(roh) else { return .leer }
        if Kategorienamen.normalisiert(neu) != Kategorienamen.normalisiert(alt),
           let einwand = Kategorienamen.pruefe(neu, belegt: belegteNamen()) { return einwand }
        let ziel = Kategorienamen.normalisiert(alt)
        var liste = alle
        guard let index = liste.firstIndex(where: { Kategorienamen.normalisiert($0.name) == ziel }) else { return nil }
        let alterName = liste[index].name
        liste[index].name = neu
        speichere(eigene: liste)
        zuordnungenUmziehen(von: alterName, nach: neu)
        return nil
    }

    /// Alle drei Speicherstellen, an denen eine **eigene** Kategorie als Name steht.
    private static func zuordnungenUmziehen(von alt: String, nach neu: String) {
        bezeichnungUmziehen(von: alt, nach: neu)
        TransactionCategorizer.overridesUmbenennen(von: alt, nach: neu)
        AssignmentRules.kategorieUmbenennen(von: alt, nach: neu)
    }

    /// Nur die Bezeichnung in der Datenbank.
    ///
    /// Das genügt bei einer **eingebauten** Kategorie: Override und Regel halten dort
    /// den `rawValue`, und der bleibt beim Umbenennen gleich. Die Datenbank hält
    /// dagegen den Anzeigenamen (so schreibt ihn `updateKategorie` und der Backfill) —
    /// ohne diesen Umzug stünde eine umbenannte Kategorie im Monatsbericht, im CLI und
    /// im MCP-Server weiter unter ihrem alten Namen, und zwar **neben** dem neuen:
    /// dieselbe Kategorie zweimal.
    private static func bezeichnungUmziehen(von alt: String, nach neu: String) {
        guard alt != neu else { return }
        do {
            try TransactionsDatabase.kategorieUmbenennen(von: alt, nach: neu)
        } catch {
            AppLogger.log("Kategorie umbenennen: Datenbank nicht erreicht (\(error.localizedDescription))",
                          category: "Kategorien", level: "WARN")
        }
    }

    /// Setzt die Farbe. `nil` stellt die automatische wieder her.
    static func farbeSetzen(_ kategorie: TransactionCategory, farbe: String?) {
        if kategorie.istEigene {
            let ziel = Kategorienamen.normalisiert(kategorie.rawValue)
            var liste = alle
            guard let index = liste.firstIndex(where: {
                Kategorienamen.normalisiert($0.name) == ziel }) else { return }
            liste[index].farbe = farbe
            speichere(eigene: liste)
            return
        }
        var tabelle = farben
        if let farbe { tabelle[kategorie.rawValue] = farbe }
        else { tabelle.removeValue(forKey: kategorie.rawValue) }
        defaults.set(tabelle, forKey: schluesselFarben)
        sperre.lock()
        gepufferteFarben = tabelle
        sperre.unlock()
        meldeAenderung()
    }

    static func symbolSetzen(eigene name: String, symbol: String) {
        let ziel = Kategorienamen.normalisiert(name)
        var liste = alle
        guard let index = liste.firstIndex(where: { Kategorienamen.normalisiert($0.name) == ziel }) else { return }
        liste[index].symbol = symbol
        speichere(eigene: liste)
    }

    /// Benennt eine **eingebaute** Kategorie um. `nil` oder leer stellt den
    /// werkseitigen Namen wieder her.
    @discardableResult
    static func umbenennen(eingebaut rawValue: String, auf roh: String?) -> Kategorienamen.Einwand? {
        var tabelle = umbenennungen
        let eigener = TransactionCategory(rawValue: rawValue)
        let alterName = eigener.displayName
        guard let neu = roh.flatMap(Kategorienamen.bereinigt) else {
            tabelle.removeValue(forKey: rawValue)
            speichere(umbenennungen: tabelle)
            bezeichnungUmziehen(von: alterName, nach: eigener.werkseitigerName)
            return nil
        }
        let andere = belegteNamen().filter { belegt in
            Kategorienamen.normalisiert(belegt) != Kategorienamen.normalisiert(eigener.displayName)
                && Kategorienamen.normalisiert(belegt) != Kategorienamen.normalisiert(rawValue)
                && Kategorienamen.normalisiert(belegt) != Kategorienamen.normalisiert(eigener.werkseitigerName)
        }
        if let einwand = Kategorienamen.pruefe(neu, belegt: andere) { return einwand }
        tabelle[rawValue] = neu
        speichere(umbenennungen: tabelle)
        bezeichnungUmziehen(von: alterName, nach: neu)
        return nil
    }

    /// Alles, was schon einen Namen hat — eingebaute (werkseitig **und** umbenannt)
    /// und eigene. Zwei Kategorien mit demselben Namen wären nicht
    /// auseinanderzuhalten, und `from(displayName:)` müsste raten.
    static func belegteNamen() -> [String] {
        var namen: [String] = []
        for kategorie in TransactionCategory.eingebaute {
            namen.append(kategorie.rawValue)
            namen.append(kategorie.werkseitigerName)
            namen.append(kategorie.displayName)
        }
        namen.append(contentsOf: alle.map(\.name))
        return namen
    }

    private static func speichere(eigene liste: [Eigenkategorie]) {
        if let daten = try? JSONEncoder().encode(liste) {
            defaults.set(daten, forKey: schluesselEigene)
        }
        sperre.lock()
        gepufferteEigene = liste
        sperre.unlock()
        meldeAenderung()
    }

    private static func speichere(umbenennungen tabelle: [String: String]) {
        defaults.set(tabelle, forKey: schluesselUmbenennungen)
        sperre.lock()
        gepufferteUmbenennungen = tabelle
        sperre.unlock()
        meldeAenderung()
    }

    private static func meldeAenderung() {
        NotificationCenter.default.post(name: aenderungsmeldung, object: nil)
    }

    /// Nur für Tests: Zwischenspeicher wegwerfen, damit ein geänderter
    /// UserDefaults-Stand wieder gelesen wird.
    static func pufferWegwerfen() {
        sperre.lock()
        gepufferteEigene = nil
        gepufferteUmbenennungen = nil
        gepufferteFarben = nil
        sperre.unlock()
    }
}

// MARK: - Namensregeln

/// Die Regeln für einen Kategorienamen — rein, damit sie prüfbar sind.
enum Kategorienamen {

    enum Einwand: Equatable {
        case leer
        case zuLang
        case belegt

        var text: String {
            switch self {
            case .leer:   return L10n.t("Bitte einen Namen eingeben.", "Please enter a name.")
            case .zuLang: return L10n.t("Höchstens \(Eigenkategorien.maximaleLaenge) Zeichen.",
                                        "At most \(Eigenkategorien.maximaleLaenge) characters.")
            case .belegt: return L10n.t("Diesen Namen gibt es schon.", "That name already exists.")
            }
        }
    }

    /// Trimmt und verwirft Leeres. Mehrfache Leerzeichen werden eingezogen — „Haus
    /// Garten" und „Haus  Garten" wären zwei Kategorien, die niemand unterscheiden kann.
    static func bereinigt(_ roh: String) -> String? {
        let zusammengezogen = roh.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return zusammengezogen.isEmpty ? nil : zusammengezogen
    }

    /// - Returns: `nil`, wenn der Name zulässig ist.
    static func pruefe(_ name: String, belegt: [String]) -> Einwand? {
        guard let sauber = bereinigt(name) else { return .leer }
        guard sauber.count <= Eigenkategorien.maximaleLaenge else { return .zuLang }
        let ziel = normalisiert(sauber)
        return belegt.contains { normalisiert($0) == ziel } ? .belegt : nil
    }

    /// Vergleichsform: ohne Groß-/Kleinschreibung, ohne Diakritika.
    ///
    /// **Ohne Diakritika** heißt auch: „Mobilitaet" und „Mobilität" fallen *nicht*
    /// zusammen (aus „ä" wird „a", nicht „ae"). Genau deshalb trägt jede eingebaute
    /// Kategorie ihren werkseitigen Anzeigenamen mit — sonst fände `from(displayName:)`
    /// eine gespeicherte „Mobilität" nach einer Umbenennung nicht mehr.
    static func normalisiert(_ text: String) -> String {
        text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "de_DE"))
            .lowercased()
    }
}
