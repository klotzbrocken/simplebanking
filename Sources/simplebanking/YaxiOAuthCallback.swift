import Foundation
import Network

// Minimal local HTTP server that handles the bank's OAuth redirect callback.
// The bank redirects the user's browser here after they approve the connection.
// We return a friendly HTML page so the browser shows success; the actual
// consent-completion signal is sent server-to-server (bank → routex), and our
// polling loop (confirmBalances/Transactions) detects it independently.

final class YaxiOAuthCallback: @unchecked Sendable {

    private var listener: NWListener?
    private(set) var port: UInt16 = 0

    /// Starts listening on an ephemeral port. Returns the actual port number.
    func start() async throws -> UInt16 {
        let params = NWParameters.tcp
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

    private func handleConnection(_ connection: NWConnection) {
        connection.start(queue: .global(qos: .utility))
        // Read the HTTP request (we don't need to parse it, just consume it).
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { _, _, _, _ in
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
        }
    }
}
