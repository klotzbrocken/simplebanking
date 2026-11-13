import SwiftUI
import AppKit
import MoneyMoneyForm

// MARK: - Verlauf aus MoneyMoney übernehmen, nachträglich
//
// Der Weg für ein schon eingerichtetes simplebanking (2.2.1). Bis 2.2.0 gab es den
// Umstieg nur auf der Willkommensseite der Ersteinrichtung; wer simplebanking bereits
// benutzte, hätte alles löschen und neu anlegen müssen.
//
// **Ein Blatt für alle Konten, nicht eines je Konto.** Eine MoneyMoney-Datenbank trägt
// den Verlauf aller Konten, und sie wird mit *einem* Kennwort geöffnet. Hinge der
// Einstieg an der Kontozeile (wie `ImportSheet` für CAMT und OFX), müsste der Nutzer
// sein MoneyMoney-Kennwort je Konto erneut tippen.
//
// Das Kennwort wird zum Entschlüsseln gebraucht und **nirgends gespeichert**. Es steht
// genau so lange im Speicher, wie der Helfer läuft; danach wird das Feld geleert.

@MainActor
struct MoneyMoneyBestandSheet: View {

    let onClose: () -> Void

    /// Die Abschnitte des Blattes. Ein `enum` und keine Sammlung von Bool-Flaggen:
    /// Zwei davon gleichzeitig wahr wäre ein Zustand, den es nicht geben darf.
    private enum Abschnitt {
        case kennwort
        case auswahl
        case laeuft
        case fertig
    }

    @State private var abschnitt: Abschnitt = .kennwort

    /// Selbst gewählte Datei; `nil` heißt „der übliche Ort". Gemeldet am 11.11.2026
    /// für den Assistenten: Wer eine Kopie aus einer Sicherung liegen hat, mit zwei
    /// Dateien arbeitet oder eine Fassung benutzt, die woanders ablegt, kam sonst
    /// nicht weiter.
    @State private var datenbank: URL? = nil
    @State private var kennwort: String = ""
    @State private var fehler: String? = nil

    @State private var auszug: MoneyMoneyAuszug? = nil
    @State private var treffer: [MoneyMoneyBestandstreffer] = []
    @State private var absagen: [MoneyMoneyAbsage] = []
    /// Angehakte Konten, über `accounts.rowid`.
    @State private var gewaehlt: Set<Int64> = []
    /// Konten, die es hier noch nicht gibt — angehakt heißt „einrichten".
    @State private var einzurichten: Set<Int64> = []
    @State private var berichte: [MoneyMoneyNachtrag.Bericht] = []
    /// MoneyMoney-Konten ohne Slot. Für sie läuft die normale Einrichtung.
    @State private var neue: [MoneyMoneyKonto] = []

    private var datei: URL { datenbank ?? MoneyMoneyLesepfad.ueblicherOrt }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            kopf

            Divider()

            switch abschnitt {
            case .kennwort: kennwortAbschnitt
            case .auswahl:  auswahlAbschnitt
            case .laeuft:   laeuftAbschnitt
            case .fertig:   fertigAbschnitt
            }

            Spacer(minLength: 0)

