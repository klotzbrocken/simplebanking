import Foundation

// MARK: - Bank Logo Mapping (Germany)

enum BankLogoAssets {
    struct BankBrand: Hashable {
        let id: String
        let displayName: String
        let logoURL: URL
        let accentColor: String
        let keywords: [String]
    }

    static let brands: [BankBrand] = [
        BankBrand(
            id: "sparkasse",
            displayName: "Sparkasse",
            logoURL: bundled("sparkasse"),
            accentColor: "FF0000",
            keywords: ["sparkasse", "spk", "stadtsparkasse", "kreissparkasse", "landessparkasse", "nasspa", "haspa", "ospa"]
        ),
        BankBrand(
            id: "volksbank",
            displayName: "Volksbank / Raiffeisenbank",
            logoURL: bundled("volk"),
            accentColor: "003399",
            keywords: ["volksbank", "raiffeisenbank", "vr bank", "vr-bank", "raiffeisen", "voba", "genobank", "sparda"]
        ),
        BankBrand(
            id: "deutsche-bank",
            displayName: "Deutsche Bank",
            logoURL: bundled("deutsche"),
            accentColor: "0018A8",
            keywords: ["deutsche bank"]
        ),
        BankBrand(
            id: "commerzbank",
            displayName: "Commerzbank",
            logoURL: bundled("commerz"),
            accentColor: "FFCC00",
            keywords: ["commerzbank"]
        ),
        BankBrand(
            id: "postbank",
            displayName: "Postbank",
            logoURL: bundled("post"),
            accentColor: "FFCC00",
            keywords: ["postbank"]
        ),
        BankBrand(
            id: "unicredit",
            displayName: "HypoVereinsbank",
            logoURL: bundled("unicredit"),
            accentColor: "D71920",
            keywords: ["hypovereinsbank", "hvb", "unicredit"]
        ),
        BankBrand(
            id: "ing",
            displayName: "ING",
            logoURL: bundled("ing"),
            accentColor: "FF6200",
            keywords: ["ing", "ing-diba", "ing diba", "ing deutschland"]
        ),
        BankBrand(
            id: "dkb",
            displayName: "DKB",
            logoURL: bundled("dkb"),
            accentColor: "005E7D",
            keywords: ["dkb", "deutsche kreditbank"]
        ),
        BankBrand(
            id: "comdirect",
            displayName: "comdirect",
            logoURL: bundled("comdirect"),
            accentColor: "FFD700",
            keywords: ["comdirect"]
        ),
        BankBrand(
            id: "norisbank",
            displayName: "norisbank",
            logoURL: wiki("Norisbank_2021_logo.svg"),
            accentColor: "007A3D",
            keywords: ["norisbank"]
        ),
        BankBrand(
            id: "consorsbank",
            displayName: "Consorsbank",
            logoURL: bundled("consors"),
            accentColor: "003B7E",
            keywords: ["consorsbank", "consors", "bnp paribas"]
        ),
        BankBrand(
            id: "1822direkt",
            displayName: "1822direkt",
            logoURL: bundled("1822direkt"),
            accentColor: "E30613",
            keywords: ["1822direkt", "1822"]
        ),
        BankBrand(
            id: "n26",
            displayName: "N26",
            logoURL: bundled("n26"),
            accentColor: "36A18B",
            keywords: ["n26", "number26"]
        ),
        BankBrand(
            id: "c24",
            displayName: "C24 Bank",
            logoURL: bundled("c24"),
            accentColor: "003C64",
            keywords: ["c24"]
        ),
        BankBrand(
            id: "vivid",
            displayName: "Vivid Money",
            logoURL: bundled("vivid"),
            accentColor: "6C3AFF",
            keywords: ["vivid"]
        ),
        BankBrand(
            id: "tomorrow",
            displayName: "Tomorrow Bank",
            logoURL: bundled("tomorrow"),
            accentColor: "1A1A1A",
            keywords: ["tomorrow"]
        ),
        BankBrand(
            id: "targobank",
            displayName: "Targobank",
            logoURL: bundled("targo"),
            accentColor: "003A65",
            keywords: ["targobank", "targo"]
        ),
        BankBrand(
            id: "santander",
            displayName: "Santander",
            logoURL: bundled("santander"),
            accentColor: "EC0000",
            keywords: ["santander"]
        ),
        BankBrand(
            id: "degussa",
            displayName: "Degussa Bank",
            logoURL: wiki("Degussa_Bank_Logo.svg"),
            accentColor: "003366",
            keywords: ["degussa"]
        ),
        BankBrand(
            id: "psd",
            displayName: "PSD Bank",
            logoURL: bundled("psd"),
            accentColor: "009EE3",
            keywords: ["psd bank"]
        ),
        BankBrand(
            id: "oldenburgische",
            displayName: "Oldenburgische Landesbank",
            logoURL: bundled("olb"),
            accentColor: "003366",
            keywords: ["oldenburgische landesbank", "olb"]
        ),
        BankBrand(
            id: "apobank",
            displayName: "apoBank",
            logoURL: bundled("apo"),
            accentColor: "003B7E",
            keywords: ["apobank", "apo bank", "apotheker"]
        ),
        BankBrand(
            id: "gls",
            displayName: "GLS Bank",
            logoURL: bundled("gls"),
            accentColor: "006633",
            keywords: ["gls bank", "gls gemeinschaftsbank"]
        ),
        BankBrand(
            id: "triodos",
            displayName: "Triodos Bank",
            logoURL: bundled("triodos"),
            accentColor: "004B3A",
            keywords: ["triodos"]
        ),
        BankBrand(
            id: "ethikbank",
            displayName: "EthikBank",
            logoURL: bundled("ethik"),
            accentColor: "009640",
            keywords: ["ethikbank"]
        ),
        BankBrand(
            id: "helaba",
            displayName: "Landesbank Hessen-Thuringen",
            logoURL: wiki("Helaba_logo.svg"),
            accentColor: "004F9F",
            keywords: ["landesbank hessen", "helaba", "landesbank hessen-thuringen", "landesbank hessen-thueringen"]
        ),
        BankBrand(
            id: "bundesbank",
            displayName: "Deutsche Bundesbank",
            logoURL: bundled("bundes"),
            accentColor: "003399",
            keywords: ["bundesbank"]
        ),
        BankBrand(
            id: "revolut",
            displayName: "Revolut",
            logoURL: bundled("revolut"),
            accentColor: "191C1F",
            keywords: ["revolut"]
        ),
    ]

