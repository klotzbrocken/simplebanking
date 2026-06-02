// simplebanking-mcp — MCP server for simplebanking (stdio transport)
// Read access plus optional draft writes: it reads directly from
// ~/Library/Application Support/simplebanking/transactions.db, and `prepare_transfer`
// writes a transfer draft to Application Support for the app to pick up — gated behind
// the app's opt-in toggle and always requires the user to confirm + SCA in-app.
// The simplebanking app does NOT need to be running for reads.

import Foundation

while true {
    guard let message = readMessage() else { break }
    if let reply = handleMessage(message) {
        writeMessage(reply)
    }
}
