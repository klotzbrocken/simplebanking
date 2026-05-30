import XCTest
import AppKit
@testable import simplebanking

// MARK: - BankTintProvider.resolveHex (Pure Resolver) Tests
//
// Exercises die pure Resolver-Funktion mit allen Parameter-Kombinationen.
// Keine Abhängigkeit zu MultibankingStore.shared oder UserDefaults — alle Inputs
// werden explizit übergeben (Pattern wie BalanceAdjustment.computeAdjustedBalance).

final class BankTintResolverTests: XCTestCase {

    // Sparkasse — verlässlicher LogoId mit bekannter Primärfarbe.
    private let sparkasse = BankSlot(
        id: "test-sparkasse", iban: "DE00000000000000000001",
        displayName: "Test-Sparkasse", logoId: "sparkasse"
    )
    private let unknownBank = BankSlot(
        id: "test-unknown", iban: "DE00000000000000000002",
        displayName: "Test-Unknown", logoId: "no-such-bank-id-12345"
    )
    private let customSlot = BankSlot(
        id: "test-custom", iban: "DE00000000000000000003",
        displayName: "Test-Custom", logoId: nil, customColor: "AABBCC"
    )

    // MARK: Priorität: Aufrunden-Mode gewinnt immer

    func test_roundupViewActive_returnsNil_regardlessOfState() {
        let result = BankTintProvider.resolveHex(
            roundupViewActive: true,
            globalEnabled: true,
            unifiedActive: false,
            activeSlot: sparkasse,
            slotOverrideEnabled: true
        )
        XCTAssertNil(result, "Aufrunden-Modus hat Vorrang — Bank-Tint muss verstummen (Mint übernimmt).")
    }

    // MARK: Global-Toggle

    func test_globalDisabled_returnsNil() {
        let result = BankTintProvider.resolveHex(
            roundupViewActive: false,
            globalEnabled: false,
            unifiedActive: false,
            activeSlot: sparkasse,
            slotOverrideEnabled: true
        )
        XCTAssertNil(result)
    }

    func test_globalEnabledDefaultBranch_returnsTint() {
        let result = BankTintProvider.resolveHex(
            roundupViewActive: false,
            globalEnabled: true,
            unifiedActive: false,
            activeSlot: sparkasse,
            slotOverrideEnabled: true
        )
        XCTAssertNotNil(result, "Bekannter Slot + alle Toggles ON ergeben Tint-Hex.")
    }

    // MARK: Unified-Mode

    func test_unifiedActive_returnsNil() {
        let result = BankTintProvider.resolveHex(
            roundupViewActive: false,
            globalEnabled: true,
            unifiedActive: true,
            activeSlot: sparkasse,
            slotOverrideEnabled: true
        )
        XCTAssertNil(result, "Im Aggregiert-Mode ist keine einzelne Bank dominant.")
    }

    // MARK: Slot-Override

    func test_slotOverrideOff_returnsNil() {
        let result = BankTintProvider.resolveHex(
            roundupViewActive: false,
            globalEnabled: true,
            unifiedActive: false,
            activeSlot: sparkasse,
            slotOverrideEnabled: false
        )
        XCTAssertNil(result)
    }

    // MARK: No-Slot + Unknown Bank

    func test_noActiveSlot_returnsNil() {
        let result = BankTintProvider.resolveHex(
            roundupViewActive: false,
            globalEnabled: true,
            unifiedActive: false,
            activeSlot: nil,
            slotOverrideEnabled: true
        )
        XCTAssertNil(result)
    }

    func test_unknownBankNoCustom_returnsNil() {
        let result = BankTintProvider.resolveHex(
            roundupViewActive: false,
            globalEnabled: true,
            unifiedActive: false,
            activeSlot: unknownBank,
            slotOverrideEnabled: true
        )
        XCTAssertNil(result, "Slot ohne bekannten LogoId und ohne customColor → kein Tint.")
    }

    // MARK: customColor hat Vorrang vor logoId

    func test_customColorTakesPrecedence() {
        XCTAssertEqual(BankTintProvider.hex(for: customSlot), "AABBCC")
    }

    func test_customColorWinsOverLogo() {
        let s = BankSlot(id: "x", iban: "DE0", displayName: "X",
                         logoId: "sparkasse", customColor: "112233")
        XCTAssertEqual(BankTintProvider.hex(for: s), "112233")
    }

    // MARK: Default-ON Convention

    func test_globalEnabled_defaultsTrue_whenNoEntry() {
        let key = BankTintProvider.globalKey
        UserDefaults.standard.removeObject(forKey: key)
        XCTAssertTrue(BankTintProvider.globalEnabled(), "Kein Eintrag = ON (Default).")
    }

    func test_globalEnabled_falseWhenExplicitlyDisabled() {
        let key = BankTintProvider.globalKey
        UserDefaults.standard.set(false, forKey: key)
        defer { UserDefaults.standard.removeObject(forKey: key) }
        XCTAssertFalse(BankTintProvider.globalEnabled())
    }

    func test_slotEnabled_defaultsTrue_whenNoEntry() {
        let slotId = "test-slot-\(UUID().uuidString)"
        UserDefaults.standard.removeObject(forKey: BankTintProvider.perSlotKey(slotId))
        XCTAssertTrue(BankTintProvider.slotEnabled(slotId: slotId))
    }

    func test_slotEnabled_falseWhenExplicitlyDisabled() {
        let slotId = "test-slot-\(UUID().uuidString)"
        let key = BankTintProvider.perSlotKey(slotId)
        UserDefaults.standard.set(false, forKey: key)
        defer { UserDefaults.standard.removeObject(forKey: key) }
        XCTAssertFalse(BankTintProvider.slotEnabled(slotId: slotId))
    }

    // MARK: Color-Math

    func test_softNSColor_resolvesNonNil_forValidHex() {
        let c = BankTintProvider.softNSColor(fromHex: "FF6200")  // ING Orange
        XCTAssertNotNil(c)
    }

    func test_softNSColor_lightAndDarkProduceDifferentRGB() {
        // Bei gleicher Bankfarbe muss Dark-Tint andere RGB liefern als Light-Tint
        // (unterschiedlicher Mix gegen #F9F9F9 vs #171717).
        let lightAppearance = NSAppearance(named: .aqua)!
        let darkAppearance = NSAppearance(named: .darkAqua)!
        let dyn = BankTintProvider.softNSColor(fromHex: "FF0000")  // Sparkasse Rot

        var lightRGB: (CGFloat, CGFloat, CGFloat) = (0, 0, 0)
        var darkRGB: (CGFloat, CGFloat, CGFloat) = (0, 0, 0)

        lightAppearance.performAsCurrentDrawingAppearance {
            let resolved = dyn.usingColorSpace(.sRGB) ?? dyn
            lightRGB = (resolved.redComponent, resolved.greenComponent, resolved.blueComponent)
        }
        darkAppearance.performAsCurrentDrawingAppearance {
            let resolved = dyn.usingColorSpace(.sRGB) ?? dyn
            darkRGB = (resolved.redComponent, resolved.greenComponent, resolved.blueComponent)
        }

        XCTAssertNotEqual(lightRGB.0, darkRGB.0)
        XCTAssertNotEqual(lightRGB.1, darkRGB.1)
        // Light-Variante sollte hellere R-Komponente haben (Mix gegen helles BG).
        XCTAssertGreaterThan(lightRGB.0, darkRGB.0)
    }
}
