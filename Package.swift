// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "simplebanking",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "simplebanking", targets: ["simplebanking"])
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "6.0.0"),
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.0.0")
    ],
    targets: [
        .executableTarget(
            name: "simplebanking",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "Sparkle", package: "Sparkle")
            ],
            resources: [
                .copy("Resources/categories_de.json"),
                .copy("Resources/Clippy.png"),
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
