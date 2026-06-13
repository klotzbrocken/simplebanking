import XCTest
@testable import simplebanking

// MARK: - QuickSendFormatting Tests
//
// Exercises the pure amount/IBAN helpers behind the flyout Quick-Send drawer.

final class QuickSendFormattingTests: XCTestCase {

    // MARK: Amount sanitizing

    func test_amount_stripsNonNumeric() {
        XCTAssertEqual(QuickSendFormatting.sanitizeAmountInput("1a2b3"), "123")
    }

    func test_amount_multipleSeparators_lastIsDecimal() {
        // Mehrere Trenner: der letzte ist Dezimal, frühere = Tausender → verworfen.
        XCTAssertEqual(QuickSendFormatting.sanitizeAmountInput("1,2,3"), "12,3")
    }

    // MARK: Locale-sichere Trenner (P1-Fix: „12.50" darf NICHT „1250" werden)

    func test_amount_pointAsDecimalSeparator() {
        XCTAssertEqual(QuickSendFormatting.sanitizeAmountInput("12.50"), "12,50")
    }

    func test_amount_commaAsDecimalSeparator() {
        XCTAssertEqual(QuickSendFormatting.sanitizeAmountInput("12,50"), "12,50")
    }

    func test_amount_germanThousandsWithCommaDecimal() {
        XCTAssertEqual(QuickSendFormatting.sanitizeAmountInput("1.234,56"), "1234,56")
    }

    func test_amount_englishThousandsWithPointDecimal() {
        XCTAssertEqual(QuickSendFormatting.sanitizeAmountInput("1,234.56"), "1234,56")
    }

    func test_amount_pointInput_decimalValueIsNotMultiplied() {
        // Kern des P1-Bugs: „12.50" ergibt 12,50 € — nicht 1250 €.
        let sanitized = QuickSendFormatting.sanitizeAmountInput("12.50")
        XCTAssertEqual(QuickSendFormatting.amountDecimal(sanitized), Decimal(string: "12.50"))
    }

    func test_amount_limitsToTwoDecimals() {
        XCTAssertEqual(QuickSendFormatting.sanitizeAmountInput("12,3456"), "12,34")
    }

    func test_amount_keepsAllIntegerDigits_noTruncation() {
        // P2-Fix: große Beträge werden NICHT mehr gekürzt (sonst stille Wertänderung).
        XCTAssertEqual(QuickSendFormatting.sanitizeAmountInput("1234567,89"), "1234567,89")
        XCTAssertEqual(QuickSendFormatting.amountDecimal("1234567,89"), Decimal(string: "1234567.89"))
    }

    func test_amount_overMax_isInvalidatedNotTruncated() {
        // Betrag > maxAmount bleibt erhalten und ist > maxAmount (Drawer sperrt das Senden).
        let parsed = QuickSendFormatting.amountDecimal(QuickSendFormatting.sanitizeAmountInput("123456,78"))
        XCTAssertEqual(parsed, Decimal(string: "123456.78"))
        XCTAssertTrue((parsed ?? 0) > QuickSendFormatting.maxAmount)
    }

    func test_amount_keepsTrailingComma() {
        XCTAssertEqual(QuickSendFormatting.sanitizeAmountInput("85,"), "85,")
    }

    // MARK: Einzel-Trenner-Heuristik (P2-Fix: „1.000" ist 1000 €, nicht 1,00 €)

    func test_amount_singleDotThreeDigits_isThousands() {
        XCTAssertEqual(QuickSendFormatting.sanitizeAmountInput("1.000"), "1000")
        XCTAssertEqual(QuickSendFormatting.amountDecimal(QuickSendFormatting.sanitizeAmountInput("1.000")),
                       Decimal(1000))
    }

    func test_amount_singleCommaThreeDigits_isThousands() {
        XCTAssertEqual(QuickSendFormatting.sanitizeAmountInput("1,000"), "1000")
    }

    func test_amount_repeatedSingleType_isGrouping() {
        XCTAssertEqual(QuickSendFormatting.sanitizeAmountInput("1.000.000"), "1000000") // Gruppierung, ungekürzt
    }

