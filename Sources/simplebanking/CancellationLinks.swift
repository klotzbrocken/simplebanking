import Foundation

/// Mapping von Merchant-Keywords → Kündigungs-URL (Fokus DE)
/// Verwendet in FixedCostsView als "Kündigen"-Button pro erkanntem Abo.
///
/// Hinweis: URLs können sich ändern. Stand: Februar 2026.
/// Manche Dienste haben keinen Deep-Link direkt zur Kündigung,
/// dann wird die Kontoverwaltung verlinkt.

enum CancellationLinks {

    struct Entry {
        let displayName: String
        let url: URL
        let note: String?  // z.B. "Kündigung nur über Apple/Google möglich"
    }

    /// Sucht passende Kündigungs-URL anhand von Merchant-Name und Verwendungszweck.
    /// Gibt nil zurück wenn kein Match gefunden wird.
    static func find(merchant: String, remittance: String = "") -> Entry? {
        let combined = "\(merchant) \(remittance)".lowercased()
        for (keywords, entry) in registry {
            if keywords.contains(where: { combined.contains($0) }) {
                return entry
            }
        }
        return nil
    }

    // MARK: - Registry
    // Tuple: ([keywords], Entry)

    private static let registry: [([String], Entry)] = [

        // ── Streaming ──────────────────────────────────────────────

        (["netflix"],
         Entry(displayName: "Netflix",
               url: URL(string: "https://www.netflix.com/cancelplan")!,
               note: nil)),

        (["spotify"],
         Entry(displayName: "Spotify",
               url: URL(string: "https://www.spotify.com/de/account/subscription/")!,
               note: nil)),

        (["disney+", "disney plus", "disneyplus"],
         Entry(displayName: "Disney+",
               url: URL(string: "https://www.disneyplus.com/account")!,
               note: nil)),

        (["amazon prime", "amzn prime", "prime video", "prime membership"],
         Entry(displayName: "Amazon Prime",
               url: URL(string: "https://www.amazon.de/gp/primecentral")!,
               note: nil)),

        (["dazn"],
         Entry(displayName: "DAZN",
               url: URL(string: "https://my.dazn.com/account")!,
               note: nil)),

        (["wow ", "sky ticket", "sky entertainment", "sky sport"],
         Entry(displayName: "WOW / Sky",
               url: URL(string: "https://www.wowtv.de/account")!,
               note: "Bei Sky-Paketen: sky.de/mein-sky")),

        (["youtube premium", "youtube music", "google youtube", "youtube"],
         Entry(displayName: "YouTube Premium",
               url: URL(string: "https://myaccount.google.com/subscriptions")!,
               note: nil)),

        (["joyn"],
         Entry(displayName: "Joyn PLUS+",
               url: URL(string: "https://www.joyn.de/account")!,
               note: nil)),

        (["rtl+", "rtl plus", "tvnow"],
         Entry(displayName: "RTL+",
               url: URL(string: "https://plus.rtl.de/account")!,
               note: nil)),

        // ── Software / Apps ────────────────────────────────────────

        (["openai", "chatgpt"],
         Entry(displayName: "ChatGPT Plus",
               url: URL(string: "https://chatgpt.com/#settings/Subscription")!,
               note: nil)),

        (["apple.com/bill", "icloud", "apple one"],
         Entry(displayName: "Apple (iCloud/One)",
               url: URL(string: "https://support.apple.com/de-de/118428")!,
               note: "Über Einstellungen → Apple-ID → Abonnements")),

        (["google storage", "google one", "google ireland", "google llc", "google payment", "google workspace"],
         Entry(displayName: "Google",
               url: URL(string: "https://myaccount.google.com/subscriptions")!,
               note: nil)),

        (["lovable", "lovable.dev"],
         Entry(displayName: "Lovable",
               url: URL(string: "https://lovable.dev/settings/billing")!,
               note: nil)),

        (["gamma.app", "gamma presentation", "gamma ai"],
         Entry(displayName: "Gamma",
               url: URL(string: "https://gamma.app/settings/billing")!,
               note: nil)),

        (["microsoft 365", "office 365", "microsoft*"],
         Entry(displayName: "Microsoft 365",
               url: URL(string: "https://account.microsoft.com/services/")!,
               note: nil)),

        (["adobe", "creative cloud"],
         Entry(displayName: "Adobe Creative Cloud",
               url: URL(string: "https://account.adobe.com/plans")!,
               note: "Achtung: Jahresabo hat Stornogebühr")),

        // ── Telekommunikation ──────────────────────────────────────

        (["telekom", "t-mobile", "magenta"],
         Entry(displayName: "Telekom",
               url: URL(string: "https://www.telekom.de/hilfe/vertrag-meine-daten/vertrag-verwalten/kuendigung")!,
               note: "Kündigungsbutton im Kundencenter")),

        (["vodafone"],
         Entry(displayName: "Vodafone",
               url: URL(string: "https://www.vodafone.de/meinvodafone/account/kuendigung")!,
               note: nil)),

        (["o2", "telefonica", "blau.de"],
         Entry(displayName: "o2 / Blau",
               url: URL(string: "https://www.o2online.de/service/kuendigung/")!,
               note: nil)),

        // ── Versicherung ───────────────────────────────────────────

        (["huk-coburg", "huk coburg"],
         Entry(displayName: "HUK-COBURG",
               url: URL(string: "https://www.huk.de/service/kuendigen.html")!,
               note: nil)),

        // ── Mitgliedschaft / Fitness ───────────────────────────────

        (["mcfit", "mc fit", "rsg group", "john reed", "gold's gym"],
         Entry(displayName: "McFIT / RSG Group",
               url: URL(string: "https://my.mcfit.com/")!,
               note: "Kündigung über Mitgliederbereich oder per Brief")),

        (["urban sports", "urbansports"],
         Entry(displayName: "Urban Sports Club",
               url: URL(string: "https://urbansportsclub.com/de/profile/membership")!,
               note: nil)),

        // ── Transport ──────────────────────────────────────────────

        (["deutschlandticket", "deutschland-ticket", "49-euro", "49 euro ticket", "d-ticket"],
         Entry(displayName: "Deutschlandticket",
               url: URL(string: "https://deutschlandticket.de/termination/form")!,
               note: "Kündigung bis 10. des Monats zum Monatsende")),

        (["bahncard", "bahn card", "db vertrieb"],
         Entry(displayName: "BahnCard",
               url: URL(string: "https://www.bahn.de/service/individuelle-reise/bahncard/bahncard-kuendigen")!,
               note: "6 Wochen vor Ablauf kündigen")),

        // ── Lieferdienste ──────────────────────────────────────────

        (["hellofresh", "hello fresh"],
         Entry(displayName: "HelloFresh",
               url: URL(string: "https://www.hellofresh.de/my-account/deliveries/menu")!,
               note: "Abo pausieren oder kündigen im Konto")),

        // ── Finanzen ───────────────────────────────────────────────

        (["audible"],
         Entry(displayName: "Audible",
               url: URL(string: "https://www.audible.de/account/overview")!,
               note: nil)),

        // ── KI / Kreativ ───────────────────────────────────────────

        (["dreamina", "capcut", "bytedance"],
         Entry(displayName: "Dreamina / CapCut",
               url: URL(string: "https://dreamina.capcut.com/account/subscription")!,
               note: nil)),

        // ── Newsletter / Plattformen ───────────────────────────────

        (["substack"],
         Entry(displayName: "Substack",
               url: URL(string: "https://substack.com/account/settings")!,
               note: "Bezahlte Abos unter 'Subscriptions' kündigen")),

        // ── Presse / News ──────────────────────────────────────────

        (["spiegel+", "spiegel plus", "der spiegel"],
         Entry(displayName: "SPIEGEL+",
               url: URL(string: "https://gruppenkonto.spiegel.de/konto")!,
               note: nil)),

        // ── Weitere 15 Dienste ─────────────────────────────────────

        // Automobil
        (["adac"],
         Entry(displayName: "ADAC",
               url: URL(string: "https://www.adac.de/mitgliedschaft/kuendigung/formular/")!,
               note: "3 Monate Kündigungsfrist zum Beitragsjahresende")),

        // Streaming / TV
        (["waipu", "exaring"],
         Entry(displayName: "waipu.tv",
               url: URL(string: "https://www.waipu.tv/account")!,
               note: "7 Tage Kündigungsfrist")),

        (["zattoo"],
         Entry(displayName: "Zattoo",
               url: URL(string: "https://zattoo.com/account")!,
               note: nil)),

        (["paramount+", "paramount plus"],
         Entry(displayName: "Paramount+",
               url: URL(string: "https://www.paramountplus.com/account/")!,
               note: nil)),

        // Hörbücher / Lesen
        (["kindle unlimited"],
         Entry(displayName: "Kindle Unlimited",
               url: URL(string: "https://www.amazon.de/kindle-dbs/ku/ku_central")!,
               note: nil)),

        // Software / Security
        (["nordvpn", "nord vpn"],
         Entry(displayName: "NordVPN",
               url: URL(string: "https://my.nordaccount.com/dashboard/nordvpn/")!,
               note: "30-Tage-Geld-zurück-Garantie")),

        // Fitness
        (["clever fit", "cleverfit"],
         Entry(displayName: "clever fit",
               url: URL(string: "https://www.clever-fit.com/kuendigung/")!,
               note: "Meist per Brief oder online im Mitgliederbereich")),

        (["fitness first"],
         Entry(displayName: "Fitness First",
               url: URL(string: "https://www.fitnessfirst.de/member")!,
               note: nil)),

        // Mobilfunk
        (["congstar"],
         Entry(displayName: "congstar",
               url: URL(string: "https://www.congstar.de/hilfe-service/mein-congstar/vertrag-kuendigen/")!,
               note: nil)),

        (["1&1", "1und1", "1 und 1"],
         Entry(displayName: "1&1",
               url: URL(string: "https://www.1und1.de/KuendigungEinleiten")!,
               note: nil)),

        (["freenet", "mobilcom", "klarmobil"],
         Entry(displayName: "freenet / mobilcom",
               url: URL(string: "https://www.freenet.de/kuendigung/")!,
               note: nil)),

        // Lieferdienste / Food
        (["lieferando", "thuisbezorgd", "takeaway"],
         Entry(displayName: "Lieferando",
               url: URL(string: "https://www.lieferando.de/account/details")!,
               note: "Plus-Abo unter Kontoeinstellungen")),

        // Cloud / Backup
        (["dropbox"],
         Entry(displayName: "Dropbox",
               url: URL(string: "https://www.dropbox.com/account/plan")!,
               note: nil)),

        // Dating
        (["parship"],
         Entry(displayName: "Parship",
               url: URL(string: "https://www.parship.de/settings/membership")!,
               note: "Kündigungsbutton-Pflicht seit 07/2022")),

        // Spende / Mitgliedschaft (häufig als Lastschrift)
        (["gez", "rundfunkbeitrag", "beitragsservice"],
         Entry(displayName: "Rundfunkbeitrag",
               url: URL(string: "https://www.rundfunkbeitrag.de/buergerinnen_und_buerger/formulare/abmelden/index_ger.html")!,
               note: "Abmeldung nur bei Wegzug/Tod/Zweitwohnung")),
    ]
}