            fuss
        }
        .padding(20)
        .frame(width: 520, height: 460)
    }

    // MARK: - Kopf und Fuß

    private var kopf: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.down.doc.fill")
                .font(.system(size: 22, weight: .regular))
                .foregroundColor(.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text(t("Verlauf aus MoneyMoney übernehmen", "Import history from MoneyMoney"))
                    .font(.system(size: 16, weight: .semibold))
                Text(t("Für Konten, die in simplebanking schon verbunden sind",
                       "For accounts already connected in simplebanking"))
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            }
            Spacer()
        }
    }

    @ViewBuilder
    private var fuss: some View {
        HStack {
            switch abschnitt {
            case .kennwort:
                Button(t("Abbrechen", "Cancel")) { schliessen() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button(t("Datenbank lesen", "Read database")) { Task { await lesen() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(kennwort.isEmpty)
            case .auswahl:
                Button(t("Abbrechen", "Cancel")) { schliessen() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button(t("Übernehmen", "Import")) { Task { await uebernehmen() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(gewaehlt.isEmpty && einzurichten.isEmpty)
            case .laeuft:
                Spacer()
            case .fertig:
                Spacer()
                Button(t("Schließen", "Close")) { schliessen() }
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    // MARK: - Kennwort

    private var kennwortAbschnitt: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(t("MoneyMoney-Datenbank", "MoneyMoney database"))
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.secondary)
                HStack(spacing: 8) {
                    Text(datei.path)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(vorhanden ? .secondary : .red)
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                    Spacer(minLength: 8)
                    Button(t("Andere wählen …", "Choose another …")) { waehleDatei() }
                        .controlSize(.small)
                }
                if !vorhanden {
                    // **Nicht „fehlt".** `isReadableFile` benutzt `access(2)`, und das
                    // verweigert macOS für den Container einer anderen App ohne zu
                    // fragen. Die alte Fassung behauptete, dort liege keine Datei —
                    // der Nutzer sah sie im Finder und kam nicht weiter (13.11.2026).
                    // Lesen darf man trotzdem: Das echte Öffnen löst die Rückfrage aus.
                    VStack(alignment: .leading, spacing: 4) {
                        // Kein „versuch es trotzdem, macOS fragt schon": Für den
                        // Container einer anderen App fragt macOS **nicht** — es
                        // verweigert still. Bestätigt am 13.11.2026: Der Dialog kam in
                        // keinem Lauf. Also die Anweisung, die wirklich hilft.
                        Text(t("Die Datei fehlt nicht — macOS lässt simplebanking nur nicht in den Ordner von MoneyMoney. Einen Dialog gibt es dafür nicht: Trag simplebanking unten beim Festplattenvollzugriff mit „+“ ein und komm zurück.",
                               "The file is not missing — macOS simply will not let simplebanking into MoneyMoney's folder. There is no prompt for this: add simplebanking under Full Disk Access with “+” below, then come back."))
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Button(t("Festplattenvollzugriff öffnen …", "Open Full Disk Access …")) {
                            // Die moderne Schreibweise springt in die Liste selbst; die
                            // alte (`com.apple.preference.security`) landete nur auf
                            // „Datenschutz & Sicherheit", und man suchte weiter.
                            if let url = URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_AllFiles") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                        .controlSize(.small)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(t("Kennwort der MoneyMoney-Datenbank", "MoneyMoney database password"))
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.secondary)
                SecureField("", text: $kennwort)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { if !kennwort.isEmpty { Task { await lesen() } } }
                Text(t("Wird nur zum Entschlüsseln gebraucht und nicht gespeichert — weder in den Einstellungen noch im Schlüsselbund.",
                       "Used only to decrypt, and never stored — neither in settings nor in the keychain."))
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let fehler {
                hinweis(fehler, farbe: .red, symbol: "exclamationmark.triangle.fill")
            }
        }
    }

    private var vorhanden: Bool {
        FileManager.default.isReadableFile(atPath: datei.path)
    }

    private func waehleDatei() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.message = t("MoneyMoney-Datenbank wählen", "Choose MoneyMoney database")
        // Ohne Typfilter: Die Datei heißt `.sqlite`, aber eine Kopie aus einer
        // Sicherung trägt gelegentlich eine andere Endung, und ein Filter, der die
        // gesuchte Datei ausgraut, ist schlimmer als keiner.
        if panel.runModal() == .OK, let url = panel.url {
            datenbank = url
            fehler = nil
        }
    }

    // MARK: - Lesen

    private func lesen() async {
        let datei = self.datei
        let kennwort = self.kennwort
        fehler = nil
        abschnitt = .laeuft

        // Der Helfer ist ein eigener Prozess und der Auszug einige Megabyte groß —
        // beides gehört vom Hauptfaden weg, sonst steht das Blatt.
        let ergebnis = await Task.detached { () -> Result<MoneyMoneyAuszug, Error> in
            do { return .success(try MoneyMoneyLesepfad.auszug(datenbank: datei, kennwort: kennwort)) }
            catch { return .failure(error) }
        }.value

        // Das Kennwort hat seinen Zweck erfüllt. Es aus dem Feld zu nehmen ist das
        // Einzige, was wir hier über seine Lebensdauer entscheiden können.
        self.kennwort = ""

        switch ergebnis {
        case .failure(let error):
            fehler = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            abschnitt = .kennwort
        case .success(let gelesen):
            let aufgeteilt = MoneyMoneyBestand.aufteilen(gelesen,
                                                         slots: MultibankingStore.shared.slots)
            auszug = gelesen
            treffer = aufgeteilt.treffer
            // Nicht verbunden ist keine Absage mehr, sondern ein Angebot: Die Bank
            // lässt sich einrichten, und der Verlauf kommt danach von selbst nach.
            absagen = aufgeteilt.absagen.filter { $0.grund != .nichtVerbunden }
            neue = aufgeteilt.absagen.filter { $0.grund == .nichtVerbunden }.map(\.konto)
            einzurichten = Set(neue.map(\.schluessel))
            // Alles vorausgewählt: Wer die Übernahme selbst anstößt, will sie in der
            // Regel ganz. Abwählen ist ein Klick, Anwählen von allem sind viele.
            gewaehlt = Set(aufgeteilt.treffer.map(\.konto.schluessel))
            AppLogger.log("MoneyMoney-Bestand: \(aufgeteilt.treffer.count) Konten verbunden, "
                          + "\(aufgeteilt.absagen.count) übergangen",
                          category: "MoneyMoney")
            abschnitt = .auswahl
        }
    }

    // MARK: - Auswahl

    @ViewBuilder
    private var auswahlAbschnitt: some View {
        if treffer.isEmpty && neue.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                hinweis(t("Aus dieser MoneyMoney-Datenbank lässt sich nichts übernehmen.",
                          "Nothing in this MoneyMoney database can be imported."),
                        farbe: .orange, symbol: "info.circle.fill")
                absagenListe
            }
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if !treffer.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(t("Schon verbunden — nur der Verlauf",
                                   "Already connected — history only"))
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(.secondary)
                            ForEach(treffer, id: \.konto.schluessel) { eintrag in
                                Toggle(isOn: haken(eintrag.konto.schluessel, in: $gewaehlt)) {
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(eintrag.slotName)
                                            .font(.system(size: 13))
                                        Text(herkunftszeile(eintrag.konto, vorsatz: eintrag.konto.name))
                                            .font(.system(size: 11))
                                            .foregroundColor(.secondary)
                                    }
                                }
                            }
                            Text(t("Übernommen wird nur, was älter ist als die älteste Buchung, die das Konto schon hat — die vorhandenen Umsätze bleiben unberührt.",
                                   "Only entries older than the account's oldest existing booking are imported — what is already there stays untouched."))
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    if !neue.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(t("Noch nicht verbunden — Konto einrichten",
                                   "Not connected yet — set up the account"))
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(.secondary)
                            ForEach(neue, id: \.schluessel) { konto in
                                Toggle(isOn: haken(konto.schluessel, in: $einzurichten)) {
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text((konto.name ?? "").isEmpty ? konto.iban : konto.name!)
                                            .font(.system(size: 13))
                                        Text(herkunftszeile(konto, vorsatz: nil))
                                            .font(.system(size: 11))
                                            .foregroundColor(.secondary)
                                    }
                                }
                            }
                            Text(t("Dafür öffnet sich der Einrichtungs-Assistent: Bank für Bank, mit der Freigabe, die deine Bank verlangt. Der Verlauf kommt nach dem ersten Abruf von selbst nach. Dein MoneyMoney-Kennwort wird dabei nicht erneut gebraucht.",
                                   "The setup assistant opens for these: bank by bank, with whatever approval your bank requires. The history follows on its own after the first fetch. Your MoneyMoney password is not needed again."))
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    absagenListe
                }
                .padding(.trailing, 4)
            }
        }
    }

    private func haken(_ schluessel: Int64, in menge: Binding<Set<Int64>>) -> Binding<Bool> {
        Binding(get: { menge.wrappedValue.contains(schluessel) },
                set: { an in
                    if an { menge.wrappedValue.insert(schluessel) }
                    else { menge.wrappedValue.remove(schluessel) }
                })
    }

    /// Woher der Verlauf kommt: wie das Konto in MoneyMoney heißt, und ab wann dort
    /// Buchungen liegen. Beides steht im Auszug, kostet also keinen Datenbankzugriff —
    /// und sagt dem Nutzer, was er bekommt, statt ihn eine Zahl raten zu lassen.
    private func herkunftszeile(_ konto: MoneyMoneyKonto, vorsatz: String?) -> String {
        let name = (vorsatz ?? "").trimmingCharacters(in: .whitespaces)
        let inMM = name.isEmpty ? t("in MoneyMoney", "in MoneyMoney")
                                : t("in MoneyMoney: \(name)", "in MoneyMoney: \(name)")
        guard let auszug else { return inMM }
        let tage = auszug.umsaetze
            .filter { $0.kontoSchluessel == konto.schluessel
                      && MoneyMoneyLeseregeln.istUebernehmbar($0) }
            .map { MoneyMoneyLeseregeln.tag(ausEpoche: $0.gebuchtAm) }
        guard let aeltester = tage.min() else {
            return inMM + " · " + t("keine Buchungen", "no bookings")
        }
        return inMM + " · " + t("\(tage.count) Buchungen seit \(aeltester)",
                                "\(tage.count) bookings since \(aeltester)")
    }

    @ViewBuilder
    private var absagenListe: some View {
        if !absagen.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text(t("Übergangen", "Skipped"))
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.secondary)
                ForEach(absagen, id: \.self) { absage in
                    let name = (absage.konto.name ?? "").trimmingCharacters(in: .whitespaces)
                    Text("• " + (name.isEmpty ? absage.konto.iban : name) + " — " + absage.satz)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    // MARK: - Übernehmen

    private var laeuftAbschnitt: some View {
        VStack(alignment: .leading, spacing: 10) {
            ProgressView().controlSize(.small)
            Text(t("Bitte warten …", "Please wait …"))
                .font(.system(size: 12))
                .foregroundColor(.secondary)
        }
    }

    private func uebernehmen() async {
        guard let auszug else { return }
        let gewaehlteTreffer = treffer.filter { gewaehlt.contains($0.konto.schluessel) }
        let gewaehlteNeue = neue.filter { einzurichten.contains($0.schluessel) }
        guard !gewaehlteTreffer.isEmpty || !gewaehlteNeue.isEmpty else { return }
        abschnitt = .laeuft

        // Konten, die es hier noch nicht gibt, gehen an den Einrichtungs-Assistenten:
        // Er kann die Banksuche, die Zugangsdaten und vor allem die Freigabe, die die
        // Bank verlangt. Das in diesem Blatt nachzubauen hieße, den halben Assistenten
        // ein zweites Mal zu haben.
        //
        // Der Auszug geht über die Ablage und nicht über die Mitteilung — er trägt den
        // Umsatzverlauf, und der gehört nicht in ein `userInfo`. Deshalb MUSS er vor
        // dem Verschicken liegen.
        if !gewaehlteNeue.isEmpty {
            MoneyMoneyAblage.legen(auszug)
            // Erst den Verlauf der schon verbundenen Konten fertig machen, dann
            // übergeben: Der Assistent läuft modal, und danach kommt dieses Blatt
            // nicht mehr zum Zug.
            if !gewaehlteTreffer.isEmpty {
                await verlaufUebernehmen(gewaehlteTreffer, auszug: auszug)
            }
            AppLogger.log("MoneyMoney-Bestand: \(gewaehlteNeue.count) Konten an den "
                          + "Einrichtungs-Assistenten übergeben", category: "MoneyMoney")
            NotificationCenter.default.post(
                name: Notification.Name("simplebanking.setupFromMoneyMoney"), object: nil)
            schliessen()
            return
        }

        await verlaufUebernehmen(gewaehlteTreffer, auszug: auszug)
        abschnitt = .fertig
    }

    /// Der Verlauf für Konten, die es hier schon gibt.
    private func verlaufUebernehmen(_ gewaehlteTreffer: [MoneyMoneyBestandstreffer],
                                    auszug: MoneyMoneyAuszug) async {
        // Der Auszug muss auf die Platte, weil der Nachtrag ihn von dort liest — und
        // weil ein Konto ohne Bankbuchungen (Naht fehlt) erst beim nächsten Abruf
        // nachrückt. Er räumt sich selbst weg, sobald kein Eintrag mehr offen ist.
        MoneyMoneyAblage.legen(auszug)

        // `ergaenzen` und nicht `anlegen`: Ein offenes Vorhaben aus der
        // Ersteinrichtung darf nicht verloren gehen.
        //
        // `verbindungsId` trägt hier keine YAXI-Verbindung — es gibt keine, der Slot
        // steht längst. Das Präfix macht das in der gespeicherten Liste sichtbar und
        // kann mit keiner echten Kennung zusammenfallen.
        MoneyMoneyVorhaben.ergaenzen(gewaehlteTreffer.map {
            MoneyMoneyVorhabenEintrag(iban: $0.konto.iban,
                                      verbindungsId: "bestand:" + $0.slotId,
                                      bankname: $0.slotName,
                                      kontoSchluessel: $0.konto.schluessel)
        })

        berichte = await MoneyMoneyNachtrag.alleFaelligen()
    }

    // MARK: - Ergebnis

    private var fertigAbschnitt: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                let uebernommen = berichte.filter { $0.ausgang == .uebernommen }
                let summe = uebernommen.reduce(0) { $0 + $1.buchungen }

                HStack(spacing: 8) {
                    Image(systemName: summe > 0 ? "checkmark.circle.fill" : "info.circle.fill")
                        .foregroundColor(summe > 0 ? .green : .orange)
                    Text(summe > 0
                         ? t("\(summe) Buchungen übernommen", "\(summe) bookings imported")
                         : t("Nichts zu übernehmen", "Nothing to import"))
                        .font(.system(size: 14, weight: .semibold))
                }

                ForEach(Array(berichte.enumerated()), id: \.offset) { _, bericht in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(name(zu: bericht.iban))
                            .font(.system(size: 13))
                        Text(satz(zu: bericht))
                            .font(.system(size: 11))
                            .foregroundColor(farbe(zu: bericht))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                if summe == 0 && berichte.allSatisfy({ $0.ausgang == .uebernommen }) {
                    Text(t("Der Verlauf aus MoneyMoney liegt nicht vor der ältesten Buchung, die diese Konten schon haben — es gab also nichts zu ergänzen.",
                           "The MoneyMoney history does not predate the oldest booking these accounts already have, so there was nothing to add."))
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.trailing, 4)
        }
    }

    private func name(zu iban: String) -> String {
        let gesucht = MoneyMoneyVorhaben.normiert(iban)
        if let gefunden = treffer.first(where: {
            MoneyMoneyVorhaben.normiert($0.konto.iban) == gesucht
        }) { return gefunden.slotName }
        return iban
    }

    private func satz(zu bericht: MoneyMoneyNachtrag.Bericht) -> String {
        switch bericht.ausgang {
        case .uebernommen:
            let buchungen = t("\(bericht.buchungen) Buchungen", "\(bericht.buchungen) bookings")
            guard bericht.kategorien > 0 else { return buchungen }
            return buchungen + ", " + t("\(bericht.kategorien) Kategorien",
                                        "\(bericht.kategorien) categories")
        case .wartetAufAbruf:
            // Kein Fehler, sondern eine Reihenfolge: Ohne eine Buchung der Bank gibt
            // es keine Naht, und ohne Naht käme der ganze Zeitraum herein — auch die
            // Wochen, die die Bank selbst liefert.
            return t("wartet auf den ersten Abruf dieses Kontos — der Verlauf rückt danach von selbst nach",
                     "waiting for this account's first fetch — the history follows on its own afterwards")
        case .gescheitert(let grund):
            return t("nicht übernommen: \(grund)", "not imported: \(grund)")
        }
    }

    private func farbe(zu bericht: MoneyMoneyNachtrag.Bericht) -> Color {
        switch bericht.ausgang {
        case .uebernommen:    return .secondary
        case .wartetAufAbruf: return .orange
        case .gescheitert:    return .red
        }
    }

    // MARK: - Aufräumen

    private func hinweis(_ text: String, farbe: Color, symbol: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: symbol).foregroundColor(farbe)
            Text(text)
                .font(.system(size: 12))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func schliessen() {
        kennwort = ""
        onClose()
    }

    /// Kurzform für `L10n.t`. Delegiert und entscheidet nicht selbst: `ImportSheet`
    /// trägt eine eigene Fassung mit abweichender Sprachermittlung
    /// (`Locale.current.language` statt `Locale.preferredLanguages`) — zwei Regeln für
    /// dieselbe Frage sind genau, wie zwei Blätter in verschiedenen Sprachen entstehen.
    private func t(_ de: String, _ en: String) -> String { L10n.t(de, en) }
}
