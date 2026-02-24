import Foundation
import Darwin

// MARK: - Backend Manager

@MainActor
final class BackendManager {
    static let shared = BackendManager()
    private var process: Process?
    private var backendLogPipe: Pipe?
    private var startupTask: Task<Void, Never>?
    private(set) var isReady: Bool = false
    private(set) var activePort: Int = 8787
    private(set) var lastStartupIssue: String?
    private var crashRestartTask: Task<Void, Never>?
    private var crashRestartCount: Int = 0
    private static let maxCrashRestarts = 3

    private struct RuntimeLaunch {
        let executableURL: URL
        let arguments: [String]
        let label: String
    }

    func start() {
        guard process == nil else { return }
        lastStartupIssue = nil

        guard let backendJSPath = Bundle.main.path(forResource: "server", ofType: "js", inDirectory: "yaxi-backend-src") else {
            lastStartupIssue = "server.js fehlt im App-Bundle."
            print("[Backend] Error: server.js not found in bundle")
            return
        }

        terminateStaleBundledBackends(matching: backendJSPath)

        let launches = runtimeLaunches(backendJSPath: backendJSPath)
        guard !launches.isEmpty else {
            lastStartupIssue = "Keine lauffähige Node-Runtime im Bundle gefunden."
            print("[Backend] Error: backend runtime not found in bundle")
            return
        }

        // Set working directory to app support for state.json
        let fileManager = FileManager.default
        guard let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return }
        let workDir = appSupport.appendingPathComponent("com.maik.simplebanking")
        try? fileManager.createDirectory(at: workDir, withIntermediateDirectories: true)

        // Create initial state.json if not exists
        let stateFile = workDir.appendingPathComponent("state.json")
        if !fileManager.fileExists(atPath: stateFile.path) {
            let initialState = """
            {
              "iban": null,
              "currency": "EUR",
              "connectionId": null,
              "connectionDisplayName": null,
              "sessionBase64": null,
              "connectionDataBase64": null
            }
            """
            try? initialState.write(to: stateFile, atomically: true, encoding: .utf8)
        }