    func test_amount_singleSeparatorTwoDigits_staysDecimal() {
        // Regressionsschutz: 1–2 Nachkommastellen bleiben Dezimal.
        XCTAssertEqual(QuickSendFormatting.sanitizeAmountInput("12.50"), "12,50")
        XCTAssertEqual(QuickSendFormatting.sanitizeAmountInput("1,5"), "1,5")
    }

    // MARK: Amount → Decimal

    func test_amountDecimal_parsesComma() {
        XCTAssertEqual(QuickSendFormatting.amountDecimal("850,00"), Decimal(string: "850.00"))
    }

    func test_amountDecimal_rejectsEmptyAndZero() {
        XCTAssertNil(QuickSendFormatting.amountDecimal(""))
        XCTAssertNil(QuickSendFormatting.amountDecimal("0"))
        XCTAssertNil(QuickSendFormatting.amountDecimal(","))
    }

    func test_amountDecimal_partialComma() {
        XCTAssertEqual(QuickSendFormatting.amountDecimal("15"), Decimal(15))
    }

    // MARK: IBAN

    func test_groupIban_groupsInFours() {
        XCTAssertEqual(
            QuickSendFormatting.groupIban("DE89370400440532013000"),
            "DE89 3704 0044 0532 0130 00"
        )
    }

    func test_groupIban_normalizesSpacingAndCase() {
        XCTAssertEqual(
            QuickSendFormatting.groupIban("de89 3704 0044 0532 0130 00"),
            "DE89 3704 0044 0532 0130 00"
        )
    }

    func test_isValidIban_acceptsValid() {
        XCTAssertTrue(QuickSendFormatting.isValidIban("DE89 3704 0044 0532 0130 00"))
    }

    func test_isValidIban_rejectsBadChecksum() {
        XCTAssertFalse(QuickSendFormatting.isValidIban("DE00 3704 0044 0532 0130 00"))
    }

    func test_maskedIban_showsFirstAndLastFour() {
        XCTAssertEqual(
            QuickSendFormatting.maskedIban("DE89 3704 0044 0532 0130 00"),
            "DE89 … 3000"
        )
    }

    func test_displayEUR_formatsGermanStyle() {
        XCTAssertEqual(QuickSendFormatting.displayEUR(Decimal(string: "850")!), "850,00 €")
    }
}

// MARK: - QuickSendFavoritesStore Tests

@MainActor
final class QuickSendFavoritesStoreTests: XCTestCase {

    private func makeStore() -> (QuickSendFavoritesStore, UserDefaults) {
        let suiteName = "quicksend.test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return (QuickSendFavoritesStore(defaults: defaults), defaults)
    }

    private func sample(_ name: String) -> QuickSendFavorite {
        QuickSendFavorite(emoji: "💸", name: name,
                          iban: "DE89370400440532013000", amount: "10,00", purpose: "x")
    }

    func test_addAppendsAndPersists() {
        let (store, defaults) = makeStore()
        XCTAssertTrue(store.add(sample("A")))
        XCTAssertEqual(store.items.count, 1)
        // Re-load from the same defaults → persisted.
        XCTAssertEqual(QuickSendFavoritesStore.load(from: defaults).count, 1)
    }

    func test_addCapsAtMaxCount() {
        let (store, _) = makeStore()
        for i in 0..<QuickSendFavoritesStore.maxCount {
            XCTAssertTrue(store.add(sample("F\(i)")))
        }
        XCTAssertFalse(store.canAddMore)
        XCTAssertFalse(store.add(sample("overflow")))
        XCTAssertEqual(store.items.count, QuickSendFavoritesStore.maxCount)
    }

    func test_removeById() {
        let (store, _) = makeStore()
        let fav = sample("A")
        store.add(fav)
        store.add(sample("B"))
        store.remove(id: fav.id)
        XCTAssertEqual(store.items.count, 1)
        XCTAssertEqual(store.items.first?.name, "B")
    }

    func test_loadClampsToMaxCount() {
        let suiteName = "quicksend.test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let many = (0..<10).map { sample("F\($0)") }
        defaults.set(try! JSONEncoder().encode(many), forKey: QuickSendFavoritesStore.defaultsKey)
        XCTAssertEqual(QuickSendFavoritesStore.load(from: defaults).count, QuickSendFavoritesStore.maxCount)
    }
}
