// swift-tools-version: 6.0
import PackageDescription

// Prüfstand für die REWE-eBon-Anbindung — **kein Auslieferungsgegenstand**.
//
// Eigenes Paket, nicht Teil des Wurzelpakets. Der Grund ist nicht Ordnungsliebe:
// Ein `executableTarget` bekommt von SwiftPM immer ein implizites Produkt. Lag der
// Prüfstand im Wurzelpaket, baute ihn jedes `swift build` mit, und weil `-Xswiftc`
// für jedes Modul gilt, schrieben CLI, MCP und er in dieselbe Const-Values-Datei —
// wer zuletzt fertig wurde, gewann. `build-app.sh` musste das mit
// `--product simplebanking` umgehen.
//
// Gebraucht wird er, wenn REWE seine Seite ändert und der eBon-Abruf in der App
// nicht mehr durchkommt: Hier sieht man den Login, die Cookies, die Antwort der
// Receipts-API und das PDF einzeln, ohne die App dazwischen.
//
//     swift run --package-path scripts/REWEPoc rewe-poc
//
// Der `ReceiptParser` hier ist der Stand von Phase 0 und absichtlich eingefroren.
// Der produktive liegt in `Sources/simplebanking/ReweReceipt.swift` und hat sich
// weiterentwickelt; ein Abgleich der beiden zeigt, was seitdem dazugekommen ist.
let package = Package(
    name: "rewe-poc",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "rewe-poc",
            path: ".",
            exclude: ["Package.swift"],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("WebKit"),
                .linkedFramework("PDFKit")
            ]
        )
    ]
)
