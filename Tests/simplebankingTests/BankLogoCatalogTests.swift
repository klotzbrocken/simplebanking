import XCTest
@testable import simplebanking

// MARK: - BankLogoCatalog / BankLogoCache Tests
//
// Validiert die Catalog-Migration 2026-05-22: YAXI bundled `catalog.json` ist
// die Single-Source-of-Truth für Bank-Logos + Brand-Colors. Frühere Quelle
// (Resources/bank-logos/*.svg + GeneratedBankColors.swift) ist entfernt.

final class BankLogoCatalogTests: XCTestCase {

    // MARK: - Catalog-Loader

    func test_catalog_loads_known_german_brands() {
        // Sanity: die 29 von uns kuratierten Brands müssen alle im YAXI-Catalog
        // sein, sonst bricht der Logo-Renderer.
        let ids = ["sparkasse", "volk", "deutsche", "commerz", "post",
                   "unicredit", "ing", "dkb", "comdirect", "noris",
                   "consors", "1822direkt", "n26", "c24", "vivid",
                   "tomorrow", "targo", "santander"]
        for id in ids {
            XCTAssertNotNil(BankLogoCatalog.svg(forLogoId: id),
                            "Bank '\(id)' fehlt im YAXI-Catalog")
        }
    }

    func test_catalog_primaryColor_includes_hash_prefix() {
        // YAXI liefert Colors mit '#'-Prefix
        let dkb = BankLogoCatalog.primaryColor(forLogoId: "dkb")
        XCTAssertNotNil(dkb)
        XCTAssertTrue(dkb?.hasPrefix("#") ?? false,
                      "YAXI-Catalog liefert Hex-Farben mit #-Prefix")
    }

    func test_catalog_unknown_logoId_returns_nil() {
        XCTAssertNil(BankLogoCatalog.svg(forLogoId: "this-bank-definitely-does-not-exist"))
        XCTAssertNil(BankLogoCatalog.primaryColor(forLogoId: "nonsense-id-xyz"))
    }

    func test_catalog_has_default_svg() {
        // _default ist der Fallback für unbekannte logoIds
        XCTAssertNotNil(BankLogoCatalog.defaultSVG,
                        "_default.svg muss im Catalog existieren als Fallback")
    }

    func test_availableLogoIds_excludes_underscore_prefixed() {
        let ids = BankLogoCatalog.availableLogoIds
        XCTAssertFalse(ids.contains("_default"),
                       "_default ist Fallback, nicht 'verfügbare Bank'")
        XCTAssertTrue(ids.count >= 100, "Catalog sollte 100+ Banken liefern, fand \(ids.count)")
    }

    func test_mask_variant_present_for_known_brands() {
        // Bekannte Banken mit Mask-Variante (laut YAXI manifest)
        let withMask = ["comdirect", "bnp", "eih", "bib"]
        for id in withMask where BankLogoCatalog.svg(forLogoId: id) != nil {
            XCTAssertNotNil(BankLogoCatalog.mask(forLogoId: id),
                            "Bank '\(id)' sollte eine Mask-Variante haben")
        }
    }

    // MARK: - BankLogoAssets.primaryColor — strippt #-Prefix

    func test_bankLogoAssets_primaryColor_strips_hash() {
        // Wrapper-API entfernt '#'-Prefix, damit nachgelagerter Color(hex:)-
        // Code beide Formate verträgt.
        guard let dkb = BankLogoAssets.primaryColor(forLogoId: "dkb") else {
            return XCTFail("DKB primaryColor sollte verfügbar sein")
        }
        XCTAssertFalse(dkb.hasPrefix("#"))
        XCTAssertEqual(dkb.count, 6, "Hex ohne # = 6 Zeichen")
    }

    // MARK: - isHexColorDark (pure)

    func test_isHexColorDark_black_isDark() {
        XCTAssertTrue(BankLogoAssets.isHexColorDark("#000000"))
        XCTAssertTrue(BankLogoAssets.isHexColorDark("000000"))
        XCTAssertTrue(BankLogoAssets.isHexColorDark("#000"))    // 3-stelliger Shortcut
    }

