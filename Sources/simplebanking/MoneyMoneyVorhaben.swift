import Foundation
import MoneyMoneyForm
import RoutexClient

// MARK: - Die Auswahl

/// Ein MoneyMoney-Konto, dem YAXI eine Bankverbindung zuordnen konnte.
struct MoneyMoneyTreffer: Hashable {
    let konto: MoneyMoneyKonto
    let verbindungsId: String
    let bankname: String
}

/// Ein MoneyMoney-Konto, für das es keinen Weg gibt — mit dem Grund, den der
/// Assistent dem Nutzer hinschreibt. Ohne den sucht er den Fehler bei sich.
struct MoneyMoneyAbsage: Hashable {
    enum Grund: Hashable {
        case keineIban          // Unterkonten und Kreditkarten tragen oft nur eine Kontonummer
        case depot              // portfolio = 1: Depots, Versicherungsverträge
        case nichtErreichbar    // YAXI kennt zu dieser BLZ keine Verbindung
        case nichtGeprueft      // Abfrage fehlgeschlagen, meist kein Netz
    }
    let konto: MoneyMoneyKonto
    let grund: Grund

    var satz: String {
        switch grund {
        case .keineIban:
            return L10n.t("ohne IBAN — in simplebanking nicht abrufbar",
                          "no IBAN — cannot be fetched in simplebanking")
        case .depot:
            return L10n.t("Depot oder Versicherung — kein Konto für Open Banking",
                          "portfolio or insurance — not an Open Banking account")
        case .nichtErreichbar:
            return L10n.t("diese Bank ist über Open Banking nicht erreichbar",
                          "this bank is not reachable via Open Banking")
        case .nichtGeprueft:
            return L10n.t("konnte nicht geprüft werden",
                          "could not be checked")
        }
    }
}

/// Die Aufteilung eines MoneyMoney-Auszugs in „geht" und „geht nicht".
///
/// Rein, damit die Regel mit eingespeisten Werten prüfbar ist: Welche Konten der
/// Assistent anbietet, entscheidet darüber, was ein Umsteiger am Ende sieht — und
/// die Begründung für die übergangenen gehört zur Antwort, nicht ins Logbuch.
enum MoneyMoneyAuswahl {

    /// `erreichbar` ist das Ergebnis der YAXI-Abfrage je IBAN: ein Treffer, `nil` für
    /// „kennt YAXI nicht", und ein fehlender Schlüssel für „nicht geprüft".
    static func aufteilen(
        _ auszug: MoneyMoneyAuszug,
        erreichbar: [String: (verbindungsId: String, bankname: String)?]
    ) -> (treffer: [MoneyMoneyTreffer], absagen: [MoneyMoneyAbsage]) {
        var treffer: [MoneyMoneyTreffer] = []
        var absagen: [MoneyMoneyAbsage] = []
        for konto in auszug.konten {
            guard !konto.istDepot else {
                absagen.append(MoneyMoneyAbsage(konto: konto, grund: .depot))
                continue
            }
            let iban = konto.iban.trimmingCharacters(in: .whitespaces)
            guard MoneyMoneyLeseregeln.istIban(iban) else {
                absagen.append(MoneyMoneyAbsage(konto: konto, grund: .keineIban))
                continue
            }
            guard let gefunden = erreichbar[iban] else {
                absagen.append(MoneyMoneyAbsage(konto: konto, grund: .nichtGeprueft))
                continue
            }
            guard let gefunden else {
                absagen.append(MoneyMoneyAbsage(konto: konto, grund: .nichtErreichbar))
                continue
            }
            treffer.append(MoneyMoneyTreffer(konto: konto,
                                             verbindungsId: gefunden.verbindungsId,
                                             bankname: gefunden.bankname))
        }
        return (treffer, absagen)
    }

    /// Treffer nach Bankverbindung gebündelt, in stabiler Reihenfolge.
    ///
    /// Eine Bank wird **einmal** eingerichtet, auch wenn drei Konten dort liegen —
    /// die Zwei-Faktor-Anmeldung gilt für die Verbindung, nicht für das Konto. Die
    /// Reihenfolge ist die des Auszugs, damit zwei Läufe dieselbe Abfolge haben und
    /// der Nutzer nicht beim zweiten Mal mit einer anderen Bank anfängt.
    static func nachBank(_ treffer: [MoneyMoneyTreffer]) -> [(verbindungsId: String,
                                                              bankname: String,
                                                              konten: [MoneyMoneyKonto])] {
        var folge: [String] = []
        var gebuendelt: [String: (bankname: String, konten: [MoneyMoneyKonto])] = [:]
        for eintrag in treffer {
            if gebuendelt[eintrag.verbindungsId] == nil {
                folge.append(eintrag.verbindungsId)
                gebuendelt[eintrag.verbindungsId] = (eintrag.bankname, [])
            }
            gebuendelt[eintrag.verbindungsId]?.konten.append(eintrag.konto)
        }
        return folge.compactMap { id in
            guard let bündel = gebuendelt[id] else { return nil }
            return (id, bündel.bankname, bündel.konten)
        }
    }
}

