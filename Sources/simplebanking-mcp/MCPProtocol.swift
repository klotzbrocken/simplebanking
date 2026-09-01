import Foundation
import Darwin
import MCPRahmen

// MARK: - Raw POSIX I/O (no buffering layers)

private func posixReadByte() -> UInt8? {
    var byte = UInt8(0)
    let n = Darwin.read(STDIN_FILENO, &byte, 1)
    return n == 1 ? byte : nil
}

private func posixReadExact(_ count: Int) -> Data? {
    var buf = [UInt8](repeating: 0, count: count)
    var total = 0
    while total < count {
        let n = Darwin.read(STDIN_FILENO, &buf[total], count - total)
        if n <= 0 { return nil }
        total += n
    }
    return Data(buf)
}

private func posixWrite(_ data: Data) {
    data.withUnsafeBytes { ptr in
        var written = 0
        while written < data.count {
            let n = Darwin.write(STDOUT_FILENO, ptr.baseAddress!.advanced(by: written), data.count - written)
            if n <= 0 { break }
            written += n
        }
    }
}

// MARK: - MCP framing

/// Liest eine Zeile bis zum Zeilenumbruch. `grenze` begrenzt die Länge; wird sie
/// überschritten, bricht das Lesen ab, statt weiter Speicher zu belegen.
private func leseZeile(grenze: Int) -> String? {
    var zeile = ""
    while true {
        guard let byte = posixReadByte() else { return nil }
        if byte == UInt8(ascii: "\n") {
            if zeile.last == "\r" { zeile.removeLast() }
            return zeile
        }
        zeile.append(Character(UnicodeScalar(byte)))
        guard zeile.utf8.count <= grenze else {
            FileHandle.standardError.write(Data("mcp: Zeile über \(grenze) Bytes — abgebrochen\n".utf8))
            return nil
        }
    }
}

func readMessage() -> [String: Any]? {
    // Die erste Zeile behält die große Grenze: Im NDJSON-Modus ist sie die vollständige
    // Nachricht und kein Header.
    guard let erste = leseZeile(grenze: maxNachrichtenGroesse) else { return nil }

    // NDJSON mode: line starts with '{' — no Content-Length framing
    if erste.hasPrefix("{") {
        guard let data = erste.data(using: .utf8),
              let msg = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return msg
    }

    // LSP framing mode: erst alle Headerzeilen einsammeln, dann einmal prüfen. Die
    // frühere Fassung prüfte nach der ersten Zeile und ließ spätere Zeilen den geprüften
    // Wert überschreiben — ein zweites `Content-Length` umging damit die Grenze.
    var headerZeilen = [erste]
    while true {
        guard let zeile = leseZeile(grenze: maxHeaderZeile) else { return nil }
        if zeile.isEmpty { break }
        headerZeilen.append(zeile)
    }

    let laenge: Int
    switch MCPRahmen.koerperLaenge(headerZeilen: headerZeilen) {
    case .success(let n):
        laenge = n
    case .failure(let fehler):
        FileHandle.standardError.write(Data("mcp: \(fehler) — abgelehnt\n".utf8))
        return nil
    }

    guard let body = posixReadExact(laenge),
          let msg = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
    else { return nil }
    return msg
}

func writeMessage(_ obj: [String: Any]) {
    guard let body = try? JSONSerialization.data(withJSONObject: obj) else { return }
    // Respond in NDJSON format (matches Claude Desktop's transport)
    posixWrite(body)
    posixWrite(Data([0x0A])) // newline
}

// MARK: - Message handler

func handleMessage(_ msg: [String: Any]) -> [String: Any]? {
    let method = msg["method"] as? String ?? ""
    let hasId   = msg.keys.contains("id")
    let id: Any = msg["id"] ?? NSNull()

    guard hasId else { return nil }

    let params = msg["params"] as? [String: Any] ?? [:]

    switch method {
    case "initialize":
        let clientVersion = params["protocolVersion"] as? String ?? "2024-11-05"
        return response(id: id, result: [
            "protocolVersion": clientVersion,
            "capabilities": ["tools": [String: Any]()],
            "serverInfo": ["name": "simplebanking-mcp", "version": "1.3.4"]
        ])
    case "tools/list":
        // Gefiltert, nicht nur gesperrt: Was ein Client nicht darf, soll er gar nicht
        // erst angeboten bekommen. Ein Werkzeug, das sichtbar ist und dann ablehnt,
        // lädt ein Sprachmodell zum Nachbohren ein.
        let erlaubt = Zugang.befund()
        let werkzeuge = BankingTools.toolList().filter { werkzeug in
            guard let name = werkzeug["name"] as? String,
                  let noetig = Zugang.bereich(fuerWerkzeug: name) else { return false }
            return erlaubt.bereiche.contains(noetig)
        }
        return response(id: id, result: ["tools": werkzeuge])
    case "tools/call":
        let name = params["name"] as? String ?? ""
        let args = params["arguments"] as? [String: Any] ?? [:]

        // Zweite Prüfung, obwohl die Liste schon gefiltert ist: Ein Client kann ein
        // Werkzeug aufrufen, das er nie angeboten bekam — die Liste ist eine Auskunft,
        // keine Sperre.
        let befund = Zugang.befund()
        guard let noetig = Zugang.bereich(fuerWerkzeug: name) else {
            return errorResponse(id: id, code: -32601, message: "Unknown tool: \(name)")
        }
        guard befund.bereiche.contains(noetig) else {
            let grund = befund.bereiche.isEmpty
                ? "Access token missing, revoked or expired. Manage clients in simplebanking → Settings."
                : "This client has no '\(noetig.rawValue)' scope. Grant it in simplebanking → Settings."
            return response(id: id, result: [
                "content": [["type": "text", "text": grund]],
                "isError": true
            ])
        }

        let (text, isError) = BankingTools.call(name: name, args: args)
        return response(id: id, result: [
            "content": [["type": "text", "text": isError ? text : BankingTools.alsDaten(text)]],
            "isError": isError
        ])
    case "ping":
        return response(id: id, result: [String: Any]())
    default:
        return errorResponse(id: id, code: -32601, message: "Method not found: \(method)")
    }
}

private func response(id: Any, result: Any) -> [String: Any] {
    ["jsonrpc": "2.0", "id": id, "result": result]
}

private func errorResponse(id: Any, code: Int, message: String) -> [String: Any] {
    ["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]]
}
