import AppKit

// simplebanking (YAXI backend on localhost)
// - Shows booked balance in menu bar without decimals.
// - Refreshes every 15 minutes.
// - Stores Sparkasse credentials in Keychain.

@main
struct SimpleBankingApp {
    // NSApplication keeps a weak delegate reference. Keep a strong reference for app lifetime.
    @MainActor
    private static var retainedDelegate: AppDelegate?

    @MainActor
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        retainedDelegate = delegate
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}
