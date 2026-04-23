import Foundation
import Darwin

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

func readMessage() -> [String: Any]? {
    // Read the first line
    var line = ""
    while true {
        guard let byte = posixReadByte() else { return nil }
        if byte == UInt8(ascii: "\n") {
            if line.last == "\r" { line.removeLast() }
            break
        }
        line.append(Character(UnicodeScalar(byte)))
    }

    // NDJSON mode: line starts with '{' — no Content-Length framing
    if line.hasPrefix("{") {
        guard let data = line.data(using: .utf8),
              let msg = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return msg
    }

    // LSP framing mode: parse Content-Length + remaining headers, then body
    var contentLength = 0
    if line.lowercased().hasPrefix("content-length:") {
        let val = String(line.dropFirst("content-length:".count)).trimmingCharacters(in: .whitespaces)
        contentLength = Int(val) ?? 0
    }
    // Read remaining headers until blank line
    while true {
        var hline = ""
        while true {
            guard let byte = posixReadByte() else { return nil }
            if byte == UInt8(ascii: "\n") {
                if hline.last == "\r" { hline.removeLast() }
                break
            }
            hline.append(Character(UnicodeScalar(byte)))
        }
        if hline.isEmpty { break }
        if hline.lowercased().hasPrefix("content-length:") {
            let val = String(hline.dropFirst("content-length:".count)).trimmingCharacters(in: .whitespaces)
            contentLength = Int(val) ?? 0
        }
    }
    guard contentLength > 0,
          let body = posixReadExact(contentLength),
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
        return response(id: id, result: ["tools": BankingTools.toolList()])
    case "tools/call":
        let name = params["name"] as? String ?? ""
        let args = params["arguments"] as? [String: Any] ?? [:]
        let (text, isError) = BankingTools.call(name: name, args: args)
        return response(id: id, result: [
            "content": [["type": "text", "text": text]],
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
