import Foundation

/// Fixkosten und Abos für die Kommandozeile.
///
/// Gelesen, nicht gerechnet — aus derselben Datei wie die MCP-Werkzeuge. Der Grund steht
/// ausführlich in `MCPSchnappschuss` im App-Ziel: `FixedCostsAnalyzer` und
/// `SubscriptionDetector` hängen an SwiftUI und lassen sich hierher nicht mitnehmen, und
/// eine zweite Auswertung derselben Zahl läuft garantiert auseinander.
enum Auswertung {

    struct Konto {
        let slotId: String
        let bankName: String
        let aktualisiert: String
        let gehaltstag: Int?
        let zyklusStart: String?
        let zyklusEnde: String?
        let monatlich: Double
        let offen: Double
        let posten: [[String: Any]]
        let abos: [[String: Any]]
    }

    enum Fehler: Error, CustomStringConvertible {
        case keinStand
        case keinKonto(String)

        var description: String {
            switch self {
            case .keinStand:
                return "Noch keine Auswertung vorhanden. Starte simplebanking einmal — gerechnet wird in der App, nicht hier."
            case .keinKonto(let id):
                return "Kein Konto mit der ID \(id). `sb accounts` zeigt die gültigen IDs."
            }
        }
    }

    static var dateiURL: URL {
        let basis = FileManager.default.urls(for: .applicationSupportDirectory,
                                             in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return basis.appendingPathComponent("simplebanking", isDirectory: true)
            .appendingPathComponent("auswertung.json")
    }

    static func lade(slot: String?) throws -> [Konto] {
        guard let daten = try? Data(contentsOf: dateiURL),
              let wurzel = try? JSONSerialization.jsonObject(with: daten) as? [String: Any],
              let slots = wurzel["slots"] as? [String: Any], !slots.isEmpty else {
            throw Fehler.keinStand
        }
        var konten: [Konto] = []
        for (slotId, roh) in slots.sorted(by: { $0.key < $1.key }) {
            if let slot, !slot.isEmpty, slot != slotId { continue }
            guard let k = roh as? [String: Any] else { continue }
            konten.append(Konto(
                slotId: slotId,
                bankName: k["bank_name"] as? String ?? slotId,
                aktualisiert: k["updated_at"] as? String ?? "",
                gehaltstag: (k["salary_day"] as? NSNumber)?.intValue,
                zyklusStart: k["cycle_start"] as? String,
                zyklusEnde: k["cycle_end"] as? String,
                monatlich: (k["monthly_total_eur"] as? NSNumber)?.doubleValue ?? 0,
                offen: (k["open_total_eur"] as? NSNumber)?.doubleValue ?? 0,
                posten: k["fixed_costs"] as? [[String: Any]] ?? [],
                abos: k["subscriptions"] as? [[String: Any]] ?? []))
        }
        if konten.isEmpty, let slot { throw Fehler.keinKonto(slot) }
        return konten
    }

    /// „vor 3 Minuten" statt eines ISO-Zeitstempels. Wer auf der Kommandozeile steht,
    /// will wissen, ob die Zahl von eben ist — nicht, wann genau sie entstand.
    static func alter(_ iso: String) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        guard let d = f.date(from: iso) else { return "unbekannt" }
        let s = Int(Date().timeIntervalSince(d))
        if s < 120 { return "gerade eben" }
        if s < 3600 { return "vor \(s / 60) Min." }
        if s < 86_400 { return "vor \(s / 3600) Std." }
        return "vor \(s / 86_400) Tagen"
    }

    private static func betrag(_ e: [String: Any]) -> Double {
        (e["amount_eur"] as? NSNumber)?.doubleValue ?? 0
    }

    // MARK: - Ausgabe

    static func zeigeFixkosten(slot: String?, nurOffene: Bool, json: Bool) throws {
        let konten = try lade(slot: slot)
        if json {
            druckeJSON(rohdaten(konten, feld: "fixed_costs", filter: { e in
                !nurOffene || (e["open_this_cycle"] as? Bool ?? false)
            }))
            return
        }
        for k in konten {
            var posten = k.posten.sorted { betrag($0) > betrag($1) }
            if nurOffene { posten = posten.filter { $0["open_this_cycle"] as? Bool ?? false } }
            print(ANSIColor.bold(k.bankName) + ANSIColor.dim("  ·  Stand \(alter(k.aktualisiert))"))
            if let a = k.zyklusStart, let b = k.zyklusEnde {
                print(ANSIColor.dim("Zyklus \(a) – \(b)"))
            }
            print("Monatlich:  \(Format.padRightANSI(Format.colorMoney(-k.monatlich), to: 14))")
            print("Noch offen: \(Format.padRightANSI(Format.colorMoney(-k.offen), to: 14))")
            if posten.isEmpty {
                print(ANSIColor.dim(nurOffene ? "  (nichts mehr offen)" : "  (keine Fixkosten erkannt)"))
            } else {
                print("")
                for p in posten {
                    let offen = p["open_this_cycle"] as? Bool ?? false
                    let marke = nurOffene ? "  " : (offen ? ANSIColor.yellow("● ") : "  ")
                    let faellig = p["next_due"] as? String ?? "—"
                    print("  \(marke)\(Format.pad(p["merchant"] as? String ?? "?", to: 30))"
                          + "\(Format.padRightANSI(Format.colorMoney(-betrag(p)), to: 12))"
                          + ANSIColor.dim("   fällig \(faellig)"))
                }
            }
            if k.slotId != konten.last?.slotId { print("") }
        }
    }

