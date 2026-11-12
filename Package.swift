// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "simplebanking",
    platforms: [
        // routex-client-swift 0.5 verlangt nur noch macOS 12; wir bleiben bei 14, weil
        // die App selbst darauf aufbaut (und der Appcast es so ausweist).
        // macOS 14 matches the deployment target of routex-client-swift (0.4+) — verhindert
        // Linker-Warnings „was built for newer 'macOS' version (14.0) than being linked (13.0)".
        .macOS(.v14)
    ],
    products: [
        .executable(name: "simplebanking", targets: ["simplebanking"]),
        .executable(name: "simplebanking-mcp", targets: ["simplebanking-mcp"]),
        .executable(name: "simplebanking-cli", targets: ["simplebanking-cli"]),
        // Liest eine MoneyMoney-Datenbank (SQLCipher) und schreibt sie als Plist.
        // Eigener Prozess, weil SQLCipher dieselben `sqlite3_*`-Symbole exportiert
        // wie das System-SQLite, an dem GRDB hängt — und weil in derselben Datei
        // die Bank-PIN des Nutzers liegt.
        .executable(name: "simplebanking-mmimport", targets: ["simplebanking-mmimport"])
        // Der REWE-Prüfstand gehört bewusst **nicht** mehr hierher, siehe
        // `scripts/REWEPoc/Package.swift`. Ein `executableTarget` bekommt von
        // SwiftPM immer ein implizites Produkt — „Ziel, aber kein Produkt" gibt es
        // nicht. Also baute jedes `swift build` ihn mit, und weil `-Xswiftc` für
        // jedes Modul gilt, schrieben CLI, MCP und der Prüfstand in dieselbe
        // Const-Values-Datei.
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "6.0.0"),
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.0.0"),
        .package(url: "https://github.com/yaxitech/routex-client-swift", from: "0.6.0"),
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.3.0"),
        // SQLite mit SQLCipher als C-Quellen (MIT). Nur `simplebanking-mmimport`
        // hängt daran — NIE die App, das Testziel oder die CLI, sonst liegen zwei
        // Implementierungen derselben Symbole in einem Binary.
        .package(url: "https://github.com/skiptools/swift-sqlcipher", from: "1.13.0")
    ],
    targets: [
        .executableTarget(
            name: "simplebanking",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "Sparkle", package: "Sparkle"),
                .product(name: "RoutexClient", package: "routex-client-swift"),
                .product(name: "RoutexRefresh", package: "routex-client-swift"),
                "MoneyMoneyForm"
            ],
            exclude: [
                // Entitlements-Dateien werden von build-app.sh zur Signing-Zeit verwendet,
                // nicht als Runtime-Resource eingebettet.
                "simplebanking.entitlements",
                "simplebanking-dev.entitlements",
                "simplebanking-mas.entitlements",
                // Metal-Shader wird via build-app.sh kompiliert (SwiftPM kann .metal nicht nativ).
                "Ripple.metal",
                // Unbenutzte Assets (nicht im Code referenziert)
                "Resources/Genius.png",
                "Resources/Links.png",
            ],
            resources: [
                .copy("Resources/categories_de.json"),
                .copy("Resources/yaxi-bank-catalog.json"),
                .copy("Resources/merchant-logos"),
                .copy("Resources/Fonts/SpaceMono-Regular.ttf"),
                .copy("Resources/Fonts/SpaceMono-Bold.ttf"),
                // BTX-Theme: VT323 (OFL-1.1, Lizenztext liegt daneben und muss
                // mit ausgeliefert werden). Latin-Subset aus dem Theme-Paket.
                .copy("Resources/Fonts/VT323-Regular.ttf"),
                .copy("Resources/Fonts/VT323-OFL.txt"),
            ],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("AuthenticationServices"),
                .linkedFramework("Security")
            ]
        ),
        // Reine Rahmenprüfung des MCP-Protokolls. Eigenes Ziel, weil
        // `simplebanking-mcp` ein Executable mit `main.swift` ist und sich aus dem
        // Testziel nicht importieren lässt; ein Quelltext kann in SwiftPM nicht zu
        // zwei Zielen gehören.
        .target(
            name: "MCPRahmen",
            path: "Sources/MCPRahmen"
        ),
        .executableTarget(
            name: "simplebanking-mcp",
            dependencies: ["MCPRahmen"],
            path: "Sources/simplebanking-mcp",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .executableTarget(
            name: "simplebanking-cli",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "ArgumentParser", package: "swift-argument-parser")
            ],
            path: "Sources/simplebanking-cli"
        ),
        // Drahtform und Leseregeln des MoneyMoney-Imports. Eigenes Ziel aus
        // demselben Grund wie `MCPRahmen`: Der Helfer ist ein Executable mit
        // `main.swift` und lässt sich aus dem Testziel nicht importieren. Hier hängt
        // bewusst NICHTS dran — zieht dieses Ziel GRDB oder SQLCipher mit, liegen
        // beide SQLite-Implementierungen im Testbinary.
        .target(
            name: "MoneyMoneyForm",
            path: "Sources/MoneyMoneyForm"
        ),
        .executableTarget(
            name: "simplebanking-mmimport",
            dependencies: [
                "MoneyMoneyForm",
                .product(name: "SQLCipher", package: "swift-sqlcipher")
            ],
            path: "Sources/simplebanking-mmimport",
            // `sqlite3_key` steht in sqlite3.h hinter `SQLITE_HAS_CODEC`. Das Paket
            // setzt das Define nicht selbst, sondern erwartet es beim Verbraucher —
            // seine eigenen Ziele `SQLCipherTests` und `SQLiteDB` machen es genauso.
            // Ohne das Define übersetzt alles, nur die Schlüsselfunktionen fehlen.
            cSettings: [.define("SQLITE_HAS_CODEC")]
        ),
        .testTarget(
            name: "simplebankingTests",
            dependencies: [
                "simplebanking",
                "MCPRahmen",
                "MoneyMoneyForm",
                .product(name: "GRDB", package: "GRDB.swift"),
            ],
            path: "Tests/simplebankingTests"
        )
    ]
)
