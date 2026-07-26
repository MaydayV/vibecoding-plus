import Foundation

// MARK: - Types

/// Protocol for a CLI session that can be observed by a delegate.
protocol CLISession: AnyObject {
    var isRunning: Bool { get }
    var delegate: CLISessionDelegate? { get set }
    var process: Process? { get set }
    var timeoutTimer: DispatchSourceTimer? { get set }
    func stop()
    func cleanup()
}

/// Result returned when a CLI session completes.
struct CLIResult {
    var success: Bool
    var sessionId: String?
    var text: String
    var exitCode: Int32?
}

/// Delegate callbacks for CLI session events.
protocol CLISessionDelegate: AnyObject {
    func cliSession(_ session: CLISession, didReceiveText text: String, role: String)
    func cliSession(_ session: CLISession, didUpdateStatus status: String)
    func cliSession(_ session: CLISession, didComplete result: CLIResult)
    func cliSession(_ session: CLISession, didEncounterError error: String)
}

// MARK: - Codex CLI Session

/// Manages a single Codex CLI subprocess (`codex exec --json`).
/// Port of Node.js `codex-session.mjs`.
final class CodexSessionManager: CLISession {

    weak var delegate: CLISessionDelegate?

    private let stateLock = NSLock()
    private var _isRunning = false
    private(set) var isRunning: Bool {
        get {
            stateLock.lock()
            defer { stateLock.unlock() }
            return _isRunning
        }
        set {
            stateLock.lock()
            _isRunning = newValue
            stateLock.unlock()
        }
    }
    private(set) var threadId = ""

    var process: Process?
    var timeoutTimer: DispatchSourceTimer?

    // MARK: Lifecycle

    /// Start a Codex CLI session with the given prompt.
    func start(prompt: String, config: ServerConfig) throws {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw CLIError.emptyPrompt
        }
        guard !isRunning else {
            throw CLIError.sessionBusy
        }

        isRunning = true
        notifyStatus("Running Codex...")

        let executable = findExecutable(config.codexCommand)
        let cwd = config.codexCwd.isEmpty
            ? FileManager.default.currentDirectoryPath
            : config.codexCwd

        var arguments: [String] = []
        if !cwd.isEmpty {
            arguments += ["-C", cwd]
        }

        if !threadId.isEmpty {
            arguments += ["exec", "resume", threadId, "--json", trimmed]
        } else {
            arguments += ["exec", "--json", trimmed]
        }

        if config.codexSkipGitRepoCheck {
            arguments.append("--skip-git-repo-check")
        }

        let proc = try spawnProcess(
            executable: executable,
            arguments: arguments,
            cwd: cwd,
            timeoutSec: config.cliTimeoutSec
        )
        self.process = proc

        var lastAssistantText = ""

        setupStdout(proc) { [weak self] event in
            guard let self else { return }

            if let type = event["type"] as? String {
                switch type {
                case "thread.started":
                    if let tid = event["thread_id"] as? String, !tid.isEmpty {
                        self.threadId = tid
                        self.notifyStatus("Codex running")
                    }

                case "item.completed":
                    if let item = event["item"] as? [String: Any],
                       item["type"] as? String == "agent_message",
                       let text = item["text"] as? String {
                        lastAssistantText = text.trimmingCharacters(in: .whitespacesAndNewlines)
                        self.delegate?.cliSession(self, didReceiveText: lastAssistantText, role: "assistant")
                        self.notifyStatus("Codex replied")
                    }

                case "turn.completed":
                    self.notifyStatus("Codex idle")

                default:
                    break
                }
            }
        } fallback: { [weak self] rawLine in
            guard let self else { return }
            self.delegate?.cliSession(self, didReceiveText: rawLine, role: "log")
        }

        let stderrAccumulator = setupStderr(proc)

        proc.terminationHandler = { [weak self] process in
            guard let self else { return }
            DispatchQueue.main.async {
                self.cleanup()

                if process.terminationStatus == 0 {
                    self.notifyStatus("Codex idle")
                    self.delegate?.cliSession(self, didComplete: CLIResult(
                        success: true,
                        sessionId: self.threadId,
                        text: lastAssistantText,
                        exitCode: 0
                    ))
                } else {
                    let message = stderrAccumulator.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    let errorText = message.isEmpty
                        ? "Codex exited with code \(process.terminationStatus)"
                        : message
                    self.notifyStatus(errorText)
                    self.delegate?.cliSession(self, didEncounterError: errorText)
                    self.delegate?.cliSession(self, didComplete: CLIResult(
                        success: false,
                        sessionId: self.threadId,
                        text: lastAssistantText,
                        exitCode: process.terminationStatus
                    ))
                }
            }
        }
    }

    /// Stop the running Codex process gracefully.
    func stop() {
        terminateGracefully()
    }

    // MARK: - Private

    private func notifyStatus(_ status: String) {
        delegate?.cliSession(self, didUpdateStatus: status)
    }

    func cleanup() {
        clearStderrHandler()
        isRunning = false
        timeoutTimer?.cancel()
        timeoutTimer = nil
        process = nil
    }
}

