import Foundation

// MARK: - STT Errors

enum STTError: LocalizedError {
    case noProviderConfigured
    case missingAPIKey(String)
    case requestFailed(String)
    case httpError(statusCode: Int, body: String)
    case apiError(String)
    case emptyTranscript
    case processFailed(String)
    case timedOut
    case websocketError(String)

    var errorDescription: String? {
        switch self {
        case .noProviderConfigured:
            "No STT provider is configured. Set STT_PROVIDER or provider-specific keys."
        case .missingAPIKey(let name):
            "\(name) is not set"
        case .requestFailed(let message):
            "STT request failed: \(message)"
        case .httpError(let code, let body):
            "STT HTTP error \(code): \(body)"
        case .apiError(let message):
            "STT API error: \(message)"
        case .emptyTranscript:
            "STT returned empty transcript"
        case .processFailed(let message):
            "whisper.cpp failed: \(message)"
        case .timedOut:
            "STT request timed out"
        case .websocketError(let message):
            "Qwen ASR websocket error: \(message)"
        }
    }
}

// MARK: - STT Service

struct STTService {
    let config: ServerConfig

    private static let requestTimeout: TimeInterval = 45

    // MARK: - Main Entry Point

    /// Transcribe PCM16 mono audio data (16kHz signed 16-bit little-endian).
    func transcribe(pcm16Data: Data) async throws -> String {
        guard !pcm16Data.isEmpty else { return "" }

        let wavData = pcm16ToWav(pcm16Data)

        // Save debug WAV if enabled
        if ProcessInfo.processInfo.environment["SAVE_DEBUG_WAV"] == "1" {
            let tmpDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("vibecoding-stt", isDirectory: true)
            try? FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
            let debugURL = tmpDir.appendingPathComponent("segment-\(Int(Date().timeIntervalSince1970 * 1000)).wav")
            try? wavData.write(to: debugURL)
        }

        if let mock = ProcessInfo.processInfo.environment["MOCK_TRANSCRIPT"], !mock.isEmpty {
            return mock
        }

        let provider = resolveProvider()
        switch provider {
        case .openai:
            return try await transcribeOpenAI(wavData)
        case .volcengine:
            return try await transcribeVolcengine(wavData)
        case .whisperCpp:
            return try await transcribeWhisperCpp(wavData)
        case .qwenAsr:
            return try await transcribeQwenAsr(pcm16Data: pcm16Data)
        }
    }

    // MARK: - Provider Resolution

    private func resolveProvider() -> STTProvider {
        // Explicit config takes priority
        if let explicit = ProcessInfo.processInfo.environment["STT_PROVIDER"],
           let provider = STTProvider(rawValue: explicit.lowercased()) {
            return provider
        }
        // Infer from available keys
        if !config.qwenAsrApiKey.trimmingCharacters(in: .whitespaces).isEmpty {
            return .qwenAsr
        }
        if !config.openaiApiKey.trimmingCharacters(in: .whitespaces).isEmpty {
            return .openai
        }
        if !config.volcengineAppKey.trimmingCharacters(in: .whitespaces).isEmpty
            && !config.volcengineAccessKey.trimmingCharacters(in: .whitespaces).isEmpty {
            return .volcengine
        }
        // Default fallback
        return .volcengine
    }

    // MARK: - OpenAI Whisper

