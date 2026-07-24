import XCTest
@testable import simplebanking

// MARK: - MCPInstaller Tests
//
// Reine Ziel-Erkennung (Owner-Check) — analog CLIInstaller. Verhindert, dass ein
// fremder Symlink unter ~/.local/bin/simplebanking-mcp überschrieben wird.

final class MCPInstallerTests: XCTestCase {

    func test_targetIsOurs_nil_isFalse() {
        XCTAssertFalse(MCPInstaller.targetIsOurs(nil))
    }

    func test_targetIsOurs_exactBundlePath_isTrue() {
        XCTAssertTrue(MCPInstaller.targetIsOurs(MCPInstaller.sourceURL.path))
    }

    func test_targetIsOurs_bundleSuffix_isTrue() {
        // Auch ein anderer Installationsort mit dem bekannten Bundle-Suffix zählt
        // (deckt App-Verschiebungen ab).
        XCTAssertTrue(MCPInstaller.targetIsOurs(
            "/Users/someone/Applications/simplebanking.app/Contents/MacOS/simplebanking-mcp"))
    }

    func test_targetIsOurs_foreignPath_isFalse() {
        XCTAssertFalse(MCPInstaller.targetIsOurs("/opt/homebrew/bin/simplebanking-mcp"))
        XCTAssertFalse(MCPInstaller.targetIsOurs("/usr/local/bin/some-other-tool"))
    }

    func test_symlinkPath_isInLocalBin() {
        XCTAssertTrue(MCPInstaller.symlinkURL.path.hasSuffix(".local/bin/simplebanking-mcp"))
    }
}