    private static let brandsByID: [String: BankBrand] = {
        Dictionary(uniqueKeysWithValues: brands.map { ($0.id, $0) })
    }()

    private static let logoIDMapping: [String: String] = [
        "sparkasse": "sparkasse",
        "spk": "sparkasse",
        "vr": "volksbank",
        "volksbank": "volksbank",
        "raiffeisen": "volksbank",
        "deutsche-bank": "deutsche-bank",
        "deutschebank": "deutsche-bank",
        "commerzbank": "commerzbank",
        "postbank": "postbank",
        "ing": "ing",
        "dkb": "dkb",
        "comdirect": "comdirect",
        "n26": "n26",
        "c24": "c24",
        "targobank": "targobank",
        "santander": "santander",
        "revolut": "revolut",
    ]

    private static let blzMapping: [String: String] = [
        "50070010": "deutsche-bank",
        "10070000": "deutsche-bank",
        "50070024": "deutsche-bank",
        "50040000": "commerzbank",
        "50080000": "commerzbank",
        "50010517": "ing",
        "12030000": "dkb",
        "10011001": "n26",
        "10022400": "c24",
        "50010060": "postbank",
        "44010046": "postbank",
        "30020900": "targobank",
        "20041111": "comdirect",
        "20041133": "comdirect",
        "10077777": "norisbank",
        "10010010": "revolut",
    ]

    private static let blzPrefixMapping: [String: String] = [
        "120": "dkb",
        // "500" removed: too broad — catches Sparkasse Frankfurt and others.
        // "100" removed: too broad — catches Revolut (10010010), N26 (10011001), etc.
        // Deutsche Bank and comdirect are covered by exact BLZ entries.
        "200": "comdirect",
    ]

    static func resolve(displayName: String?, logoID: String?, iban: String?) -> BankBrand? {
        if let logoID, let byLogo = find(byLogoID: logoID) {
            return withGeneratedColor(byLogo)
        }
        if let displayName, let byName = find(byName: displayName) {
            return withGeneratedColor(byName)
        }
        if let iban, let byIBAN = find(byIBAN: iban) {
            return withGeneratedColor(byIBAN)
        }
        return nil
    }