    private func transcribeOpenAI(_ wavData: Data) async throws -> String {
        let apiKey = config.openaiApiKey.trimmingCharacters(in: .whitespaces)
        guard !apiKey.isEmpty else {
            throw STTError.missingAPIKey("OPENAI_API_KEY")
        }

        let model = config.openaiModel.trimmingCharacters(in: .whitespacesAndNewlines)
        // Base URL precedence: explicit config field > env var > official OpenAI endpoint.
        let configuredBase = config.openaiBaseUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        let envBase = ProcessInfo.processInfo.environment["OPENAI_BASE_URL"]
            ?? ProcessInfo.processInfo.environment["OPENAI_API_BASE"]
        let baseURL = (configuredBase.isEmpty ? (envBase ?? "https://api.openai.com/v1") : configuredBase)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))

        let url = URL(string: "\(baseURL)/audio/transcriptions")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = Self.requestTimeout

        let boundary = "Boundary-\(UUID().uuidString)"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var body = Data()
        // model field
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"model\"\r\n\r\n".data(using: .utf8)!)
        body.append("\(model)\r\n".data(using: .utf8)!)
        // task field
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"task\"\r\n\r\n".data(using: .utf8)!)
        body.append("transcribe\r\n".data(using: .utf8)!)
        // optional language field
        let openaiLanguage = (ProcessInfo.processInfo.environment["OPENAI_LANGUAGE"] ?? "").trimmingCharacters(in: .whitespaces)
        if !openaiLanguage.isEmpty {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"language\"\r\n\r\n".data(using: .utf8)!)
            body.append("\(openaiLanguage)\r\n".data(using: .utf8)!)
        }
        // file field
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"segment.wav\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: audio/wav\r\n\r\n".data(using: .utf8)!)
        body.append(wavData)
        body.append("\r\n".data(using: .utf8)!)
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)

        request.httpBody = body

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw STTError.requestFailed("Invalid response")
        }
        guard http.statusCode == 200 else {
            let text = String(data: data, encoding: .utf8) ?? ""
            throw STTError.httpError(statusCode: http.statusCode, body: text)
        }

        // Parse JSON response: {"text": "..."}
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let text = (json["text"] as? String) ?? (json["transcription"] as? String) ?? (json["result"] as? String) ?? ""
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        throw STTError.emptyTranscript
    }

    // MARK: - Volcengine

    private func transcribeVolcengine(_ wavData: Data) async throws -> String {
        let appKey = config.volcengineAppKey.trimmingCharacters(in: .whitespaces)
        let accessKey = config.volcengineAccessKey.trimmingCharacters(in: .whitespaces)
        guard !appKey.isEmpty else {
            throw STTError.missingAPIKey("VOLCENGINE_APP_KEY")
        }
        guard !accessKey.isEmpty else {
            throw STTError.missingAPIKey("VOLCENGINE_ACCESS_KEY")
        }

        let url = URL(string: "https://openspeech.bytedance.com/api/v3/auc/bigmodel/recognize/flash")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = Self.requestTimeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(appKey, forHTTPHeaderField: "X-Api-App-Key")
        request.setValue(accessKey, forHTTPHeaderField: "X-Api-Access-Key")
        let resourceId = ProcessInfo.processInfo.environment["VOLCENGINE_RESOURCE_ID"] ?? "volc.bigasr.auc_turbo"
        request.setValue(resourceId, forHTTPHeaderField: "X-Api-Resource-Id")
        request.setValue(UUID().uuidString.lowercased(), forHTTPHeaderField: "X-Api-Request-Id")
        request.setValue("-1", forHTTPHeaderField: "X-Api-Sequence")

        let language = ProcessInfo.processInfo.environment["VOLCENGINE_LANGUAGE"] ?? "zh-CN"
        var audioPayload: [String: Any] = [
            "data": wavData.base64EncodedString(),
            "format": "wav",
            "language": language
        ]

        let payload: [String: Any] = [
            "user": ["uid": appKey],
            "audio": audioPayload,
            "request": [
                "model_name": "bigmodel",
                "enable_itn": true,
                "enable_punc": true,
                "show_utterances": false
            ] as [String: Any]
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw STTError.requestFailed("Invalid response")
        }

        let statusCode = http.value(forHTTPHeaderField: "X-Api-Status-Code") ?? ""
        let statusMessage = http.value(forHTTPHeaderField: "X-Api-Message") ?? ""
        let logId = http.value(forHTTPHeaderField: "X-Tt-Logid") ?? ""

        guard http.statusCode == 200, statusCode == "20000000" else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw STTError.apiError(
                "Volcengine: http=\(http.statusCode) api=\(statusCode) message=\(statusMessage) logid=\(logId) body=\(body)"
            )
        }

        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let result = json["result"] as? [String: Any],
           let text = result["text"] as? String {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        throw STTError.emptyTranscript
    }

    // MARK: - whisper.cpp

    private func transcribeWhisperCpp(_ wavData: Data) async throws -> String {
        let modelPath = config.whisperCppModelPath.trimmingCharacters(in: .whitespaces)
        guard !modelPath.isEmpty else {
            throw STTError.missingAPIKey("WHISPER_CPP_MODEL_PATH")
        }

        let command = config.whisperCppCommand.trimmingCharacters(in: .whitespaces).isEmpty
            ? "whisper-cli"
            : config.whisperCppCommand.trimmingCharacters(in: .whitespaces)
        let language = config.whisperCppLanguage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "zh"
            : config.whisperCppLanguage.trimmingCharacters(in: .whitespacesAndNewlines)
        let threads = max(1, config.whisperCppThreads)

        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("vibecoding-stt", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)

        let token = "\(Int(Date.timeIntervalSinceReferenceDate))-\(UUID().uuidString)"
        let wavURL = tmpDir.appendingPathComponent("whisper-input-\(token).wav")
        let outputPrefix = tmpDir.appendingPathComponent("whisper-output-\(token)")
        let outputTxtURL = tmpDir.appendingPathComponent("whisper-output-\(token).txt")

        defer {
            try? FileManager.default.removeItem(at: wavURL)
            try? FileManager.default.removeItem(at: outputTxtURL)
            try? FileManager.default.removeItem(at: tmpDir.appendingPathComponent("whisper-output-\(token).srt"))
            try? FileManager.default.removeItem(at: tmpDir.appendingPathComponent("whisper-output-\(token).vtt"))
            try? FileManager.default.removeItem(at: tmpDir.appendingPathComponent("whisper-output-\(token).json"))
        }

        try wavData.write(to: wavURL)

        var args = [
            "-m", modelPath,
            "-f", wavURL.path,
            "-l", language,
            "-t", "\(threads)",
            "-otxt",
            "-of", outputPrefix.path,
            "-nt"
        ]
        let extraArgs = config.whisperCppExtraArgs.trimmingCharacters(in: .whitespaces)
        if !extraArgs.isEmpty {
            args.append(contentsOf: extraArgs.components(separatedBy: .whitespaces).filter { !$0.isEmpty })
        }

        let result = await Shell.run(
            Shell.findExecutable(command).isEmpty ? command : Shell.findExecutable(command),
            arguments: args,
            timeout: Self.requestTimeout
        )

        guard result.code == 0 else {
            throw STTError.processFailed(result.output)
        }

        // Try reading output .txt file first
        if let fileText = try? String(contentsOf: outputTxtURL, encoding: .utf8) {
            let trimmed = fileText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }

        // Fallback: parse stdout, stripping [timestamp] prefixes
        let fromStdout = result.output
            .components(separatedBy: .newlines)
            .map { line in
                line.replacingOccurrences(of: #"^\[[^\]]+\]\s*"#, with: "", options: .regularExpression)
                    .trimmingCharacters(in: .whitespaces)
            }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)

        if !fromStdout.isEmpty { return fromStdout }
        throw STTError.emptyTranscript
    }

    // MARK: - Qwen ASR (WebSocket Realtime)

    private func transcribeQwenAsr(pcm16Data: Data) async throws -> String {
        let model = config.qwenAsrModel.trimmingCharacters(in: .whitespaces)
        guard !model.isEmpty else {
            throw STTError.missingAPIKey("QWEN_ASR_MODEL")
        }
        let apiKey = config.qwenAsrApiKey.trimmingCharacters(in: .whitespaces)
        guard !apiKey.isEmpty else {
            throw STTError.missingAPIKey("QWEN_ASR_API_KEY")
        }
        let baseURL = config.qwenAsrRealtimeBaseUrl.trimmingCharacters(in: .whitespaces)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !baseURL.isEmpty else {
            throw STTError.missingAPIKey("QWEN_ASR_REALTIME_BASE_URL")
        }

        let sampleRate = max(8000, config.qwenAsrSampleRate)
        let wsURL = URL(string: "\(baseURL)?model=\(model.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? model)")!

        let pcmData = pcm16Data

        // Build request with auth headers (URLSessionWebSocketTask requires URLRequest for custom headers)
        var wsRequest = URLRequest(url: wsURL)
        wsRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        wsRequest.setValue("realtime=v1", forHTTPHeaderField: "OpenAI-Beta")

        return try await withCheckedThrowingContinuation { continuation in
            var resumed = false
            let lock = NSLock()
            func finish(_ result: Result<String, Error>) {
                lock.lock()
                guard !resumed else { lock.unlock(); return }
                resumed = true
                lock.unlock()
                continuation.resume(with: result)
            }

            var transcript = ""
            let session = URLSession(configuration: .default)
            let task = session.webSocketTask(with: wsRequest)

            // Timeout
            let timeoutItem = DispatchWorkItem {
                finish(.failure(STTError.timedOut))
                task.cancel()
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + Self.requestTimeout, execute: timeoutItem)

            func sendJSON(_ dict: [String: Any]) {
                guard let data = try? JSONSerialization.data(withJSONObject: dict),
                      let text = String(data: data, encoding: .utf8) else { return }
                task.send(.string(text)) { _ in }
            }

            func buildPrompt() -> String {
                var parts = [
                    "请将音频准确转写为中文文本。",
                    "只输出转写结果，不要解释。"
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

            func receiveLoop() {
                task.receive { result in
                    switch result {
                    case .success(let message):
                        switch message {
                        case .string(let text):
                            if let event = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] {
                                let extracted = extractQwenRealtimeTranscript(event)
                                if !extracted.isEmpty {
                                    transcript = extracted
                                }
                                if (event["type"] as? String) == "session.finished" {
                                    timeoutItem.cancel()
                                    finish(.success(transcript.isEmpty ? extracted : transcript))
                                    task.cancel(with: .normalClosure, reason: nil)
                                    return
                                }
                            }
                        default:
                            break
                        }
                        receiveLoop()
                    case .failure(let error):
                        timeoutItem.cancel()
                        finish(.failure(STTError.websocketError(error.localizedDescription)))
                    }
                }
            }

            task.resume()

            // Wait briefly for connection, then send session config
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) {
                var sessionConfig: [String: Any] = [
                    "modalities": ["text"],
                    "input_audio_format": "pcm",
                    "sample_rate": sampleRate,
                    "input_audio_transcription": [:] as [String: Any],
                    "turn_detection": NSNull()
                ]
                let language = config.qwenAsrLanguage.trimmingCharacters(in: .whitespaces)
                if !language.isEmpty {
                    sessionConfig["input_audio_transcription"] = ["language": language]
                }
                let prompt = buildPrompt()
                if !prompt.isEmpty {
                    sessionConfig["instructions"] = prompt
                }

                sendJSON([
                    "event_id": "event_\(Int(Date().timeIntervalSince1970 * 1000))",
                    "type": "session.update",
                    "session": sessionConfig
                ])

                // Stream PCM chunks
                let chunkSize = max(3200, (sampleRate / 10) * 2)
                var offset = 0
                var chunkIndex = 0
                while offset < pcmData.count {
                    let end = min(offset + chunkSize, pcmData.count)
                    let chunk = pcmData.subdata(in: offset..<end)
                    sendJSON([
                        "event_id": "event_\(Int(Date().timeIntervalSince1970 * 1000))_\(chunkIndex)",
                        "type": "input_audio_buffer.append",
                        "audio": chunk.base64EncodedString()
                    ])
                    offset = end
                    chunkIndex += 1
                }

                // Commit and finish
                sendJSON([
                    "event_id": "event_\(Int(Date().timeIntervalSince1970 * 1000))_commit",
                    "type": "input_audio_buffer.commit"
                ])
                sendJSON([
                    "event_id": "event_\(Int(Date().timeIntervalSince1970 * 1000))_finish",
                    "type": "session.finish"
                ])

                // Start receiving
                receiveLoop()
            }
        }
    }

    // MARK: - WAV Conversion

    /// Convert PCM16 mono audio to WAV format (prepend 44-byte header).
    private func pcm16ToWav(_ pcmData: Data, sampleRate: Int = 16000, channels: Int = 1) -> Data {
        let pcmLength = UInt32(pcmData.count)
        let bitsPerSample: UInt16 = 16
        let byteRate = UInt32(sampleRate * channels * Int(bitsPerSample) / 8)
        let blockAlign = UInt16(channels * Int(bitsPerSample) / 8)

        var header = Data(count: 44)

        // RIFF header
        header.replaceSubrange(0..<4, with: [0x52, 0x49, 0x46, 0x46]) // "RIFF"
        writeUInt32LE(&header, offset: 4, value: 36 + pcmLength)
        header.replaceSubrange(8..<12, with: [0x57, 0x41, 0x56, 0x45]) // "WAVE"

        // fmt subchunk
        header.replaceSubrange(12..<16, with: [0x66, 0x6D, 0x74, 0x20]) // "fmt "
        writeUInt32LE(&header, offset: 16, value: 16) // subchunk1 size
        writeUInt16LE(&header, offset: 20, value: 1) // PCM format
        writeUInt16LE(&header, offset: 22, value: UInt16(channels))
        writeUInt32LE(&header, offset: 24, value: UInt32(sampleRate))
        writeUInt32LE(&header, offset: 28, value: byteRate)
        writeUInt16LE(&header, offset: 32, value: blockAlign)
        writeUInt16LE(&header, offset: 34, value: bitsPerSample)

        // data subchunk
        header.replaceSubrange(36..<40, with: [0x64, 0x61, 0x74, 0x61]) // "data"
        writeUInt32LE(&header, offset: 40, value: pcmLength)

        var wav = header
        wav.append(pcmData)
        return wav
    }

    private func writeUInt32LE(_ data: inout Data, offset: Int, value: UInt32) {
        withUnsafeBytes(of: value.littleEndian) { buffer in
            for i in 0..<4 {
                data[offset + i] = buffer[i]
            }
        }
    }

    private func writeUInt16LE(_ data: inout Data, offset: Int, value: UInt16) {
        withUnsafeBytes(of: value.littleEndian) { buffer in
            for i in 0..<2 {
                data[offset + i] = buffer[i]
            }
        }
    }
}

