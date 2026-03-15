// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "simplebanking",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "simplebanking", targets: ["simplebanking"])
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
                .copy("Resources/Genius.png"),
                .copy("Resources/Links.png"),
                .copy("Resources/animations.json"),
            ],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("AuthenticationServices"),
                .linkedFramework("Security")
            ]
        )
    ]
)