        startupTask?.cancel()
        startupTask = Task { @MainActor [weak self] in
            guard let self else { return }
            var launchErrors: [String] = []

            for launch in launches {
                if Task.isCancelled { return }

                let port = pickBackendPort()
                activePort = port
                NetworkService.setBackendPort(port)

                let proc = Process()
                proc.executableURL = launch.executableURL
                proc.arguments = launch.arguments
                proc.currentDirectoryURL = workDir

                var env = ProcessInfo.processInfo.environment
                // Avoid broken shell/user NODE_OPTIONS from killing child runtime startup.
                env.removeValue(forKey: "NODE_OPTIONS")
                env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
                env["YAXI_KEY_ID"] = Secrets.yaxiKeyId
                env["YAXI_SECRET_BASE64"] = Secrets.yaxiSecretB64
                env["PORT"] = String(port)
                proc.environment = env

                attachLogging(to: proc)

                do {
                    try proc.run()
                    self.process = proc
                    self.isReady = false
                    self.lastStartupIssue = nil
                    print("[Backend] Started \(launch.label) on port \(port)")

                    let ready = await self.waitForReady(port: port)
                    if Task.isCancelled { return }

                    if ready, self.process === proc {
                        self.isReady = true
                        self.lastStartupIssue = nil
                        self.startupTask = nil
                        self.crashRestartCount = 0
                        print("[Backend] Ready!")
                        return
                    }

                    let reason = "Healthcheck auf Port \(port) hat nicht geantwortet."
                    launchErrors.append("\(launch.label): \(reason)")
                    self.lastStartupIssue = reason
                    print("[Backend] Warning: \(reason). Trying next runtime...")

                    if proc.isRunning {
                        proc.terminate()
                    }
                    if self.process === proc {
                        self.process = nil
                    }
                    self.clearLogPipe()
                } catch {
                    self.clearLogPipe()
                    let reason = "\(launch.label): \(error.localizedDescription)"
                    launchErrors.append(reason)
                    print("[Backend] Failed with \(launch.label): \(error.localizedDescription)")
                }
            }

            self.process = nil
            self.isReady = false
            self.startupTask = nil
            if !launchErrors.isEmpty {
                self.lastStartupIssue = "Backend-Start fehlgeschlagen (\(launchErrors.joined(separator: " | ")))."
            } else {
                self.lastStartupIssue = "Backend-Start fehlgeschlagen."
            }
            print("[Backend] Error: unable to start backend runtime")
        }
    }

    private func waitForReady(port: Int) async -> Bool {
        let url = URL(string: "http://127.0.0.1:\(port)/health")!
        for _ in 0..<120 { // Try for up to 12 seconds
            do {
                let (_, response) = try await URLSession.shared.data(from: url)
                if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 {
                    return true
                }
            } catch {
                // Not ready yet
            }
            try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
        }
        return false
    }

    func stop() {
        crashRestartTask?.cancel()
        crashRestartTask = nil
        startupTask?.cancel()
        startupTask = nil
        process?.terminate()
        process = nil
        clearLogPipe()
        isReady = false
        crashRestartCount = 0
        print("[Backend] Stopped")
    }

    func restartForRecovery() {
        crashRestartTask?.cancel()
        crashRestartTask = nil
        startupTask?.cancel()
        startupTask = nil
        if process != nil {
            process?.terminate()
            process = nil
        }
        clearLogPipe()
        isReady = false
        crashRestartCount = 0
        start()
    }

    func startIfNeeded() {
        if process == nil, startupTask == nil {
            start()
        }
    }

    private func runtimeLaunches(backendJSPath: String) -> [RuntimeLaunch] {
        var launches: [RuntimeLaunch] = []

        if let nodePath = preferredSystemNodePath() {
            launches.append(RuntimeLaunch(
                executableURL: URL(fileURLWithPath: nodePath),
                arguments: [backendJSPath],
                label: "system node (\(nodePath))"
            ))
        }

        if let bundledNodePath = Bundle.main.path(forResource: "yaxi-backend-node", ofType: nil) {
            launches.append(RuntimeLaunch(
                executableURL: URL(fileURLWithPath: bundledNodePath),
                arguments: [backendJSPath],
                label: "bundled node"
            ))
        }

        if let wrapperPath = Bundle.main.path(forResource: "yaxi-backend", ofType: nil) {
            launches.append(RuntimeLaunch(
                executableURL: URL(fileURLWithPath: wrapperPath),
                arguments: [],
                label: "wrapper"
            ))
        }

        return launches
    }

    private func preferredSystemNodePath() -> String? {
        let fm = FileManager.default
        let knownPaths = [
            "/opt/homebrew/bin/node",
            "/usr/local/bin/node",
            "/usr/bin/node",
        ]
        for path in knownPaths where fm.isExecutableFile(atPath: path) {
            return path
        }

        let pathEnv = ProcessInfo.processInfo.environment["PATH"] ?? ""
        for dir in pathEnv.split(separator: ":") {
            let candidate = String(dir) + "/node"
            if fm.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }

    private func attachLogging(to proc: Process) {
        clearLogPipe()
        let pipe = Pipe()
        backendLogPipe = pipe
        proc.standardOutput = pipe
        proc.standardError = pipe

        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            guard let text = String(data: data, encoding: .utf8) else { return }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                print("[Backend] \(trimmed)")
                AppLogger.log(trimmed, category: "Backend")
            }
        }

        proc.terminationHandler = { [weak self] terminated in
            Task { @MainActor in
                guard let self else { return }
                let reason = terminated.terminationReason == .exit ? "exit" : "signal"
                let status = terminated.terminationStatus
                print("[Backend] Process exited (\(reason): \(status))")

                guard self.process === terminated else { return }
                self.process = nil
                self.isReady = false
                self.clearLogPipe()

                // Normaler Stop (status 0 oder vom User ausgelöst) → kein Neustart
                if terminated.terminationReason == .exit && status == 0 { return }

                // Crash → automatischer Neustart mit exponentiellem Backoff
                guard self.crashRestartCount < Self.maxCrashRestarts else {
                    self.lastStartupIssue = "Backend wiederholt abgestürzt – bitte App neu starten."
                    print("[Backend] Max crash restarts reached, giving up")
                    return
                }
                self.crashRestartCount += 1
                let delaySeconds = UInt64(pow(2.0, Double(self.crashRestartCount - 1))) // 1s, 2s, 4s
                print("[Backend] Crash detected, restarting in \(delaySeconds)s (attempt \(self.crashRestartCount)/\(Self.maxCrashRestarts))")
                self.lastStartupIssue = "Backend-Prozess abgestürzt (\(reason): \(status)), Neustart in \(delaySeconds)s…"

                self.crashRestartTask?.cancel()
                self.crashRestartTask = Task { @MainActor [weak self] in
                    try? await Task.sleep(nanoseconds: delaySeconds * 1_000_000_000)
                    guard !Task.isCancelled else { return }
                    self?.start()
                }
            }
        }
    }

    private func clearLogPipe() {
        backendLogPipe?.fileHandleForReading.readabilityHandler = nil
        backendLogPipe = nil
    }

    private func pickBackendPort() -> Int {
        // Isolate from other local tools (e.g. legacy yaxi-balancebar) by using a free ephemeral port.
        let socketFD = socket(AF_INET, SOCK_STREAM, 0)
        guard socketFD >= 0 else { return 8787 }
        defer { close(socketFD) }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(0).bigEndian
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))

        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(socketFD, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else { return 8787 }

        var boundAddress = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameResult = withUnsafeMutablePointer(to: &boundAddress) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(socketFD, $0, &length)
            }
        }
        guard nameResult == 0 else { return 8787 }

        let port = Int(UInt16(bigEndian: boundAddress.sin_port))
        return port > 0 ? port : 8787
    }

    private func terminateStaleBundledBackends(matching backendJSPath: String) {
        let cleaner = Process()
        cleaner.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        cleaner.arguments = ["-f", backendJSPath]
        do {
            try cleaner.run()
            cleaner.waitUntilExit()
            if cleaner.terminationStatus == 0 {
                print("[Backend] Cleared stale backend processes for current bundle")
            }
        } catch {
            // Non-fatal; continue startup even if cleanup command is unavailable.
        }
    }
}