// MARK: - Qwen Realtime Transcript Extraction

/// Extract transcript text from a Qwen ASR realtime event, matching the
/// multi-format response parsing logic from the Node.js implementation.
private func extractQwenRealtimeTranscript(_ event: [String: Any]) -> String {
    // Primary: completion event
    if (event["type"] as? String) == "conversation.item.input_audio_transcription.completed" {
        let text = (event["transcript"] as? String)
            ?? (event["text"] as? String)
            ?? (event["output_text"] as? String) ?? ""
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
    }

    // Direct fields
    for key in ["transcript", "text", "output_text", "response_text"] {
        if let value = event[key] as? String {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
    }

    // results array
    if let results = event["results"] as? [[String: Any]] {
        let merged = results.compactMap { item -> String? in
            for key in ["transcript", "text", "output_text"] {
                if let value = item[key] as? String, !value.isEmpty { return value }
            }
            return nil
        }.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        if !merged.isEmpty { return merged }
    }

    // output array (with possible nested content)
    if let output = event["output"] as? [[String: Any]] {
        let merged = output.compactMap { item -> String? in
            if let content = item["content"] as? [Any] {
                let text = content.compactMap { part -> String? in
                    if let s = part as? String { return s }
                    if let dict = part as? [String: Any] {
                        return (dict["transcript"] as? String)
                            ?? (dict["text"] as? String)
                            ?? (dict["output_text"] as? String)
                    }
                    return nil
                }.joined(separator: " ")
                return text.isEmpty ? nil : text
            }
            for key in ["transcript", "text", "output_text"] {
                if let value = item[key] as? String, !value.isEmpty { return value }
            }
            return nil
        }.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        if !merged.isEmpty { return merged }
    }

    return ""
}
