import Foundation

/// Live Qwen ASR session: connect on PTT start, append PCM while recording, finalize on stop.
final class QwenStreamingSTTSession: @unchecked Sendable {
    private let config: ServerConfig
    private var task: URLSessionWebSocketTask?
    private var urlSession: URLSession?
    private var transcript = ""
    private var onPartial: ((String) -> Void)?
    private var finished = false
    private var chunkIndex = 0
    private let lock = NSLock()

    init(config: ServerConfig) {
        self.config = config
    }

    func start(onPartial: @escaping (String) -> Void) async throws {
        let model = config.qwenAsrModel.trimmingCharacters(in: .whitespaces)
        guard !model.isEmpty else { throw STTError.missingAPIKey("QWEN_ASR_MODEL") }
        let apiKey = config.qwenAsrApiKey.trimmingCharacters(in: .whitespaces)
        guard !apiKey.isEmpty else { throw STTError.missingAPIKey("QWEN_ASR_API_KEY") }
        let baseURL = config.qwenAsrRealtimeBaseUrl.trimmingCharacters(in: .whitespaces)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !baseURL.isEmpty else { throw STTError.missingAPIKey("QWEN_ASR_REALTIME_BASE_URL") }

        self.onPartial = onPartial
        let sampleRate = max(8000, config.qwenAsrSampleRate)
        let wsURL = URL(string: "\(baseURL)?model=\(model.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? model)")!

        var wsRequest = URLRequest(url: wsURL)
        wsRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        wsRequest.setValue("realtime=v1", forHTTPHeaderField: "OpenAI-Beta")

        let session = URLSession(configuration: .default)
        let wsTask = session.webSocketTask(with: wsRequest)
        urlSession = session
        task = wsTask
        wsTask.resume()

        try await Task.sleep(for: .milliseconds(300))

        var sessionConfig: [String: Any] = [
            "modalities": ["text"],
            "input_audio_format": "pcm",
            "sample_rate": sampleRate,
            "input_audio_transcription": [:] as [String: Any],
            "turn_detection": NSNull(),
        ]
        let language = config.qwenAsrLanguage.trimmingCharacters(in: .whitespaces)
        if !language.isEmpty {
            sessionConfig["input_audio_transcription"] = ["language": language]
        }
        let prompt = buildPrompt()
        if !prompt.isEmpty {
            sessionConfig["instructions"] = prompt
        }

        try sendJSON([
            "event_id": "event_\(Int(Date().timeIntervalSince1970 * 1000))",
            "type": "session.update",
            "session": sessionConfig,
        ])

        receiveLoop()
    }

    func append(pcm16: Data) {
        guard !pcm16.isEmpty, let task else { return }
        lock.lock()
        let index = chunkIndex
        chunkIndex += 1
        lock.unlock()

        let payload: [String: Any] = [
            "event_id": "event_\(Int(Date().timeIntervalSince1970 * 1000))_\(index)",
            "type": "input_audio_buffer.append",
            "audio": pcm16.base64EncodedString(),
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let text = String(data: data, encoding: .utf8) else { return }
        task.send(.string(text)) { _ in }
    }

    func finish() async throws -> String {
        guard let task else { throw STTError.websocketError("session_not_started") }

        try sendJSON([
            "event_id": "event_\(Int(Date().timeIntervalSince1970 * 1000))_commit",
            "type": "input_audio_buffer.commit",
        ])
        try sendJSON([
            "event_id": "event_\(Int(Date().timeIntervalSince1970 * 1000))_finish",
            "type": "session.finish",
        ])

        let deadline = Date().addingTimeInterval(45)
        while Date() < deadline {
            lock.lock()
            let done = finished
            let text = transcript
            lock.unlock()
            if done { return text }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw STTError.timedOut
    }

    func cancel() {
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        urlSession?.invalidateAndCancel()
        urlSession = nil
    }

    // MARK: - Private

    private func buildPrompt() -> String {
        var parts = [
            "请将音频准确转写为中文文本。",
            "只输出转写结果，不要解释。",
        ]
        let language = config.qwenAsrLanguage.trimmingCharacters(in: .whitespaces)
        if !language.isEmpty {
            parts.append("语言提示：\(language)")
        }
        let extraPrompt = config.qwenAsrPrompt.trimmingCharacters(in: .whitespaces)
        if !extraPrompt.isEmpty {
            parts.append(extraPrompt)
        }
        return parts.joined(separator: "\n")
    }

    private func sendJSON(_ dict: [String: Any]) throws {
        guard let task else { throw STTError.websocketError("session_not_started") }
        guard let data = try? JSONSerialization.data(withJSONObject: dict),
              let text = String(data: data, encoding: .utf8) else {
            throw STTError.websocketError("encode_failed")
        }
        let sem = DispatchSemaphore(value: 0)
        var sendError: Error?
        task.send(.string(text)) { error in
            sendError = error
            sem.signal()
        }
        sem.wait()
        if let sendError { throw STTError.websocketError(sendError.localizedDescription) }
    }

    private func receiveLoop() {
        task?.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let message):
                if case .string(let text) = message,
                   let event = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] {
                    let extracted = STTService.extractQwenRealtimeTranscript(event)
                    if !extracted.isEmpty {
                        self.lock.lock()
                        self.transcript = extracted
                        self.lock.unlock()
                        self.onPartial?(extracted)
                    }
                    if (event["type"] as? String) == "session.finished" {
                        self.lock.lock()
                        self.finished = true
                        if !extracted.isEmpty {
                            self.transcript = extracted
                        }
                        self.lock.unlock()
                        return
                    }
                }
                self.receiveLoop()
            case .failure:
                self.lock.lock()
                self.finished = true
                self.lock.unlock()
            }
        }
    }
}
