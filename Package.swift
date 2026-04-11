// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "simplebanking",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "simplebanking", targets: ["simplebanking"]),
        .executable(name: "simplebanking-mcp", targets: ["simplebanking-mcp"])
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "6.0.0"),
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.0.0"),
        .package(url: "https://github.com/yaxitech/routex-client-swift", from: "0.3.0")
    ],
    targets: [
        .executableTarget(
            name: "simplebanking",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "Sparkle", package: "Sparkle"),
                .product(name: "RoutexClient", package: "routex-client-swift")
            ],
            resources: [
                .copy("Resources/categories_de.json"),
                .copy("Resources/Clippy.png"),
                .copy("Resources/animations.json"),
                .copy("Resources/bank-logos"),
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