// MARK: - Die Abfrage

enum MoneyMoneyEinrichtung {

    /// Liest den Auszug und fragt YAXI zu jeder IBAN, ob die Bank erreichbar ist.
    ///
    /// Eine Abfrage **je Bankleitzahl**, nicht je Konto: Drei Konten bei derselben
    /// Sparkasse sind eine Verbindung und eine Anmeldung. Scheitert eine Abfrage
    /// (meist kein Netz), bleibt der Schlüssel fehlend und das Konto landet unter
    /// „nicht geprüft" — nicht unter „geht nicht", was einem Umsteiger ohne
    /// Verbindung sagen würde, seine Banken seien unerreichbar.
    /// Zeitgrenze je Bankabfrage.
    ///
    /// Ohne sie hängt der Assistent an einem Aufruf, der nicht zurückkommt — mit
    /// drehendem Rad und ohne jede Aussage. Gemeldet am 11.11.2026. Zwanzig Sekunden
    /// sind großzügig für eine Suchabfrage und kurz genug, dass niemand glaubt, das
    /// Programm sei tot. Läuft sie ab, gilt die Bank als **nicht geprüft** — nicht
    /// als unerreichbar.
    static func aufteilung(
        _ auszug: MoneyMoneyAuszug,
        fortschritt: (@Sendable (Int, Int) -> Void)? = nil
    ) async -> (treffer: [MoneyMoneyTreffer],
                absagen: [MoneyMoneyAbsage],
                verbindungen: [String: ConnectionInfo]) {
        var erreichbar: [String: (verbindungsId: String, bankname: String)?] = [:]
        var jeBankleitzahl: [String: (verbindungsId: String, bankname: String)?] = [:]
        var verbindungen: [String: ConnectionInfo] = [:]

        // Wie viele Abfragen es überhaupt werden — für „Bank 2 von 3".
        let zuFragen = Set(auszug.konten.compactMap { konto -> String? in
            let iban = konto.iban.trimmingCharacters(in: .whitespaces)
            guard !konto.istDepot, MoneyMoneyLeseregeln.istIban(iban) else { return nil }
            return bankleitzahl(iban)
        }).count
        var gefragt = 0

        for konto in auszug.konten {
            let iban = konto.iban.trimmingCharacters(in: .whitespaces)
            // Dieselbe Regel wie in `aufteilen` — sonst wird YAXI mit einer nackten
            // Kontonummer gefragt und die Absage lautet hinterher das Falsche.
            guard !konto.istDepot, MoneyMoneyLeseregeln.istIban(iban) else { continue }
            let bereich = bankleitzahl(iban)
            if let schonGefragt = jeBankleitzahl[bereich] {
                erreichbar[iban] = schonGefragt
                continue
            }
            gefragt += 1
            fortschritt?(gefragt, zuFragen)
            AppLogger.log("MoneyMoney-Import: frage YAXI zu Bankbereich \(bereich) "
                               + "(\(gefragt) von \(zuFragen))", category: "MoneyMoney")
            do {
                let gefunden = try await YaxiService.verbindung(fuerIban: iban)
                if let gefunden { verbindungen[gefunden.id.description] = gefunden }
                let antwort = gefunden.map { (verbindungsId: $0.id.description,
                                              bankname: $0.displayName) }
                jeBankleitzahl[bereich] = antwort
                erreichbar[iban] = antwort
                AppLogger.log("MoneyMoney-Import: \(bereich) → "
                                   + (antwort.map { $0.bankname } ?? "keine Verbindung"),
                                   category: "MoneyMoney")
            } catch {
                // Kein Eintrag: „nicht geprüft". Die nächste Bank wird trotzdem
                // gefragt — ein Aussetzer soll nicht den ganzen Import absagen.
                //
                // Dass dieser Schritt in einer frischen Installation stumm ist — die
                // Diagnose ist ab Werk aus — wird NICHT hier umgangen: Der Schalter
                // gehört dem Nutzer. Stattdessen sagt die Oberfläche selbst, bei
                // welcher Bank sie steht, und die Zeitgrenze sorgt dafür, dass es
                // überhaupt weitergeht.
                AppLogger.log("MoneyMoney-Import: IBAN-Abfrage für \(bereich) "
                                   + "fehlgeschlagen (\(error))",
                                   category: "MoneyMoney", level: "WARN")
            }
        }
        let aufgeteilt = MoneyMoneyAuswahl.aufteilen(auszug, erreichbar: erreichbar)
        return (aufgeteilt.treffer, aufgeteilt.absagen, verbindungen)
    }