    static func zeigeAbos(slot: String?, reiter: String?, json: Bool) throws {
        let konten = try lade(slot: slot)
        let gesucht = reiter?.lowercased()
        if json {
            druckeJSON(rohdaten(konten, feld: "subscriptions", filter: { e in
                gesucht == nil || (e["tab"] as? String)?.lowercased() == gesucht
            }))
            return
        }
        for k in konten {
            var abos = k.abos.sorted { betrag($0) > betrag($1) }
            if let gesucht { abos = abos.filter { ($0["tab"] as? String)?.lowercased() == gesucht } }
            print(ANSIColor.bold(k.bankName) + ANSIColor.dim("  ·  Stand \(alter(k.aktualisiert))"))
            if abos.isEmpty {
                print(ANSIColor.dim("  (nichts erkannt)"))
            } else {
                for a in abos {
                    // Das Kündigungs-Zeichen ist der Grund, warum man die Liste
                    // überhaupt aufruft — deshalb steht es am Zeilenende, wo das Auge
                    // beim Überfliegen hängenbleibt.
                    let link = a["cancellation_url"] != nil ? ANSIColor.dim("  ↗ kündbar") : ""
                    print("  \(Format.pad(a["name"] as? String ?? "?", to: 28))"
                          + "\(Format.padRightANSI(Format.colorMoney(-betrag(a)), to: 12))"
                          + ANSIColor.dim("   \(Format.pad(a["tab"] as? String ?? "", to: 18))"
                                          + "nächste \(a["next_due"] as? String ?? "—")")
                          + link)
                }
            }
            if k.slotId != konten.last?.slotId { print("") }
        }
    }

    /// `Format.json` verlangt `Encodable`; hier liegen Wörterbücher vor, die genau so
    /// weitergereicht werden sollen.
    /// `JSONSerialization` liest 35.40 als `Double` zurück und schreibt daraus
    /// 35.399999999999999. Die Datei selbst ist sauber — erst dieser Umweg verdirbt sie,
    /// also wird beim Hinausschreiben wieder auf zwei Stellen gebracht. Ganzzahlen
    /// (Monate, Vorkommen, Gehaltstag) bleiben unberührt.
    private static func entrauscht(_ o: Any) -> Any {
        if let d = o as? [String: Any] { return d.mapValues(entrauscht) }
        if let a = o as? [Any] { return a.map(entrauscht) }
        if let n = o as? NSNumber, CFNumberIsFloatType(n) {
            return NSDecimalNumber(string: String(format: "%.2f", n.doubleValue))
        }
        return o
    }

    private static func druckeJSON(_ obj: Any) {
        guard let d = try? JSONSerialization.data(withJSONObject: ["accounts": entrauscht(obj)],
                                                  options: [.prettyPrinted, .sortedKeys]),
              let s = String(data: d, encoding: .utf8) else { print("{}"); return }
        print(s)
    }

    /// JSON geht als Rohdurchreichung raus, nicht durch ein Swift-Modell: Was die App
    /// schreibt, soll hier unverändert ankommen. Ein Modell dazwischen wäre eine dritte
    /// Stelle, die bei jedem neuen Feld mitgepflegt werden müsste.
    private static func rohdaten(_ konten: [Konto], feld: String,
                                 filter: ([String: Any]) -> Bool) -> Any {
        konten.map { k -> [String: Any] in
            var block: [String: Any] = [
                "account_id": k.slotId,
                "bank_name": k.bankName,
                "updated_at": k.aktualisiert,
                feld: (feld == "fixed_costs" ? k.posten : k.abos).filter(filter)
            ]
            if feld == "fixed_costs" {
                block["salary_day"] = k.gehaltstag ?? NSNull()
                block["cycle_start"] = k.zyklusStart ?? NSNull()
                block["cycle_end"] = k.zyklusEnde ?? NSNull()
                block["monthly_total_eur"] = k.monatlich
                block["open_total_eur"] = k.offen
            }
            return block
        }
    }
}
