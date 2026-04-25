import ArgumentParser
import Foundation

@main
struct SimplebankingCLI: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "sb",
        abstract: "Read-only CLI für simplebanking. Liest den lokalen Cache, ohne die Menüleisten-App zu brauchen.",
        version: "1.4.0",
        subcommands: [
            BalanceCommand.self,
            AccountsCommand.self,
            TxCommand.self,
            SummaryCommand.self,
            TodayCommand.self,
            WeekCommand.self,
            MonthCommand.self,
            RefreshCommand.self
        ],
        defaultSubcommand: BalanceCommand.self
    )

    @Option(name: .long, help: "Farbiger Output: auto | always | never (Default: auto).")
    var color: String = "auto"

    mutating func validate() throws {
        ANSIColor.configure(ColorMode(rawValue: color) ?? .auto)
    }
}

// MARK: - Shortcuts

struct TodayCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "today",
        abstract: "Heutige Transaktionen (= sb tx --days 1)."
    )
    @Flag(name: .long) var json = false
    func run() throws {
        try Shortcuts.renderTransactions(days: 1, slot: nil, category: nil, limit: nil, json: json)
    }
}

struct WeekCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "week",
        abstract: "Transaktionen der letzten 7 Tage."
    )
    @Flag(name: .long) var json = false
    func run() throws {
        try Shortcuts.renderTransactions(days: 7, slot: nil, category: nil, limit: nil, json: json)
    }
}

struct MonthCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "month",
        abstract: "Summary des aktuellen Monats."
    )
    @Flag(name: .long) var json = false
    func run() throws {
        try Shortcuts.renderSummary(month: nil, slot: nil, json: json)
    }
}

// MARK: - balance

struct BalanceCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "balance",
        abstract: "Zeigt den zuletzt gecachten Kontostand pro Konto."
    )

    @Option(name: .shortAndLong, help: "Slot-ID (z.B. 'legacy'). Ohne: alle Konten.")
    var slot: String?

    @Flag(name: .long, help: "JSON-Output statt Text.")
    var json = false

    func run() throws {
        let slots = DataReader.loadSlots()
        guard !slots.isEmpty else {
            print("Keine Konten gefunden. Ist simplebanking eingerichtet?")
            throw ExitCode(2)
        }

        let filtered = slot.map { s in slots.filter { $0.id == s } } ?? slots
        guard !filtered.isEmpty else {
            print("Kein Slot mit ID '\(slot ?? "")' gefunden.")
            throw ExitCode(3)
        }

        struct BalanceOut: Encodable {
            let slotId: String
            let name: String
            let iban: String
            let balance: Double?
            let currency: String
        }
        let items = filtered.map { s in
            BalanceOut(
                slotId: s.id,
                name: s.nickname ?? s.displayName,
                iban: s.iban,
                balance: DataReader.cachedBalance(slotId: s.id),
                currency: s.currency ?? "EUR"
            )
        }

        if json {
            print(Format.json(items))
            return
        }

        for it in items {
            let bal: String
            if let b = it.balance {
                bal = Format.colorMoney(b, currency: it.currency)
            } else {
                bal = ANSIColor.dim("— (kein Cache)")
            }
            let ibanShort = ANSIColor.dim("•••\(String(it.iban.suffix(4)))")
            let slot = ANSIColor.dim(String(it.slotId.prefix(8)))
            print("\(Format.pad(it.name, to: 28))\(slot)  \(ibanShort)  \(Format.padRightANSI(bal, to: 14))")
        }
    }
}

// MARK: - accounts

struct AccountsCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "accounts",
        abstract: "Listet alle eingerichteten Konten (Slots)."
    )

    @Flag(name: .long, help: "JSON-Output statt Text.")
    var json = false

    func run() throws {
        let slots = DataReader.loadSlots()
        if json {
            struct AccountOut: Encodable {
                let id: String
                let name: String
                let iban: String
                let nickname: String?
                let currency: String
            }
            let items = slots.map { s in
                AccountOut(id: s.id, name: s.displayName, iban: s.iban,
                           nickname: s.nickname, currency: s.currency ?? "EUR")
            }
            print(Format.json(items))
            return
        }

        if slots.isEmpty {
            print("Keine Konten eingerichtet.")
            return
        }
        print("ID                                    BANK                            IBAN")
        print(String(repeating: "─", count: 80))
        for s in slots {
            let name = s.nickname ?? s.displayName
            print("\(Format.pad(s.id, to: 38))\(Format.pad(name, to: 32))\(s.iban)")
        }
    }
}

// MARK: - tx

struct TxCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "tx",
        abstract: "Zeigt Transaktionen aus dem lokalen Cache."
    )

    @Option(name: .shortAndLong, help: "Zeitfenster in Tagen (Default: 30).")
    var days: Int = 30

    @Option(name: .shortAndLong, help: "Slot-ID zum Filtern.")
    var slot: String?

    @Option(name: .shortAndLong, help: "Kategorie-Filter (exakter Match auf 'kategorie'-Spalte).")
    var category: String?

    @Option(name: .long, help: "Maximal N Zeilen.")
    var limit: Int?

    @Flag(name: .long, help: "JSON-Output statt Text.")
    var json = false

    func run() throws {
        try Shortcuts.renderTransactions(
            days: days, slot: slot, category: category, limit: limit, json: json
        )
    }
}

// MARK: - summary

struct SummaryCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "summary",
        abstract: "Ausgaben-Summary pro Kategorie für einen Monat."
    )

    @Option(name: .shortAndLong, help: "Monat im Format YYYY-MM (Default: aktueller Monat).")
    var month: String?

    @Option(name: .shortAndLong, help: "Slot-ID zum Filtern.")
    var slot: String?

    @Flag(name: .long, help: "JSON-Output statt Text.")
    var json = false

    func run() throws {
        try Shortcuts.renderSummary(month: month, slot: slot, json: json)
    }
}
