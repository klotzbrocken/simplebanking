import XCTest
@testable import simplebanking

final class MerchantWordBoundaryTests: XCTestCase {

    func test_rejectsBrandNeedleInsideLongerWord() {
        // Der eigentliche Bug: „otto" darf NICHT in „Lotto24" matchen.
        XCTAssertFalse(MerchantLogoService.wordContains("1051063192335/pp.4679.pp/. lotto24 ag, ihr einkauf bei lotto24 ag", "otto"))
        XCTAssertFalse(MerchantLogoService.wordContains("lotto24 ag", "otto"))
        XCTAssertFalse(MerchantLogoService.wordContains("ottomane wohnen", "otto"))
        // Kundenfall: Miete an „… Immobilien …" darf NICHT als OBI matchen.
        XCTAssertFalse(MerchantLogoService.wordContains("müller immobilien gmbh miete", "obi"))
        XCTAssertFalse(MerchantLogoService.wordContains("hausverwaltung immobilien", "obi"))
        XCTAssertTrue(MerchantLogoService.wordContains("obi markt köln", "obi"))   // echtes OBI weiterhin
    }

    func test_matchesBrandNeedleAtWordBoundaries() {
        XCTAssertTrue(MerchantLogoService.wordContains("otto versand gmbh", "otto"))
        XCTAssertTrue(MerchantLogoService.wordContains("zahlung an otto", "otto"))
        XCTAssertTrue(MerchantLogoService.wordContains("amazon.de", "amazon"))
        XCTAssertTrue(MerchantLogoService.wordContains("paypal *steam", "paypal"))
        XCTAssertTrue(MerchantLogoService.wordContains("otto24", "otto"))   // Ziffer = Grenze
    }

    func test_emptyAndMissing() {
        XCTAssertFalse(MerchantLogoService.wordContains("otto", ""))
        XCTAssertFalse(MerchantLogoService.wordContains("rewe markt", "otto"))
    }
}