    /// Bricht ab, wenn die Arbeit nicht rechtzeitig zurückkommt.
    ///
    /// Zwei Aufgaben im Rennen: die Abfrage und eine Uhr. Wer zuerst da ist, gewinnt,
    /// die andere wird abgebrochen. Allein `Task.cancel()` würde nicht reichen — ein
    /// Aufruf, der Abbrüche nicht beachtet, liefe weiter und der Assistent wartete
    /// weiter mit ihm.

    /// Die ersten acht Stellen hinter Land und Prüfsumme — bei DE die Bankleitzahl.
    /// Nur zum Bündeln der Abfragen; wenn das bei einem Land nicht passt, wird
    /// einmal zu viel gefragt, nicht falsch geantwortet.
    static func bankleitzahl(_ iban: String) -> String {
        let blank = iban.replacingOccurrences(of: " ", with: "").uppercased()
        return String(blank.dropFirst(4).prefix(8))
    }
}

// MARK: - Das Vorhaben

/// Was noch zu tun ist, über Assistentenläufe hinweg.
///
/// **Das ist die Warteschlange** — und sie ist absichtlich eine dauerhafte Liste und
/// keine Schleife im Assistenten. Ein Umsteiger mit fünf Banken bricht bei der
/// dritten Zwei-Faktor-Anmeldung ab, legt das Notebook zu und macht am Abend weiter.
/// Als Schleife wäre das ein Sonderfall mit eigenem Zustand; als Liste ist es der
/// Normalbetrieb: Jeder Lauf nimmt den nächsten offenen Eintrag, ein erledigter
/// kommt nicht zurück.
///
/// **Das Kennwort steht hier nicht und kommt hier nie hin.** Es gilt für eine
/// MoneyMoney-Datenbank, in der die Bank-PIN des Nutzers liegt; gespeichert wäre es
/// ein zweiter Schlüssel zu fremdem Geld. Wer später weitermacht, tippt es neu.
struct MoneyMoneyVorhabenEintrag: Codable, Hashable, Sendable {
    var iban: String
    var verbindungsId: String
    var bankname: String
    /// `accounts.rowid` — der Schlüssel, über den die Umsätze dieses Kontos im
    /// Auszug hängen.
    var kontoSchluessel: Int64
    var erledigt: Bool = false
}

enum MoneyMoneyVorhaben {

    nonisolated(unsafe) static let defaults: UserDefaults = {
        let name = "simplebanking.tests.mmvorhaben"
        if NSClassFromString("XCTestCase") != nil, let sandkasten = UserDefaults(suiteName: name) {
            sandkasten.removePersistentDomain(forName: name)
            return sandkasten
        }
        return .standard
    }()

    private static let schluessel = "moneymoneyVorhaben"

    static var eintraege: [MoneyMoneyVorhabenEintrag] {
        get {
            guard let daten = defaults.data(forKey: schluessel),
                  let liste = try? JSONDecoder().decode([MoneyMoneyVorhabenEintrag].self, from: daten)
            else { return [] }
            return liste
        }
        set {
            guard let daten = try? JSONEncoder().encode(newValue) else { return }
            defaults.set(daten, forKey: schluessel)
        }
    }

    static var offene: [MoneyMoneyVorhabenEintrag] { eintraege.filter { !$0.erledigt } }

