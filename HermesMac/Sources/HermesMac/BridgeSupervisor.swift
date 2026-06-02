import Foundation

final class BridgeSupervisor {
    static let shared = BridgeSupervisor()

    private var process: Process?

    private init() {}

    func startIfNeeded() {
        guard process == nil else { return }

        Task {
            guard !(await isBridgeAvailable()) else { return }

            guard let bridgeDirectory = Bundle.main.resourceURL?
                .appending(path: "hermes-bridge"),
                  FileManager.default.fileExists(atPath: bridgeDirectory.path) else {
                return
            }

            let pythonExecutable = Self.resolvePythonExecutable()
            let process = Process()
            process.executableURL = URL(fileURLWithPath: pythonExecutable)
            process.arguments = [
                "-m", "uvicorn", "main:app",
                "--host", "127.0.0.1",
                "--port", "8765",
                "--log-level", "info",
                "--no-access-log",
            ]
            process.currentDirectoryURL = bridgeDirectory
            process.environment = ProcessInfo.processInfo.environment.merging(
                [
                    "PYTHONDONTWRITEBYTECODE": "1",
                    "HERMES_BRIDGE_PYTHON": pythonExecutable,
                ],
                uniquingKeysWith: { current, _ in current }
            )
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice

            do {
                try process.run()
                self.process = process
            } catch {
                self.process = nil
            }
        }
    }

    func stopOwnedBridge() {
        guard let process, process.isRunning else { return }
        process.terminate()
        self.process = nil
    }

    private func isBridgeAvailable() async -> Bool {
        guard let url = URL(string: "http://127.0.0.1:8765/health") else { return false }
        var request = URLRequest(url: url)
        request.timeoutInterval = 1
        return (try? await URLSession.shared.data(for: request)) != nil
    }

    private static func resolvePythonExecutable() -> String {
        let env = ProcessInfo.processInfo.environment
        if let configured = env["HERMES_BRIDGE_PYTHON"], !configured.isEmpty {
            return configured
        }

        let fileManager = FileManager.default
        let candidates = [
            "/opt/homebrew/bin/python3.11",
            "/opt/homebrew/bin/python3",
            "/usr/local/bin/python3",
            "/usr/bin/python3",
        ]

        if let match = candidates.first(where: { fileManager.isExecutableFile(atPath: $0) }) {
            return match
        }

        return "/usr/bin/python3"
    }
}
