import Foundation

enum Shell {
    static let commonPath = [
        "/opt/homebrew/bin",
        "/opt/homebrew/sbin",
        "/usr/local/bin",
        "/usr/local/sbin",
        "/usr/bin",
        "/bin",
        "/usr/sbin",
        "/sbin",
        "\(NSHomeDirectory())/.local/bin",
        "\(NSHomeDirectory())/.npm-global/bin"
    ]

    static func toolPath(_ base: String? = ProcessInfo.processInfo.environment["PATH"]) -> String {
        var parts = commonPath
        parts.append(contentsOf: (base ?? "").split(separator: ":").map(String.init))
        var seen = Set<String>()
        return parts.filter { !$0.isEmpty && seen.insert($0).inserted }.joined(separator: ":")
    }

    static func environment(extra: [String: String] = [:]) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = toolPath(env["PATH"])
        for (key, value) in extra {
            env[key] = value
        }
        return env
    }

    static func findExecutable(_ command: String) -> String {
        let value = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return "" }
        if value.hasPrefix("/") || value.contains("/") {
            return FileManager.default.isExecutableFile(atPath: value) ? value : ""
        }
        for directory in toolPath().split(separator: ":").map(String.init) {
            let candidate = "\(directory)/\(value)"
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return ""
    }

    static func run(_ command: String, arguments: [String] = [], timeout: TimeInterval = 8) async -> (code: Int32, output: String) {
        await withCheckedContinuation { continuation in
            let process = Process()
            let pipe = Pipe()
            process.executableURL = URL(fileURLWithPath: command)
            process.arguments = arguments
            process.environment = environment()
            process.standardOutput = pipe
            process.standardError = pipe

            var finished = false
            let finish: (Int32) -> Void = { code in
                guard !finished else { return }
                finished = true
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let text = String(data: data, encoding: .utf8) ?? ""
                continuation.resume(returning: (code, text.trimmingCharacters(in: .whitespacesAndNewlines)))
            }

            process.terminationHandler = { proc in
                finish(proc.terminationStatus)
            }

            do {
                try process.run()
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                    if process.isRunning {
                        process.terminate()
                    }
                }
            } catch {
                continuation.resume(returning: (1, error.localizedDescription))
            }
        }
    }

    static func runBash(_ script: String, onOutput: @escaping (String) -> Void = { _ in }) async -> (code: Int32, output: String) {
        await withCheckedContinuation { continuation in
            let process = Process()
            let stdout = Pipe()
            let stderr = Pipe()
            let lock = NSLock()
            var output = ""

            func append(_ data: Data) {
                guard let text = String(data: data, encoding: .utf8), !text.isEmpty else { return }
                lock.lock()
                output += text
                lock.unlock()
                onOutput(text)
            }

            stdout.fileHandleForReading.readabilityHandler = { handle in append(handle.availableData) }
            stderr.fileHandleForReading.readabilityHandler = { handle in append(handle.availableData) }

            process.executableURL = URL(fileURLWithPath: "/bin/bash")
            process.arguments = ["-lc", script]
            process.currentDirectoryURL = URL(fileURLWithPath: NSHomeDirectory())
            process.environment = environment()
            process.standardOutput = stdout
            process.standardError = stderr
            process.terminationHandler = { proc in
                stdout.fileHandleForReading.readabilityHandler = nil
                stderr.fileHandleForReading.readabilityHandler = nil
                continuation.resume(returning: (proc.terminationStatus, output.trimmingCharacters(in: .whitespacesAndNewlines)))
            }

            do {
                try process.run()
            } catch {
                continuation.resume(returning: (1, error.localizedDescription))
            }
        }
    }
}