    /// Welche IBANs der Verlauf betrifft, wenn eine Bank gerade verbunden wurde.
    ///
    /// `gewaehlt` ist die Kontoauswahl des Assistenten — dort darf der Nutzer
    /// abwählen, und solange sie etwas enthält, gilt sie. Sie erscheint aber
    /// **nicht immer**: Nennt die Bank nur ein Konto, fragt der Verbindungsweg gar
    /// nicht. Dann war die Menge leer, und der Nachtrag stieg still aus — Bank
    /// verbunden, Verlauf fehlt, keine Zeile im Protokoll (11.11.2026).
    ///
    /// Der Rückfall nimmt die offenen Einträge **dieser** Bank. Ohne Kennung alle:
    /// Ein Eintrag, der nie abgehakt wird, fragt den Nutzer bei jedem Start erneut.
    static func zuUebernehmen(gewaehlt: Set<String>,
                              bankKennung: String?,
                              offene: [MoneyMoneyVorhabenEintrag]) -> Set<String> {
        guard gewaehlt.isEmpty else { return gewaehlt }
        return Set(offene
            .filter { bankKennung == nil || $0.verbindungsId == bankKennung }
            .map(\.iban))
    }

    /// Die Bank, die dieser Lauf einrichtet — die erste, für die noch etwas offen ist.
    static var naechsteBank: (verbindungsId: String, bankname: String, ibans: [String])? {
        guard let erste = offene.first else { return nil }
        let gleiche = offene.filter { $0.verbindungsId == erste.verbindungsId }
        return (erste.verbindungsId, erste.bankname, gleiche.map(\.iban))
    }

    static func anlegen(_ neue: [MoneyMoneyVorhabenEintrag]) {
        eintraege = neue
        if !neue.isEmpty { defaults.set(true, forKey: umstiegSchluessel) }
    }

    /// Ob dieser Mac einen Umstieg aus MoneyMoney hinter sich hat.
    ///
    /// Dauerhaft und nicht am Vorhaben abgelesen: Das Vorhaben räumt sich selbst
    /// weg, sobald der Verlauf drin ist — die Frage „kam der von MoneyMoney?" stellt
    /// sich aber später noch einmal, etwa beim Umsteiger-Rabatt im letzten Schritt
    /// der Einrichtung. Gesetzt, sobald der Nutzer im Assistenten Konten ausgewählt
    /// hat; ob der Verlauf schon geschrieben ist, spielt dafür keine Rolle, denn der
    /// Rabatt wird ihm **vor** dem ersten Abruf angeboten.
    static var umstiegErfolgt: Bool {
        defaults.bool(forKey: umstiegSchluessel)
    }

    static let umstiegSchluessel = "simplebanking.moneymoneyUmstieg"

    /// Hakt jeden offenen Eintrag ab, dessen IBAN jetzt einen Slot hat.
    ///
    /// Über die IBAN und nicht über die Verbindung: Der Nutzer darf im Kontoauswahl-
    /// Schritt Konten abwählen, die er aus MoneyMoney mitgebracht hat. Ein Eintrag,
    /// den er nicht mehr will, bliebe sonst für immer offen und der Assistent fragte
    /// bei jedem Start erneut danach.
    static func abhaken(ibans: Set<String>) {
        guard !ibans.isEmpty else { return }
        // Nicht `normiert` nennen — das verdeckt die Funktion gleichen Namens.
        let gesucht = Set(ibans.map(normiert))
        eintraege = eintraege.map { eintrag in
            guard !eintrag.erledigt, gesucht.contains(normiert(eintrag.iban)) else { return eintrag }
            var abgehakt = eintrag
            abgehakt.erledigt = true
            return abgehakt
        }
    }

    /// Hakt die ganze Bank ab — für den Fall, dass der Nutzer dort gar kein Konto
    /// ausgewählt hat. Ohne das bliebe die Bank als nächste stehen und der Assistent
    /// liefe im Kreis.
    static func bankAbhaken(verbindungsId: String) {
        eintraege = eintraege.map { eintrag in
            guard !eintrag.erledigt, eintrag.verbindungsId == verbindungsId else { return eintrag }
            var abgehakt = eintrag
            abgehakt.erledigt = true
            return abgehakt
        }
    }

    static func wegwerfen() {
        defaults.removeObject(forKey: schluessel)
    }

    /// Einen Eintrag ganz entfernen — nach dem Nachtrag, wenn er nichts mehr soll.
    static func entfernen(iban: String) {
        let gesucht = normiert(iban)
        eintraege = eintraege.filter { normiert($0.iban) != gesucht }
    }

    /// IBAN-Vergleich ohne Leerzeichen und Groß-/Kleinschreibung: Banken und
    /// MoneyMoney schreiben sie unterschiedlich, und ein Vergleich, der daran
    /// scheitert, lässt den Eintrag offen und fragt ewig weiter.
    static func normiert(_ iban: String) -> String {
        iban.replacingOccurrences(of: " ", with: "").uppercased()
    }
}