    func test_isHexColorDark_white_isLight() {
        XCTAssertFalse(BankLogoAssets.isHexColorDark("#FFFFFF"))
        XCTAssertFalse(BankLogoAssets.isHexColorDark("FFFFFF"))
    }

    func test_isHexColorDark_deutscheBlue_isDark() {
        // Deutsche Bank #1e2a78 — knapp aber dunkel laut Rec.709-Luminanz
        XCTAssertTrue(BankLogoAssets.isHexColorDark("#1e2a78"))
    }

    func test_isHexColorDark_ingOrange_isLight() {
        // ING #FF6200 — gesättigtes Orange, klar nicht dunkel
        XCTAssertFalse(BankLogoAssets.isHexColorDark("#FF6200"))
    }

    func test_isHexColorDark_accepts_rgba() {
        // 8-stelliges Hex (RGBA) — Alpha wird für Luminanz ignoriert
        XCTAssertTrue(BankLogoAssets.isHexColorDark("#000000FF"))
        XCTAssertFalse(BankLogoAssets.isHexColorDark("#FFFFFFFF"))
    }

    func test_isHexColorDark_invalid_returnsFalse() {
        XCTAssertFalse(BankLogoAssets.isHexColorDark(""))
        XCTAssertFalse(BankLogoAssets.isHexColorDark("#XYZ"))
        XCTAssertFalse(BankLogoAssets.isHexColorDark("12345"))  // ungültige Länge
    }
}

// MARK: - BankLogoCache Tests

final class BankLogoCacheTests: XCTestCase {

    override func setUp() {
        super.setUp()
        #if DEBUG
        BankLogoCache._testReset()
        #endif
    }

    func test_url_forKnownLogoId_returnsExtractedFile() throws {
        guard let url = BankLogoCache.url(forLogoId: "dkb") else {
            return XCTFail("DKB sollte extrahierbar sein")
        }
        XCTAssertTrue(url.isFileURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        // Inhalt prüfen: muss ein SVG sein
        let content = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(content.hasPrefix("<svg"), "Extracted file muss SVG sein")
    }

    func test_url_forUnknownLogoId_falls_back_to_default() throws {
        guard let url = BankLogoCache.url(forLogoId: "this-id-does-not-exist-xyz") else {
            return XCTFail("Default-Fallback sollte greifen")
        }
        XCTAssertEqual(url.lastPathComponent, "_default.svg")
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    func test_url_lazyCaching_secondCallReusesFile() throws {
        guard let url1 = BankLogoCache.url(forLogoId: "ing") else { return XCTFail() }
        let mtime1 = try FileManager.default.attributesOfItem(atPath: url1.path)[.modificationDate] as? Date
        // Kurz warten + nochmal abrufen
        Thread.sleep(forTimeInterval: 0.05)
        guard let url2 = BankLogoCache.url(forLogoId: "ing") else { return XCTFail() }
        let mtime2 = try FileManager.default.attributesOfItem(atPath: url2.path)[.modificationDate] as? Date
        XCTAssertEqual(url1, url2)
        XCTAssertEqual(mtime1, mtime2, "File darf bei zweitem Zugriff nicht neu geschrieben werden (cached)")
    }

    func test_url_forMaskVariant_writesSeparateFile() throws {
        guard let regular = BankLogoCache.url(forLogoId: "comdirect", mask: false),
              let masked  = BankLogoCache.url(forLogoId: "comdirect", mask: true) else {
            return XCTFail("comdirect sollte regular + mask haben")
        }
        XCTAssertNotEqual(regular, masked, "Regular und Mask-File müssen unterschiedliche Pfade haben")
        XCTAssertTrue(masked.lastPathComponent.contains("-mask"))
    }

    func test_hasMask_truForBranchesWithMaskInCatalog() {
        XCTAssertTrue(BankLogoCache.hasMask(forLogoId: "comdirect"))
    }

    func test_hasMask_falseForUnknown() {
        XCTAssertFalse(BankLogoCache.hasMask(forLogoId: "nonsense-bank"))
    }
}
