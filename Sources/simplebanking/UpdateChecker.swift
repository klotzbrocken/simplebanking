import Sparkle

/// Wraps SPUStandardUpdaterController for use in the menu-bar app.
/// Auto-checks for updates on launch; exposes checkForUpdates() for the menu item.
@MainActor
final class UpdateChecker: NSObject {
    private let updaterController: SPUStandardUpdaterController

    override init() {
        updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
    }

    func checkForUpdates() {
        updaterController.checkForUpdates(nil)
    }
}
