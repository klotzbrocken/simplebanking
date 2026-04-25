import Foundation
import Network

// Minimal local HTTP server that handles the bank's OAuth redirect callback.
// The bank redirects the user's browser here after they approve the connection.
// We return a friendly HTML page so the browser shows success; the actual
// consent-completion signal is sent server-to-server (bank → routex), and our
// polling loop (confirmBalances/Transactions) detects it independently.
//
// Hardening:
//   1. Listener bindet nur auf Loopback (127.0.0.1) — andere Geräte im LAN
//      können den Endpoint nicht erreichen.
//   2. Path-Validation: nur Hits auf `/simplebanking-auth-callback` triggern
//      das Signal. Andere Pfade (Port-Scanner, Browser-Probes) bekommen 404
//      und das Polling wird nicht fälschlich beschleunigt.

final class YaxiOAuthCallback: @unchecked Sendable {

    /// Erwarteter Pfad in der HTTP-Request-Line. Muss mit der `redirectUri`
    /// übereinstimmen, die wir bei Routex registrieren (siehe YaxiService).
    static let expectedPath = "/simplebanking-auth-callback"

    private var listener: NWListener?
    private(set) var port: UInt16 = 0

    /// Starts listening on an ephemeral port. Returns the actual port number.
    func start() async throws -> UInt16 {
        let params = NWParameters.tcp
        // Loopback-only: bind nur auf 127.0.0.1 statt auf alle Interfaces.
        params.requiredInterfaceType = .loopback
        let listener = try NWListener(using: params, on: .any)
        self.listener = listener

        let actualPort: UInt16 = try await withCheckedThrowingContinuation { continuation in
            // Box the flag in a class so the @Sendable closure can mutate it
            // without triggering Swift 6 "mutation of captured var in concurrently-executing code".
            final class Once: @unchecked Sendable { var done = false }
            let once = Once()

            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    guard !once.done else { return }
                    once.done = true
                    continuation.resume(returning: listener.port?.rawValue ?? 0)
                case .failed(let error):
                    guard !once.done else { return }
                    once.done = true
                    continuation.resume(throwing: error)
                case .cancelled:
                    guard !once.done else { return }
                    once.done = true
                    continuation.resume(returning: 0)
                default:
                    break
                }
            }

            listener.newConnectionHandler = { [weak self] connection in
                self?.handleConnection(connection)
            }

            listener.start(queue: .global(qos: .utility))
        }

        self.port = actualPort
        return actualPort
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    /// Called when the bank's redirect hits our localhost callback.
    /// YaxiService sets this to immediately trigger the first confirmation poll.
    var onCallbackReceived: (@Sendable () -> Void)?

    private func handleConnection(_ connection: NWConnection) {
        connection.start(queue: .global(qos: .utility))
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, _, _ in
            let isExpected = Self.requestMatchesExpectedPath(data: data)

            if isExpected {
                // Signal before serving HTML so polling starts immediately
                self?.onCallbackReceived?()
                let html = """
                <!DOCTYPE html>
                <html><head><meta charset="utf-8"><title>Freigabe erteilt</title></head>
                <body style="font-family:sans-serif;text-align:center;padding:60px">
                <h2>&#x2713; Freigabe erteilt</h2>
                <p>Die Banking-Verbindung wird jetzt eingerichtet.</p>
                <p style="color:#888;font-size:14px">Du kannst dieses Fenster schlie&szlig;en.</p>
                </body></html>
                """
                let body = html.data(using: .utf8)!
                let header = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
                let responseData = header.data(using: .utf8)! + body
                connection.send(content: responseData, completion: .contentProcessed { _ in
                    connection.cancel()
                })
            } else {
                // Falscher Pfad (Port-Scan, Browser-Probe, …) — 404, kein Signal.
                let body = Data("Not Found".utf8)
                let header = "HTTP/1.1 404 Not Found\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
                let responseData = header.data(using: .utf8)! + body
                connection.send(content: responseData, completion: .contentProcessed { _ in
                    connection.cancel()
                })
            }
        }
    }

    /// Pure helper: prüft ob die HTTP-Request-Line den erwarteten Pfad trifft.
    /// Robust gegen `?query=...` und Unicode-noise. Public für Tests.
    static func requestMatchesExpectedPath(data: Data?) -> Bool {
        guard let data, !data.isEmpty,
              let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
            return false
        }
        // HTTP-Request: erste Zeile = "METHOD path HTTP/x.x"
        let firstLine = text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
        let parts = firstLine.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count >= 2 else { return false }
        // Trim ?query und anchor — wir matchen nur den Path.
        let rawPath = String(parts[1])
        let pathOnly = rawPath.split(separator: "?", maxSplits: 1).first.map(String.init) ?? rawPath
        return pathOnly == expectedPath
    }
}