// MARK: - Claude CLI Session

/// Manages a single Claude Code CLI subprocess (`claude -p --output-format stream-json`).
/// Port of Node.js `claude-session.mjs`.
final class ClaudeSessionManager: CLISession {

    weak var delegate: CLISessionDelegate?

    private let stateLock = NSLock()
    private var _isRunning = false
    private(set) var isRunning: Bool {
        get {
            stateLock.lock()
            defer { stateLock.unlock() }
            return _isRunning
        }
        set {
            stateLock.lock()
            _isRunning = newValue
            stateLock.unlock()
        }
    }
    private(set) var sessionId: String?
    private var lastCwd: String?

    var process: Process?
    var timeoutTimer: DispatchSourceTimer?

    // MARK: Lifecycle

    /// Start a Claude CLI session with the given prompt.
    /// - Parameters:
    ///   - prompt: The text prompt to send.
    ///   - config: Server configuration.
    ///   - continuationId: If non-nil, resumes the given session via `--continue`.
    func start(prompt: String, config: ServerConfig, continuationId: String? = nil) throws {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw CLIError.emptyPrompt
        }
        guard !isRunning else {
            throw CLIError.sessionBusy
        }

        isRunning = true
        notifyStatus("Running Claude...")

        let cwd = config.claudeCwd.isEmpty
            ? FileManager.default.currentDirectoryPath
            : config.claudeCwd

        if let existing = sessionId, !existing.isEmpty,
           let last = lastCwd, last != cwd {
            sessionId = nil
        }
        lastCwd = cwd

        let executable = findExecutable(config.claudeCommand)
        var arguments = ["--output-format", "stream-json", "--verbose"]

        if config.claudeDangerouslySkipPermissions {
            arguments.append("--dangerously-skip-permissions")
        }

        if config.claudeMaxTurns > 0 {
            arguments += ["--max-turns", String(config.claudeMaxTurns)]
        }

        let resumeId = continuationId ?? sessionId
        if let sid = resumeId, !sid.isEmpty {
            arguments += ["--resume", sid]
        }

        arguments += ["-p", trimmed]

        let proc = try spawnProcess(
            executable: executable,
            arguments: arguments,
            cwd: cwd,
            timeoutSec: config.cliTimeoutSec
        )
        self.process = proc

        var lastAssistantText = ""
        var lastResultMessage = ""
        var resultHandled = false
        var sawErrorResult = false