    /// Overrides accentColor with the value from GeneratedBankColors if available.
    private static func withGeneratedColor(_ brand: BankBrand) -> BankBrand {
        guard let color = GeneratedBankColors.primaryColor(forLogoId: brand.id) else {
            return brand
        }
        return BankBrand(
            id: brand.id,
            displayName: brand.displayName,
            logoURL: brand.logoURL,
            accentColor: color,
            keywords: brand.keywords
        )
    }

    static func find(byLogoID logoID: String) -> BankBrand? {
        let key = normalize(logoID).replacingOccurrences(of: " ", with: "")
        for (needle, brandID) in logoIDMapping {
            if key.contains(needle), let brand = brandsByID[brandID] {
                return brand
            }
        }
        return nil
    }

    static func find(byName name: String) -> BankBrand? {
        let normalizedName = normalize(name)
        guard !normalizedName.isEmpty else { return nil }

        return brands.first { brand in
            brand.keywords.contains { keyword in
                normalizedName.contains(normalize(keyword))
            }
        }
    }

    static func find(byIBAN iban: String) -> BankBrand? {
        let cleanIBAN = iban
            .replacingOccurrences(of: " ", with: "")
            .uppercased()
        guard cleanIBAN.hasPrefix("DE"), cleanIBAN.count >= 12 else {
            return nil
        }

        let start = cleanIBAN.index(cleanIBAN.startIndex, offsetBy: 4)
        let end = cleanIBAN.index(start, offsetBy: 8)
        let blz = String(cleanIBAN[start..<end])
        let prefix3 = String(blz.prefix(3))
        let digit4 = blz.count >= 4 ? String(blz[blz.index(blz.startIndex, offsetBy: 3)]) : ""

        if let brandID = blzMapping[blz], let brand = brandsByID[brandID] {
            return brand
        }
        if let brandID = blzPrefixMapping[prefix3], let brand = brandsByID[brandID] {
            return brand
        }

        // Generic German bank groups (fallback only).
        if digit4 == "5" {
            return brandsByID["sparkasse"]
        }
        if digit4 == "6" || digit4 == "9" {
            return brandsByID["volksbank"]
        }
        return nil
    }

    private static func normalize(_ value: String) -> String {
        value
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "de_DE"))
            .replacingOccurrences(of: "ß", with: "ss")
            .replacingOccurrences(of: "[^a-z0-9]+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    // MARK: - Dark Mode Detection

    /// Gibt true zurück wenn das Logo dieser Bank im Dark Mode invertiert werden soll.
    /// Kriterien: SVG hat data-maskable="true" UND data-primary-color mit Luminanz < 0.15.
    static func isDark(brandId: String) -> Bool { darkBrandIDs.contains(brandId) }

    private static let darkBrandIDs: Set<String> = {
        var result: Set<String> = []
        let pattern = #"data-primary-color="(#[0-9A-Fa-f]{6})""#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return result }
        for brand in brands {
            guard brand.logoURL.isFileURL,
                  let svg = try? String(contentsOf: brand.logoURL),
                  svg.contains("data-maskable=\"true\"") else { continue }
            let ns = svg as NSString
            guard let match = regex.firstMatch(in: svg, range: NSRange(location: 0, length: ns.length)),
                  let range = Range(match.range(at: 1), in: svg) else { continue }
            if isHexColorDark(String(svg[range])) { result.insert(brand.id) }
        }
        return result
    }()

    private static func isHexColorDark(_ hex: String) -> Bool {
        let h = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard h.count == 6, let n = UInt64(h, radix: 16) else { return false }
        let r = Double((n >> 16) & 0xFF) / 255
        let g = Double((n >> 8)  & 0xFF) / 255
        let b = Double(n         & 0xFF) / 255
        return 0.2126 * r + 0.7152 * g + 0.0722 * b < 0.15
    }

    /// Returns a file URL to a bundled SVG in Resources/bank-logos/, or falls back to a placeholder.
    private static func bundled(_ name: String) -> URL {
        if let url = Bundle.main.url(forResource: name, withExtension: "svg", subdirectory: "bank-logos") {
            return url
        }
        // Fallback: should never happen for correctly bundled assets
        return URL(fileURLWithPath: "/")
    }

    private static func wiki(_ filename: String, width: Int = 72) -> URL {
        let encoded = filename.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? filename
        let raw = "https://commons.wikimedia.org/wiki/Special:FilePath/\(encoded)?width=\(width)"
        if let url = URL(string: raw) {
            return url
        }
        return URL(fileURLWithPath: "/")
    }
}
