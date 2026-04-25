// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "simplebanking",
    platforms: [
        // macOS 14 matches the deployment target of routex-client-swift (0.4+) — verhindert
        // Linker-Warnings „was built for newer 'macOS' version (14.0) than being linked (13.0)".
        .macOS(.v14)
    ],
    products: [
        .executable(name: "simplebanking", targets: ["simplebanking"]),
        .executable(name: "simplebanking-mcp", targets: ["simplebanking-mcp"]),
        .executable(name: "simplebanking-cli", targets: ["simplebanking-cli"])
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "6.0.0"),
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.0.0"),
        .package(url: "https://github.com/yaxitech/routex-client-swift", from: "0.3.0"),
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.3.0")
    ],
    targets: [
        .executableTarget(
            name: "simplebanking",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "Sparkle", package: "Sparkle"),
                .product(name: "RoutexClient", package: "routex-client-swift")
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
                .copy("Resources/Clippy.png"),
                .copy("Resources/animations.json"),
                .copy("Resources/bank-logos"),
                .copy("Resources/merchant-logos"),
                .copy("Resources/Fonts/SpaceMono-Regular.ttf"),
                .copy("Resources/Fonts/SpaceMono-Bold.ttf"),
            ],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("AuthenticationServices"),
                .linkedFramework("Security")
            ]
        ),
        .executableTarget(
            name: "simplebanking-mcp",
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
        .testTarget(
            name: "simplebankingTests",
            dependencies: [
                "simplebanking",
                .product(name: "GRDB", package: "GRDB.swift"),
            ],
            path: "Tests/simplebankingTests"
        )
    ]
)