        setupStdout(proc) { [weak self] event in
            guard let self else { return }
            guard let type = event["type"] as? String else { return }

            switch type {
            case "assistant":
                // Extract text from content blocks
                if let message = event["message"] as? [String: Any],
                   let content = message["content"] as? [[String: Any]] {
                    for block in content {
                        if block["type"] as? String == "text",
                           let text = block["text"] as? String {
                            lastAssistantText += text
                        }
                    }
                    if !lastAssistantText.isEmpty {
                        self.delegate?.cliSession(self, didReceiveText: lastAssistantText, role: "assistant")
                        self.notifyStatus("Claude replying...")
                    }
                }

            case "stream_event":
                // Streaming text delta (verbose mode)
                if let streamEvent = event["event"] as? [String: Any],
                   streamEvent["type"] as? String == "content_block_delta",
                   let delta = streamEvent["delta"] as? [String: Any],
                   delta["type"] as? String == "text_delta",
                   let text = delta["text"] as? String {
                    lastAssistantText += text
                    self.delegate?.cliSession(self, didReceiveText: lastAssistantText, role: "assistant")
                    self.notifyStatus("Claude replying...")
                }

            case "result":
                if let sid = event["session_id"] as? String {
                    self.sessionId = sid
                }
                sawErrorResult = (event["is_error"] as? Bool) ?? false
                lastResultMessage = (event["result"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

                // Fallback: result text when no streaming content was captured
                if lastAssistantText.isEmpty && !lastResultMessage.isEmpty {
                    lastAssistantText = lastResultMessage
                }
                resultHandled = true

                if sawErrorResult {
                    let message = !lastResultMessage.isEmpty ? lastResultMessage
                        : !lastAssistantText.isEmpty ? lastAssistantText
                        : "Claude returned an error"
                    self.notifyStatus(message)
                    self.delegate?.cliSession(self, didEncounterError: message)
                } else {
                    if !lastAssistantText.isEmpty {
                        self.delegate?.cliSession(self, didReceiveText: lastAssistantText, role: "assistant")
                    }
                    self.notifyStatus("Claude idle")
                }

            case "system":
                if let subtype = event["subtype"] as? String {
                    let msg: String
                    if subtype == "api_retry",
                       let attempt = event["attempt"],
                       let maxRetries = event["max_retries"] {
                        msg = "retry: attempt \(attempt)/\(maxRetries) (\(event["error"] ?? "unknown"))"
                    } else {
                        msg = "system: \(subtype)"
                    }
                    self.delegate?.cliSession(self, didReceiveText: msg, role: "log")
                }

            default:
                break
            }
        } fallback: { [weak self] rawLine in
            guard let self else { return }
            self.delegate?.cliSession(self, didReceiveText: rawLine, role: "log")
        }

        let stderrAccumulator = setupStderr(proc)

        proc.terminationHandler = { [weak self] process in
            guard let self else { return }
            DispatchQueue.main.async {
                self.cleanup()

                let exitCode = process.terminationStatus
                if exitCode == 0 {
                    if !resultHandled {
                        self.notifyStatus("Claude idle")
                    }
                    self.delegate?.cliSession(self, didComplete: CLIResult(
                        success: true,
                        sessionId: self.sessionId,
                        text: lastAssistantText,
                        exitCode: exitCode
                    ))
                } else {
                    let message = !lastResultMessage.isEmpty ? lastResultMessage
                        : !lastAssistantText.isEmpty ? lastAssistantText
                        : stderrAccumulator.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    let errorText = message.isEmpty
                        ? "Claude exited with code \(exitCode)"
                        : message
                    self.notifyStatus(errorText)
                    self.delegate?.cliSession(self, didEncounterError: errorText)
                    self.delegate?.cliSession(self, didComplete: CLIResult(
                        success: false,
                        sessionId: self.sessionId,
                        text: lastAssistantText,
                        exitCode: exitCode
                    ))
                }
            }
        }
    }

    /// Stop the running Claude process gracefully.
    func stop() {
        terminateGracefully()
    }

    // MARK: - Private

    private func notifyStatus(_ status: String) {
        delegate?.cliSession(self, didUpdateStatus: status)
    }

    func cleanup() {
        clearStderrHandler()
        isRunning = false
        timeoutTimer?.cancel()
        timeoutTimer = nil
        process = nil
    }
}

// MARK: - Shared Process Utilities

/// Thread-safe container for accumulating stderr text.
private final class StderrAccumulator {
    private let lock = NSLock()
    private var buffer = ""

    var text: String {
        lock.lock()
        defer { lock.unlock() }
        return buffer
    }

    func append(_ string: String) {
        lock.lock()
        buffer += string
        lock.unlock()
    }
}

private extension CLISession where Self: AnyObject {

    /// Shared helper: spawn a `Process` with the given parameters and start the timeout timer.
    func spawnProcess(
        executable: String,
        arguments: [String],
        cwd: String,
        timeoutSec: Double
    ) throws -> Process {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: executable)
        proc.arguments = arguments

        if !cwd.isEmpty {
            proc.currentDirectoryURL = URL(fileURLWithPath: cwd)
        }

        // Enhance PATH for common tool locations
        var env = ProcessInfo.processInfo.environment
        let toolPaths = [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            NSHomeDirectory() + "/.local/bin",
            NSHomeDirectory() + "/.npm-global/bin",
            NSHomeDirectory() + "/.bun/bin",
        ]
        let currentPath = env["PATH"] ?? "/usr/bin:/bin"
        let enhanced = (toolPaths + [currentPath]).joined(separator: ":")
        env["PATH"] = enhanced
        proc.environment = env

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        proc.standardOutput = stdoutPipe
        proc.standardError = stderrPipe
        proc.standardInput = FileHandle.nullDevice

        try proc.run()

        // Store pipe references so they stay alive (avoid premature deallocation)
        objc_setAssociatedObject(proc, "stdoutPipe", stdoutPipe, .OBJC_ASSOCIATION_RETAIN)
        objc_setAssociatedObject(proc, "stderrPipe", stderrPipe, .OBJC_ASSOCIATION_RETAIN)

