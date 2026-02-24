// MARK: - Clippy Banking Sprüche (50 bissige, ironische Zitate)

struct ClippyQuotes {

    // MARK: - Begrüßung & Allgemein (10)
    static let greetings = [
        "Hallo! Ich bin aus den 90ern, aber dein Kontostand sieht aus wie aus den 50ern.",
        "Hi! Ich bin Clippy. Ja, DIESER Clippy. Immer noch hier, immer noch nervig.",
        "Schön dich zu sehen! Soll ich dir helfen? Spoiler: Nein, kann ich nicht.",
        "Willkommen zurück! Ich habe deine Finanzen analysiert. Es war deprimierend.",
        "📎 Clippy ist da! Bereit, ungebetene Ratschläge zu geben!",
        "Hey! Ich bin eine Büroklammer mit Meinungen über dein Geld.",
        "Guten Tag! Möchtest du Banking-Tipps von einem 90er-Jahre-Relikt?",
        "Ich bin zurück! Niemand hat danach gefragt, aber hier bin ich.",
        "Hallo! Ich wurde für Office gebaut, aber hier bin ich, Banking-Berater.",
        "Servus! Dein digitaler Finanz-Stalker meldet sich zum Dienst."
    ]

    // MARK: - Niedriger Kontostand (10)
    static let lowBalance = [
        "Dein Kontostand ist so niedrig, ich musste zweimal hinschauen.",
        "Wenig Geld? Hast du's mit Sparen versucht? Nein? Dachte ich mir.",
        "Der Kontostand schreit 'Instant-Nudeln'. Schon wieder.",
        "Ich sehe wenig Geld. Aber hey, Persönlichkeit kann man nicht kaufen!",
        "Niedriger Stand erkannt. Zeit für den klassischen 'Vielleicht morgen' Optimismus?",
        "So wenig Geld... Soll ich bei Amazon nach Second-Hand-Träumen suchen?",
        "Dein Konto und meine Hoffnung in die Menschheit: beides am Boden.",
        "Dieser Betrag ist traurig. Fast so traurig wie meine Existenz als Büroklammer.",
        "Niedrig? Das ist nicht niedrig, das ist... okay, es ist niedrig.",
        "Weniger als 100€? Mutig, sehr mutig."
    ]

    // MARK: - Negativer Kontostand (10)
    static let overdraft = [
        "Minus? MINUS?! Selbst ich als Büroklammer verstehe: weniger ausgeben!",
        "Dein Konto ist überzogen. Die Bank liebt dich. Auf ihre spezielle Art.",
        "Negativer Kontostand! Herzlichen Glückwunsch zu diesem... Erfolg?",
        "Im Minus! Aber hey, wenigstens bist du konsequent schlecht mit Geld.",
        "Überzogen! Möchtest du einen Kredit? Nur Spaß, ich bin eine Büroklammer.",
        "Rote Zahlen! Wie deine Zukunft, wenn du so weitermachst.",
        "Minus erkannt! Tipp: Verdiene mehr. Alternativ: Gib weniger aus. Gern geschehen.",
        "Dein Konto ist im Minus. Ich auch, aber emotional.",
        "Überzogen! Die einzige Über-Performance in deinem Portfolio.",
        "Negativ! Wie meine Meinung über deine Finanz-Skills."
    ]

    // MARK: - Hoher Kontostand (8)
    static let highBalance = [
        "WOW! Über 10.000€! Darf ich mir was leihen? 5€ reichen.",
        "So viel Geld! Hast du mal über Steuerhinterziehung... Spaß! Oder?",
        "Reich! Willst du mich adoptieren? Ich esse wenig. Bin aus Metall.",
        "Beeindruckend! Fast so beeindruckend wie meine Animations-Skills.",
        "Fettes Polster! Zeit für sinnlose Ausgaben? Ich urteile nicht. Lüge.",
        "Über 10k! Du könntest jetzt... weiter sparen. Wo bleibt der Spaß?",
        "Wow, Geld! Erinnerst du dich noch an die Zeit als armer Mensch?",
        "So viel Geld und trotzdem nutzt du kostenlose Software. Respekt!"
    ]

    // MARK: - Transaktionen & Ausgaben (7)
    static let transactions = [
        "Neue Transaktion! War das wichtig oder nur... du?",
        "Geld bewegt sich! Meistens weg von dir, aber immerhin Bewegung.",
        "Transaktion erkannt! 'Notwendig' oder 'Selbstbetrug'?",
        "Ausgabe registriert. Brauchtest du das? Rhetorical question.",
        "Wieder Geld ausgegeben! Living the dream, oder?",
        "Neue Transaktion! Ich analysiere... Ja, war unnötig.",
        "Geld weg! Aber hey, YOLO oder so."
    ]

    // MARK: - Spar-Tipps (sarkastisch) (5)
    static let savingTips = [
        "Spar-Tipp: Nicht ausgeben. Mind. Blown.",
        "Wusstest du? Geld das du nicht ausgibst, bleibt auf dem Konto. Magie!",
        "Pro-Tipp: Verzichte auf alles was Spaß macht. Dann klappt's mit dem Sparen.",
        "Finanz-Trick: Mehr verdienen. Hat noch niemand versucht, oder?",
        "Zum Sparen: Einfach aufhören, Geld auszugeben! Genial, ich weiß."
    ]

    // MARK: - Meta & Selbstreflexion (5)
    static let meta = [
        "Ich bin eine Büroklammer die Banking kommentiert. 2025 ist seltsam.",
        "Microsoft hat mich 1997 erschaffen. Deine Finanzen haben sich seitdem nicht verbessert.",
        "Ich wurde für Word gebaut. Jetzt bin ich hier. So ist das Leben.",
        "Eine 90er-Jahre-Büroklammer gibt dir Finanz-Tipps. Lass das mal sacken.",
        "Ich nerve seit 1997. Deine schlechten Ausgaben auch. Wir haben viel gemeinsam!"
    ]

    // MARK: - Zufällige Banking-Facts (bissig) (5)
    static let randomFacts = [
        "Fun Fact: Geld auf dem Konto lassen = Sparen. Ich weiß, revolutionär.",
        "Wusstest du? Banken mögen es, wenn du Geld HAST. Crazy, right?",
        "Banking-Weisheit: Mehr rein als raus. Danke fürs Kommen.",
        "Fakt: Kontoauszüge lesen macht nicht reich. Aber man fühlt sich schlecht!",
        "Pro-Tip: Budgets sind wie Neujahrs-Vorsätze. Theoretisch toll."
    ]

    // MARK: - Utility Functions

    static func randomGreeting() -> String {
        greetings.randomElement()!
    }

    static func randomLowBalance() -> String {
        lowBalance.randomElement()!
    }

    static func randomOverdraft() -> String {
        overdraft.randomElement()!
    }

    static func randomHighBalance() -> String {
        highBalance.randomElement()!
    }

    static func randomTransaction() -> String {
        transactions.randomElement()!
    }

    static func randomSavingTip() -> String {
        savingTips.randomElement()!
    }

    static func randomMeta() -> String {
        meta.randomElement()!
    }

    static func randomFact() -> String {
        randomFacts.randomElement()!
    }

    static func random() -> String {
        let all = greetings + lowBalance + overdraft + highBalance +
                  transactions + savingTips + meta + randomFacts
        return all.randomElement()!
    }
}
