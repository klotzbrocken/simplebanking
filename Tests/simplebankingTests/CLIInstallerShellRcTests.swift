import XCTest
@testable import simplebanking

// MARK: - CLIInstaller shell-rc append tests
//
// Schützt die PATH-Auto-Fix-UX:
//  - shellRcLine ist garantiert ASCII (kein OCR-Mojibake-Risiko)
//  - appendShellRcLineIfMissing ist idempotent (doppelte Aufrufe → ein Eintrag)
//  - Marker erkennt vorherige Konfiguration
//  - Newline-Handling sauber

final class CLIInstallerShellRcTests: XCTestCase {

    // MARK: - shellRcLine ist ASCII

    func test_shellRcLine_isAsciiOnly() {
        let line = CLIInstaller.shellRcLine
        let asciiData = line.data(using: .ascii)
        XCTAssertNotNil(asciiData,
            "shellRcLine darf nur ASCII enthalten — sonst leakt Unicode-Mojibake (kyrillische H/O/M/E)")
        // Defense in depth: jedes Byte ist im 0x20–0x7E Range
        for byte in line.utf8 {
            XCTAssertLessThanOrEqual(byte, 0x7E,
                "Byte \(byte) ist nicht im ASCII-printable-Range — Live-Text-OCR-Risiko")
            XCTAssertGreaterThanOrEqual(byte, 0x20,
                "Byte \(byte) ist nicht im ASCII-printable-Range")
        }
    }

    func test_shellRcLine_hasExpectedContent() {
        // Schützt gegen Refactor-Drift — die Zeile MUSS exakt das sein,
        // weil User das im Terminal sehen + verstehen können müssen.
        XCTAssertEqual(CLIInstaller.shellRcLine,
                       "export PATH=\"$HOME/.local/bin:$PATH\"")
    }

    // MARK: - appendShellRcLineIfMissing idempotency

    func test_emptyContent_appendsLineWithMarker() {
        let result = CLIInstaller.appendShellRcLineIfMissing(content: "")
        XCTAssertTrue(result.contains(CLIInstaller.shellRcLine))
        XCTAssertTrue(result.contains(CLIInstaller.shellRcMarker))
    }

    func test_alreadyContainsLine_isNoop() {
        let existing = "# my own zshrc\nexport FOO=bar\nexport PATH=\"$HOME/.local/bin:$PATH\"\n"
        let result = CLIInstaller.appendShellRcLineIfMissing(content: existing)
        XCTAssertEqual(result, existing,
            "Wenn Zeile schon drin: keine Änderung (idempotent)")
    }

    func test_alreadyContainsMarker_isNoop() {
        // Marker präsent, aber jemand hat die Zeile selbst editiert (z.B. anderer Pfad).
        // Wir respektieren das und tun nichts.
        let existing = "# my zshrc\n\(CLIInstaller.shellRcMarker)\nexport PATH=\"/custom:$PATH\"\n"
        let result = CLIInstaller.appendShellRcLineIfMissing(content: existing)
        XCTAssertEqual(result, existing)
    }

    func test_doubleCall_doesNotProduceDuplicate() {
        let first = CLIInstaller.appendShellRcLineIfMissing(content: "")
        let second = CLIInstaller.appendShellRcLineIfMissing(content: first)
        XCTAssertEqual(first, second,
            "Zwei aufeinander folgende Aufrufe müssen das gleiche Ergebnis liefern")
        // Genau eine Zeile mit dem export-Statement
        let count = first.components(separatedBy: CLIInstaller.shellRcLine).count - 1
        XCTAssertEqual(count, 1, "Nur eine Kopie der export-Line darf drin sein")
    }

    // MARK: - Newline handling

    func test_contentWithoutTrailingNewline_getsLineSeparator() {
        let existing = "# no trailing newline"
        let result = CLIInstaller.appendShellRcLineIfMissing(content: existing)
        XCTAssertTrue(result.hasPrefix("# no trailing newline\n"),
            "Wenn content nicht mit \\n endet, muss eines vor dem Append eingefügt werden")
        XCTAssertTrue(result.hasSuffix("\n"),
            "Result soll mit \\n enden — saubere File-Konvention")
    }

    func test_contentEndingInNewline_doesNotDoubleNewline() {
        let existing = "# already has newline\n"
        let result = CLIInstaller.appendShellRcLineIfMissing(content: existing)
        // Es darf keine drei \n in Folge geben (existing\n + \n vor marker + ...)
        XCTAssertFalse(result.contains("\n\n\n"),
            "Kein Triple-Newline (Trailing-\\n + unser eigenes \\n + Marker)")
    }

    // MARK: - Marker stability

    func test_marker_isAsciiOnly() {
        let marker = CLIInstaller.shellRcMarker
        XCTAssertNotNil(marker.data(using: .ascii),
            "Marker muss ASCII sein — sonst kann er bei Re-Read drift'en")
    }

    func test_marker_mentionsSimplebanking() {
        // Damit ein User der ~/.zshrc öffnet weiß WOHER der Eintrag kommt.
        XCTAssertTrue(CLIInstaller.shellRcMarker.lowercased().contains("simplebanking"))
    }
}
