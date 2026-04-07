// simplebanking-mcp — MCP server for simplebanking (stdio transport, read-only)
// Reads directly from ~/Library/Application Support/simplebanking/transactions.db
// The simplebanking app does NOT need to be running.

import Foundation

while true {
    guard let message = readMessage() else { break }
    if let reply = handleMessage(message) {
        writeMessage(reply)
    }
}