        // Timeout
        let timeoutMs = timeoutSec > 0 ? timeoutSec : 300
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .userInitiated))
        timer.schedule(deadline: .now() + timeoutMs)
        timer.setEventHandler { [weak proc] in
            proc?.terminate() // SIGTERM
        }
        timer.resume()
        self.timeoutTimer = timer

        return proc
    }

    /// Set up stdout line-by-line JSON parsing.
    func setupStdout(
        _ proc: Process,
        onEvent: @escaping ([String: Any]) -> Void,
        fallback: @escaping (String) -> Void
    ) {
        // `proc.standardOutput` was assigned a `Pipe`, so it always reads back as a
        // `Pipe`, never a `FileHandle` — fetch the real read handle from the pipe we
        // stashed via objc_setAssociatedObject in spawnProcess.
        guard let pipe = objc_getAssociatedObject(proc, "stdoutPipe") as? Pipe else { return }
        let handle = pipe.fileHandleForReading

        func handleLine(_ lineData: Data) {
            guard let line = String(data: lineData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !line.isEmpty else { return }

            if let jsonData = line.data(using: .utf8),
               let event = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] {
                DispatchQueue.main.async { onEvent(event) }
            } else {
                DispatchQueue.main.async { fallback(line) }
            }
        }

        // Use a background queue for reading to avoid blocking
        DispatchQueue.global(qos: .userInitiated).async {
            let newline = UInt8(ascii: "\n")
            var residual = Data()

            while true {
                let data = handle.availableData
                if data.isEmpty { break } // EOF

                var chunk = residual
                chunk.append(data)

                // Split the whole chunk on '\n' in a single forward pass (tracking a
                // scan-start offset) instead of re-scanning from byte 0 and shifting
                // the buffer for every line, which was O(n^2) on chatty output.
                var lineStart = chunk.startIndex
                while let newlineIndex = chunk[lineStart...].firstIndex(of: newline) {
                    handleLine(chunk[lineStart..<newlineIndex])
                    lineStart = chunk.index(after: newlineIndex)
                }
                residual = Data(chunk[lineStart...])
            }

            // Flush remaining data
            if !residual.isEmpty {
                handleLine(residual)
            }
        }
    }

    /// Set up stderr capture, returning the accumulator for reading the final text.
    func setupStderr(_ proc: Process) -> StderrAccumulator {
        let accumulator = StderrAccumulator()
        guard let pipe = objc_getAssociatedObject(proc, "stderrPipe") as? Pipe else { return accumulator }
        let handle = pipe.fileHandleForReading

        handle.readabilityHandler = { [weak self] fileHandle in
            let data = fileHandle.availableData
            guard !data.isEmpty else {
                // EOF: detach so the dispatch source + FileHandle backing this closure
                // don't leak past this CLI invocation.
                fileHandle.readabilityHandler = nil
                return
            }
            guard let text = String(data: data, encoding: .utf8) else { return }

            accumulator.append(text)

            for line in text.components(separatedBy: .newlines) {
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty, let self {
                    DispatchQueue.main.async {
                        self.delegate?.cliSession(self, didReceiveText: "stderr: \(trimmed)", role: "stderr")
                    }
                }
            }
        }

        return accumulator
    }

    /// Defensive fallback for the EOF self-clear in `setupStderr`: detach the stderr
    /// readabilityHandler if it's somehow still attached when the session is torn
    /// down (e.g. the process was killed before its pipe reported EOF). Only clears
    /// the closure reference — never closes the handle — so it can't race a
    /// use-after-free or truncate stderr that hasn't been delivered yet.
    func clearStderrHandler() {
        guard let proc = process,
              let pipe = objc_getAssociatedObject(proc, "stderrPipe") as? Pipe else { return }
        pipe.fileHandleForReading.readabilityHandler = nil
    }

    /// Send SIGTERM, then SIGINT after 3 seconds if still running.
    func terminateGracefully() {
        guard let proc = process, proc.isRunning else {
            cleanup()
            return
        }
        proc.terminate() // SIGTERM

        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 3) { [weak proc, weak self] in
            guard let proc, proc.isRunning else { return }
            proc.interrupt() // SIGINT
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                self?.cleanup()
            }
        }
    }
}

// MARK: - Executable Resolution

/// Search for a CLI executable in common locations, falling back to the bare command name.
private func findExecutable(_ command: String) -> String {
    // If the command is already an absolute path and exists, use it directly
    if command.hasPrefix("/") && FileManager.default.isExecutableFile(atPath: command) {
        return command
    }

    let searchPaths = [
        Bundle.main.resourcePath.map { ($0 as NSString).appendingPathComponent("bin") },
        "/opt/homebrew/bin",
        "/usr/local/bin",
        (NSHomeDirectory() as NSString).appendingPathComponent(".local/bin"),
        (NSHomeDirectory() as NSString).appendingPathComponent(".npm-global/bin"),
        (NSHomeDirectory() as NSString).appendingPathComponent(".bun/bin"),
        "/usr/bin",
    ].compactMap { $0 }

    for directory in searchPaths {
        let candidate = (directory as NSString).appendingPathComponent(command)
        if FileManager.default.isExecutableFile(atPath: candidate) {
            return candidate
        }
    }

    // Fall back to bare name; Process will search PATH
    return command
}

// MARK: - Errors

enum CLIError: LocalizedError {
    case emptyPrompt
    case sessionBusy

    var errorDescription: String? {
        switch self {
        case .emptyPrompt: return "Prompt is empty"
        case .sessionBusy: return "CLI session is busy"
        }
    }
}
