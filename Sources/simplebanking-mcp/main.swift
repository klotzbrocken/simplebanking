// simplebanking-mcp — MCP server for simplebanking (stdio transport)
//
// **Ausschließlich lesend.** Der Server liest
// ~/Library/Application Support/simplebanking/transactions.db und kann nichts schreiben,
// nichts vorbereiten und nichts auslösen. `prepare_transfer` gab es bis 08/2026 und ist
// bewusst entfernt: Überweisungen über einen Agenten sind nicht gewollt — bei einem
// Werkzeug, das Kontotexte liest, in denen jede Anweisung stehen kann, ist das Risiko
// den Nutzen nicht wert.
//
// Was ein einzelner Client lesen darf, steuern die Bereiche in `Zugang.swift`.
// Die simplebanking-App muss dafür nicht laufen.

import Foundation

while true {
    guard let message = readMessage() else { break }
    if let reply = handleMessage(message) {
        writeMessage(reply)
    }
}
